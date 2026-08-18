--------------------------------------------------------------------
-- Rems Receiver Debug Privilege
-- Windower 4 companion addon
--
-- Purpose:
--   Grants temporary debug privilege to RemsReceiver while this
--   companion addon is loaded.
--
-- Commands:
--   //rrdebug status
--
-- Usage:
--   //lua load RemsReceiverDebug
--   //rr debug
--
-- To revoke privilege:
--   //lua unload RemsReceiverDebug
--------------------------------------------------------------------

_addon = _addon or {}
_addon.name     = 'RemsReceiverDebug'
_addon.author   = 'OpenAI / HyperKnightGaming'
_addon.version  = '1.0'
_addon.commands = {'rrdebug'}

local TOKEN_FILE = windower.addon_path .. 'debug.token'
local HEARTBEAT_SECONDS = 2

local active = true

local function msg(text)
    windower.add_to_chat(207, '[RR Debug Privilege] ' .. tostring(text))
end

local function write_token()
    local f = io.open(TOKEN_FILE, 'w')

    if not f then
        msg('ERROR: Could not write debug.token.')
        return false
    end

    f:write(tostring(os.time()))
    f:write('\n')
    f:close()

    return true
end

local function remove_token()
    os.remove(TOKEN_FILE)
end

local function heartbeat()
    if not active then
        return
    end

    write_token()

    coroutine.schedule(function()
        heartbeat()
    end, HEARTBEAT_SECONDS)
end

windower.register_event('addon command', function(command)
    command = command and tostring(command):lower() or 'status'

    if command == 'status' then
        msg('Debug privilege heartbeat is ACTIVE.')
        msg('Use //rr debug in RemsReceiver to toggle debug logging.')
        return
    end

    msg('Command: //rrdebug status')
end)

windower.register_event('unload', function()
    active = false
    remove_token()
end)

remove_token()
write_token()
heartbeat()

msg('Loaded. RemsReceiver debug privilege is ACTIVE.')
msg('Run //rr debug to enable privileged debug logging.')
