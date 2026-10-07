--[[
    Created by Naturesong
    Version: 0.1    -   Initial Version, has all primary functions
    Version: 0.2    -   Remove Ed Utils dependancy, added file_exists function
    Version: 0.3    -   Removed bind_setdrink and bind_alcoholic functions and moved code to bind_drinking
    Version: 0.4    -   Added ability to choose drink when running the script: /lua run DayDrinking [Drink]
                        Was using a previous version of Write, now referencing updated version of write which
                        should be found in the /lua folder. Updated version of Write did not parse the % character
                        as previous version did, replaced '%' with 'percent' as a quick fix
    Version 0.5     -   Added auto function. Will search and drink anything in your bags when your toon runs
                        out of their current drink. /lua daydrinking auto
    Version 0.6     -   Removed dependancies on Write.lua and LIP.lua
    Version 0.7     -   Added optional ui. DayDrinking UI will toggle the interface
    Version 0.8     -   Added basic protections for multiple writes to the same config file
    --]]

local mq = require('mq')
local ImGui = require('ImGui')
local log_levels = {
    debug   = { level = 2, color = '\as', abbrev = '[DEBUG]' },
    info    = { level = 3, color = '\ab', abbrev = '[INFO]' },
    warning = { level = 4, color = '\ay', abbrev = '[WARN]' },
    error   = { level = 5, color = '\ar', abbrev = '[ERROR]' },
    help    = { level = 7, color = '\aw', abbrev = '[HELP]' },
}

local current_loglevel = 'info'

local function log_output(level_name, message)
    local level = log_levels[level_name]
    if level and log_levels[current_loglevel].level <= level.level then
        print('[\agDayDrinking\ax] ' .. level.color .. message)
    end
end

local function log_info(message)
    log_output('info', message)
end

local function log_warn(message)
    log_output('warning', message)
end

local function log_error(message)
    log_output('error', message)
end

local function log_help(message)
    log_output('help', message)
end

local function log_debug(message)
    log_output('debug', message)
end

local function file_exists(path)
    local file = io.open(path, "r")
    if file ~= nil then
        io.close(file)
        return true
    else
        return false
    end
end

local function serialize_value(val)
    local t = type(val)
    if t == 'string' then
        return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
    elseif t == 'number' or t == 'boolean' then
        return tostring(val)
    else
        return 'nil'
    end
end

local function serialize_table(tbl, indent)
    indent = indent or 0
    local ind = string.rep('    ', indent)
    local next_ind = string.rep('    ', indent + 1)
    local result = '{\n'

    for key, value in pairs(tbl) do
        local key_str
        if type(key) == 'string' then
            key_str = '"' .. key:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
        else
            key_str = tostring(key)
        end
        result = result .. next_ind .. '[' .. key_str .. '] = '

        if type(value) == 'table' then
            result = result .. serialize_table(value, indent + 1)
        else
            result = result .. serialize_value(value)
        end
        result = result .. ',\n'
    end

    result = result .. ind .. '}'
    return result
end

local function migrate_ini_to_lua(ini_path)
    log_info('\ayMigrating settings from .ini to .lua format...')
    local ini_file = io.open(ini_path, 'r')
    if not ini_file then
        log_warn('\ayMigration: Could not open .ini file at ' .. ini_path)
        return nil
    end

    local migrated = {}
    local current_section = nil
    local line_count = 0

    for line in ini_file:lines() do
        line_count = line_count + 1
        line = line:match('^%s*(.-)%s*$')
        if line and line ~= '' and line:sub(1, 1) ~= ';' then
            if line:sub(1, 1) == '[' and line:sub(-1) == ']' then
                current_section = line:sub(2, -2)
                migrated[current_section] = {}
                log_info('\ayMigration: Found section [' .. current_section .. ']')
            elseif current_section and line:find('=') then
                local key, val = line:match('^([^=]+)=(.*)$')
                if key and val then
                    key = key:match('^%s*(.-)%s*$')
                    val = val:match('^%s*(.-)%s*$')

                    local val_lower = tostring(val):lower()
                    if val_lower == 'true' then
                        migrated[current_section][key] = true
                    elseif val_lower == 'false' then
                        migrated[current_section][key] = false
                    elseif tonumber(val) then
                        migrated[current_section][key] = tonumber(val)
                    else
                        migrated[current_section][key] = val
                    end
                end
            end
        end
    end

    io.close(ini_file)

    if line_count == 0 then
        log_warn('\ayMigration: .ini file is empty')
        return nil
    end

    log_info('\aySuccessfully parsed .ini file (' .. line_count .. ' lines)')
    return migrated
end

local settings_path
local settings

local function save_settings()
    if settings_path and settings then
        local lock_path = settings_path .. '.lock'

        -- File Locking - Wait if another instance has the lock
        local lock_wait_count = 0
        while file_exists(lock_path) and lock_wait_count < 10 do
            mq.delay(50)
            lock_wait_count = lock_wait_count + 1
        end

        mq.pickle(lock_path, { locked_at = mq.gettime() })

        -- Atomic Write - mq.pickle handles safe serialization
        local success = pcall(mq.pickle, settings_path, settings)

        if not success then
            log_error('\ar[Config] Failed to write settings to ' .. settings_path)
            if file_exists(lock_path) then
                pcall(os.remove, lock_path)
            end
            return
        end

        if file_exists(lock_path) then
            pcall(os.remove, lock_path)
        end
    else
        log_error('\ar[Config] Settings path or settings table not initialized')
    end
end

local args = { ... }

local init = true
local auto = false
if args[1] ~= nil then
    if args[1] == 'auto' then
        auto = true
    end
end

local skill = 'Alcohol Tolerance'
local enabled = true
local server_name = mq.TLO.EverQuest.Server()
local char_config = 'Char_' .. mq.TLO.Me.CleanName() .. '_Config'
local DefaultSets = {
    min_intoxication_level = 2,
    drink = "Short Beer",
    auto = false
}
local drink
local min_intoxication_level
local booze
local showUI = false
local previousShowUI = true

local function print_usage()
    if init then
        log_help('\aw/drinking\a-t - Show command reference.')
    else
        log_help('\aw/drinking\a-t - Show command reference.')
        log_help('\aw/drinking status\a-t - Drinking stats and information.')
        log_help('\aw/drinking on|off\a-t - Pause DayDrinking on/off.')
        log_help('\aw/drinking ui [show|hide|blank]\a-t - Show, hide, or toggle ImGui window.')
        log_help('\aw/drinking auto on|off|blank\a-t - Automatic drink selection, on/off or blank to toggle.')
        log_help('\aw/drinking level [int]\a-t - Set min intoxication percent (1 .. 99).')
        log_help('\aw/drinking setdrink [name]\a-t - Set drink to item on cursor or name. Use quotes if there are spaces. Item must be in your inventory.')
        log_help('\aw/drinking loglevel [info|debug|warning|error]\a-t - Set logging verbosity level.')
    end
    init = false
end

local function print_status()
    local drunkenness = math.min(100, math.ceil(mq.TLO.Me.Drunk() / 2))
    log_info('\a-gStatus - \at' .. (enabled and 'Running' or 'Paused'))
    log_info('\a-gCurrent drunkeness - \at' .. drunkenness .. ' / 100.')
    log_info('\a-gMinimum intoxication setting - \at' .. min_intoxication_level / 2 .. ' / 100.')
    log_info('\a-gAutomatic drink selection - \at' .. (auto and 'On' or 'Off'))
    log_info('\a-gCurrent Drink - \at' .. drink)
    log_info('\a-g' .. skill .. ' - \at' .. mq.TLO.Me.Skill(skill)() .. ' / ' .. mq.TLO.Me.SkillCap(skill)())
end

local function is_alcohol(name)
    local item = mq.TLO.FindItem(name)
    return item.ID() and tostring(item.Type()) == 'Alcohol'
end

local function find_drink()
    local bagSlots = mq.TLO.Me.NumBagSlots()
    for i = 1, bagSlots do
        local slots = mq.TLO.InvSlot('pack' .. i).Item.Container()
        if slots ~= nil and slots ~= 0 then
            for j = 1, slots do
                local item = mq.TLO.InvSlot('pack' .. i).Item(j)
                if item.ID() ~= nil and tostring(item.Type()) == 'Alcohol' then
                    return tostring(item.Name())
                end
            end
        end
    end
end

local function strip_quotes(strInput)
    if (strInput:sub(1, 1) == '"' and strInput:sub(strInput:len()) == '"') or
        (strInput:sub(1, 1) == "'" and strInput:sub(strInput:len()) == "'") then
        strInput = strInput:sub(2, strInput:len() - 1)
    end
    return strInput
end

local function bind_drinking(cmd, val)
    if cmd == nil then
        print_usage()
        return

    elseif cmd == 'status' then
        print_status()
        return

    elseif cmd == 'on' then
        enabled = true
        log_info('\ayDayDrinking resumes.')
    elseif cmd == 'off' then
        enabled = false
        log_info('\agDayDrinking paused.')

    elseif cmd == 'level' and val ~= nil then
        val = tonumber(val)
        if val <= 99 and val >= 1 and val == math.floor(val) then
            -- TLO.Me.Drunk goes to 200, but we present it as a percentage to the user
            min_intoxication_level = val * 2
            settings[char_config].min_intoxication_level = min_intoxication_level
            save_settings()
            log_info('\a-gMinimum intoxication level set - \at' .. min_intoxication_level / 2 .. ' / 100.')
        else
            log_warn('\a-g/drinking level [int] - \a-tValid integer required min 1, max 99.')
        end

    elseif cmd == 'auto' then
        local old_auto = auto
        if (val == 'on' or (val == nil and auto == false)) then
            auto = true
            if enabled == false then
                enabled = true
            end
        elseif (val == 'off' or (val == nil and auto == true)) then
            auto = false
        end

        if auto ~= old_auto then
            log_info('\agAutomatic booze selection set to ' .. tostring(auto))
            settings[char_config].auto = auto
            save_settings()
        end

    elseif cmd == 'setdrink' then
        if mq.TLO.Cursor.ID() == nil and val == nil then
            log_error("\ar[SetDrink] Nothing on the cursor. I need something a bit more substantial than that!")
            return
        end
        local name
        if mq.TLO.Cursor.ID() then
            name = mq.TLO.Cursor.Name()
        else
            name = strip_quotes(val)
        end

        if is_alcohol(name) then
            -- is_alcohol uses finditem.type so in order to evaluate, the item needs to be in the toons inventory
            drink = name
            settings[char_config].drink = drink
            save_settings()
            log_info('\a-gDrink set to: \at' .. drink)
        else
            log_error('\ar[SetDrink] ' .. name .. ' is NOT an alcoholic drink (or I cant find it in your inventory)')
        end

    elseif cmd == 'ui' then
        if val == 'show' then
            showUI = true
            log_info('\a-gUI \atshown')
        elseif val == 'hide' then
            showUI = false
            log_info('\a-gUI \athidden')
        else
            showUI = not showUI
            log_info('\a-gUI \at' .. (showUI and 'shown' or 'hidden'))
        end

    elseif cmd == 'loglevel' and val ~= nil then
        val = val:lower()
        if val == 'debug' or val == 'info' or val == 'warning' or val == 'error' then
            current_loglevel = val
            log_info('\a-gLogging level set to: \at' .. val)
        else
            log_error('\ar/drinking loglevel [debug|info|warning|error]')
        end
    end
end

local function load_settings()
    local config_dir = mq.configDir:gsub('\\', '/') .. '/'
    local settings_file_lua = 'DayDrinking_' .. server_name:gsub(' ', '') .. '.lua'
    local settings_file_ini = 'DayDrinking.ini'
    local lua_path = config_dir .. settings_file_lua
    local ini_path = config_dir .. settings_file_ini
    settings_path = lua_path

    if file_exists(lua_path) then
        local success, result = pcall(dofile, lua_path)
        if success and result and type(result) == 'table' then
            log_info('\ayLoaded .lua config successfully')
            settings = result

            if file_exists(ini_path) then
                log_help('\ayRedundant .ini config file found: ' .. ini_path)
                log_help('\ayYou can safely delete it - the script now uses .lua config format.')
            end
        else
            log_warn('\ayFailed to load .lua config, checking for .ini backup...')
            if file_exists(ini_path) then
                log_info('\ayLegacy .ini config found, migrating to .lua format...')
                settings = migrate_ini_to_lua(ini_path)
                if settings and type(settings) == 'table' then
                    log_info('\aySaving migrated config to .lua format...')
                    save_settings()
                    log_info('\ayMigration complete!')
                else
                    log_warn('\ayMigration failed, using defaults')
                    settings = {
                        [char_config] = DefaultSets
                    }
                end
            else
                log_warn('\ayNo .ini backup found, using defaults')
                settings = {
                    [char_config] = DefaultSets
                }
            end
        end

    elseif file_exists(ini_path) then
        log_info('\ayNo .lua config found. Legacy .ini config detected, migrating to .lua format...')
        settings = migrate_ini_to_lua(ini_path)
        if settings and type(settings) == 'table' then
            log_info('\aySaving migrated config to .lua format...')
            save_settings()
            log_info('\ayMigration complete!')
        else
            log_warn('\ayMigration failed, using defaults')
            settings = {
                [char_config] = DefaultSets
            }
        end

    else
        settings = {
            [char_config] = DefaultSets
        }
        save_settings()
    end

    if not settings or type(settings) ~= 'table' then
        settings = {}
    end

    if settings[char_config] == nil then
        settings[char_config] = DefaultSets
        save_settings()
    end
    drink = settings[char_config].drink or DefaultSets.drink
    min_intoxication_level = settings[char_config].min_intoxication_level or DefaultSets.min_intoxication_level
    if settings[char_config].auto ~= nil then
        auto = settings[char_config].auto
    else
        settings[char_config].auto = auto
        log_info('\ayAuto is set to ' .. tostring(auto))
        save_settings()
    end

    log_info('\ayby Naturesong - \atLoaded: ' .. settings_file_lua)

    if args[1] ~= nil then
        if auto then
            booze = find_drink()
            if booze ~= nil then
                bind_drinking('setdrink', booze)
            end
        else
            bind_drinking('setdrink', tostring(args[1]))
        end
    end

end

local function DrawToggle(id, value, on_color, off_color, height, width)
    height = height or 16
    width = width or height * 2
    on_color = on_color or ImVec4(0.2, 0.8, 0.2, 1)
    off_color = off_color or ImVec4(0.8, 0.2, 0.2, 1)

    local clicked = false
    local label = id:match("^(.-)##")
    if not id:find("##") then
        label = id
    end

    if label and label ~= "" then
        ImGui.Text(string.format("%s:", label))
        if ImGui.IsItemClicked() then
            value = not value
            clicked = true
        end
        ImGui.SameLine()
    end

    local draw_list = ImGui.GetWindowDrawList()
    local pos = { x = 0, y = 0, }
    pos.x, pos.y = ImGui.GetCursorScreenPos()
    local radius = height * 0.5

    local t = value and 1.0 or 0.0
    local knob_x = pos.x + radius + t * (width - height)

    draw_list:AddRectFilled(
        ImVec2(pos.x, pos.y),
        ImVec2(pos.x + width, pos.y + height),
        ImGui.GetColorU32(value and on_color or off_color),
        height * 0.5
    )

    draw_list:AddCircleFilled(
        ImVec2(knob_x, pos.y + radius),
        radius * 0.8,
        ImGui.GetColorU32(ImVec4(1, 1, 1, 1)),
        0
    )

    ImGui.SetCursorScreenPos(ImVec2(pos.x, pos.y))
    ImGui.InvisibleButton(id, width, height)
    if ImGui.IsItemClicked() then
        value = not value
        clicked = true
    end

    return value, clicked
end

local function renderUI()
    if previousShowUI ~= showUI then
        if showUI then
            log_info('\ayDayDrinking UI\ax \agvisible')
        else
            log_info('\ayDayDrinking UI\ax \aghidden')
        end
        previousShowUI = showUI
    end

    if not showUI then return end

    showUI, shouldDraw = ImGui.Begin('DayDrinking##main', showUI)

    if shouldDraw then
        local drunkenness = math.min(100, math.ceil(mq.TLO.Me.Drunk() / 2))
        ImGui.Text('Drunkenness: ' .. drunkenness .. ' / 100')

        ImGui.Text('Minimum Drunkenness: ' .. min_intoxication_level / 2 .. ' / 100')

        ImGui.Text('Current Drink: ' .. drink .. ' [' .. mq.TLO.FindItemCount(drink)() .. ']')
        ImGui.Text('Alcohol Tolerance: ' .. mq.TLO.Me.Skill(skill)() .. ' / ' .. mq.TLO.Me.SkillCap(skill)())

        ImGui.Spacing()

        ImGui.Text('Status: ')
        ImGui.SameLine()
        enabled, changed = DrawToggle('##status_toggle', enabled,
            ImVec4(0.0, 1.0, 0.0, 0.8), ImVec4(1.0, 0.5, 0.0, 0.8))
        if changed then
            save_settings()
            log_info('\a-gStatus \at' .. (enabled and 'Running' or 'Paused'))
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip(enabled and 'Running' or 'Paused')
        end

        ImGui.Spacing()

        auto, changed = DrawToggle('Auto Select Drink##auto', auto,
            ImVec4(0.4, 1.0, 0.4, 0.8), ImVec4(1.0, 0.4, 0.4, 0.8))
        if changed then
            settings[char_config].auto = auto
            save_settings()
            log_info('\a-gAutomatic booze selection set to ' .. tostring(auto))
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip('Automatically search bags for alcohol when current drink runs out')
        end

    end

    ImGui.End()
end

local function setup()
    load_settings()

    mq.bind('/drinking', bind_drinking)
    mq.imgui.init('DayDrinking', renderUI)

    print_usage()

end

local function out_of_booze()
    booze = find_drink()
    if auto and booze ~= nil then
        log_info('\ayFound some more booze! \ag' .. booze .. '!')
        bind_drinking('setdrink', booze)
    else
        log_warn('\ayUnable to find ' .. drink .. '. Drinking paused. Get another round and type \a-g/drinking on')
        enabled = false
    end
end

local function skill_maxxed()
    if mq.TLO.Me.Skill(skill)() == mq.TLO.Me.SkillCap(skill)() then
        log_info('\aySkill at maximum - Time to exit.')
    end
end

local function main()
    skill_maxxed()
    while mq.TLO.Me.Skill(skill)() < mq.TLO.Me.SkillCap(skill)() do
        if (mq.TLO.Me.Drunk() <= min_intoxication_level) and enabled then
            if drink and (mq.TLO.FindItemCount(drink)() > 0) then
                mq.cmd('/useitem ' .. drink)
            else
                out_of_booze()
            end
        end
        skill_maxxed()
        mq.delay(1000)
    end
end

setup()
main()
