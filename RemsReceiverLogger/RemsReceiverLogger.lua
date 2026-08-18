--------------------------------------------------------------------
-- Rems Receiver Logger
-- Passive Windower 4 packet capture addon
--
-- This addon DOES NOT inject packets or make NPC selections.
--
-- Commands:
--   //rrlog on
--   //rrlog off
--   //rrlog clear
--   //rrlog status
--
-- Log:
--   Windower\addons\RemsReceiverLogger\RemsReceiverCapture.log
--------------------------------------------------------------------

_addon = _addon or {}
_addon.name     = 'RemsReceiverLogger'
_addon.author   = 'OpenAI'
_addon.version  = '1.0'
_addon.commands = {'rrlog'}

local packets = require('packets')

local enabled = true
local log_file = windower.addon_path .. 'RemsReceiverCapture.log'

local function msg(text)
    windower.add_to_chat(207, '[RR Logger] ' .. tostring(text))
end

local function write_log(text)
    local f = io.open(log_file, 'a')
    if not f then
        msg('ERROR: Could not open log file.')
        return
    end
    f:write(tostring(text), '\n')
    f:close()
end

local function clear_log()
    local f = io.open(log_file, 'w')
    if not f then
        msg('ERROR: Could not create log file.')
        return
    end
    f:write('============================================================\n')
    f:write('Rems Receiver Passive Capture Log\n')
    f:write('Created: ' .. os.date('%Y-%m-%d %H:%M:%S') .. '\n')
    f:write('============================================================\n\n')
    f:close()
    msg('Capture log cleared.')
end

local function bytes_to_hex(data)
    local out = {}
    for i = 1, #data do
        out[#out + 1] = string.format('%02X', data:byte(i))
    end
    return table.concat(out, ' ')
end

local function dump_packet(direction, id, data, title)
    write_log('')
    write_log('============================================================')
    write_log(string.format('%s 0x%03X - %s', direction:upper(), id, title))
    write_log('Time: ' .. os.date('%Y-%m-%d %H:%M:%S'))
    write_log('============================================================')

    local ok, p = pcall(packets.parse, direction, data)

    if ok and p then
        write_log('PARSED FIELDS:')
        for k, v in pairs(p) do
            if type(v) ~= 'table' then
                write_log(string.format('%-28s = %s', tostring(k), tostring(v)))
            end
        end
    else
        write_log('PARSE FAILED')
    end

    write_log('')
    write_log('RAW BYTES:')
    write_log(bytes_to_hex(data))
    write_log('')
end

windower.register_event('addon command', function(command)
    command = command and command:lower() or 'status'

    if command == 'on' then
        enabled = true
        write_log('CAPTURE ENABLED: ' .. os.date('%Y-%m-%d %H:%M:%S'))
        msg('Capture ON.')
        return
    end

    if command == 'off' then
        enabled = false
        write_log('CAPTURE DISABLED: ' .. os.date('%Y-%m-%d %H:%M:%S'))
        msg('Capture OFF.')
        return
    end

    if command == 'clear' then
        clear_log()
        return
    end

    if command == 'status' then
        msg('Capture is ' .. (enabled and 'ON' or 'OFF') .. '.')
        msg('Log: ' .. log_file)
        return
    end

    msg('Commands: //rrlog on | off | clear | status')
end)

windower.register_event('incoming chunk', function(id, data)
    if not enabled then
        return
    end

    if id == 0x034 then
        dump_packet('incoming', id, data, 'NPC Interaction 2')
        msg('Logged incoming 0x034.')
    elseif id == 0x052 then
        dump_packet('incoming', id, data, 'NPC Release')
    end
end)

windower.register_event('outgoing chunk', function(id, data)
    if not enabled then
        return
    end

    if id == 0x05B then
        dump_packet('outgoing', id, data, 'Dialog Choice')

        local ok, p = pcall(packets.parse, 'outgoing', data)
        if ok and p then
            msg(
                '0x05B Option=' .. tostring(p['Option Index']) ..
                ' Menu=' .. tostring(p['Menu ID'])
            )
        else
            msg('Logged outgoing 0x05B.')
        end
    end
end)

clear_log()
msg('Loaded. Passive capture is ON.')
msg('This addon does NOT inject packets.')
