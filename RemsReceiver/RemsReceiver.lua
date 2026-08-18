--------------------------------------------------------------------
-- Rems Receiver
-- Windower 4 Addon
-- v2.7
--
-- Retrieval commands:
--   //rr <chapter> <quantity>
--   //rr <chapter> all
--   //rr all
--   //rr all <chapter> <chapter> ...
--   //rr <chapter> <qty|all> <chapter> <qty|all> ...
--
-- Inspection / QoL:
--   //rr list
--   //rr space
--   //rr missing
--   //rr status
--   //rr retry
--   //rr stop
--   //rr cancel
--   //rr hud on|off
--   //rr notify on|off
--   //rr debug
--   //rr clearlog
--
-- Debug privilege:
--   Debug logging is LOCKED unless the separate RemsReceiverDebug
--   companion addon is loaded.  The companion maintains a short-lived
--   heartbeat token; stale tokens expire automatically.
--
-- Examples:
--   //rr 1 5
--   //rr 2 all
--   //rr all
--   //rr all 1 2 5 6
--   //rr 1 5 2 3 6 all
--
-- Confirmed Monisette Rem's Tale menus:
--   385 = no gear traded
--   387 = gear traded
--------------------------------------------------------------------

_addon = _addon or {}
_addon.name     = 'RemsReceiver'
_addon.author   = 'OpenAI / HyperKnightGaming'
_addon.version  = '2.7'
_addon.commands = {'rr', 'remsreceiver'}

local packets = require('packets')
local res = require('resources')
local texts = require('texts')

--------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------

local MONISETTE_NAME = 'Monisette'
local PORT_JEUNO_ZONE = 246

local VALID_REMS_MENUS = {
    [385] = true, -- no gear traded
    [387] = true, -- gear traded
}

local REM_ITEM_IDS = {
    [1]  = 4064,
    [2]  = 4065,
    [3]  = 4066,
    [4]  = 4067,
    [5]  = 4068,
    [6]  = 4069,
    [7]  = 4070,
    [8]  = 4071,
    [9]  = 4072,
    [10] = 4073,
}

-- In Windower's parsed 32-byte Menu Parameters field,
-- Monisette's chapter counts are bytes 17 through 26.
local REM_COUNT_OFFSET = 16

local MAX_QUANTITY = 255
local MAX_DISTANCE_SQUARED = 36
local NEXT_REQUEST_DELAY = 0.75
local INTERACTION_TIMEOUT = 5
local MAX_INTERACTION_RETRIES = 2
local STATUS_HIDE_DELAY = 3

-- Debug privilege is granted only while the separate RemsReceiverDebug
-- companion addon is actively maintaining this heartbeat token.
local DEBUG_TOKEN_TTL = 6
local DEBUG_TOKEN_FILE =
    windower.windower_path .. 'addons/RemsReceiverDebug/debug.token'

--------------------------------------------------------------------
-- Runtime state
--------------------------------------------------------------------

local pending = nil
local serial_counter = 0
local debug_enabled = false
local hud_enabled = true
local notify_enabled = true

local log_file = windower.addon_path .. 'RemsReceiver.log'
local notify_sound = windower.addon_path .. 'complete.wav'

--------------------------------------------------------------------
-- HUD
--------------------------------------------------------------------

local status_settings = {
    pos = {x = 20, y = 300},
    bg = {
        alpha = 145,
        red = 0,
        green = 0,
        blue = 0,
        visible = true,
    },
    text = {
        font = 'Consolas',
        size = 10,
        red = 255,
        green = 255,
        blue = 255,
        alpha = 255,
    },
    flags = {
        bold = false,
        italic = false,
        right = false,
        bottom = false,
        draggable = true,
    },
    padding = 6,
}

local status_box = texts.new('', status_settings)
status_box:hide()

--------------------------------------------------------------------
-- Basic helpers
--------------------------------------------------------------------

local function msg(text)
    windower.add_to_chat(207, '[Rems Receiver] ' .. tostring(text))
end

local function log(text)
    local f = io.open(log_file, 'a')
    if not f then
        return
    end

    f:write(os.date('[%Y-%m-%d %H:%M:%S] '))
    f:write(tostring(text))
    f:write('\n')
    f:close()
end

local function debug_privilege_active()
    local f = io.open(DEBUG_TOKEN_FILE, 'r')

    if not f then
        return false
    end

    local raw = f:read('*l')
    f:close()

    local stamp = tonumber(raw)

    if not stamp then
        return false
    end

    local age = os.time() - stamp

    return age >= 0 and age <= DEBUG_TOKEN_TTL
end

local function revoke_debug_if_needed()
    if debug_enabled and not debug_privilege_active() then
        debug_enabled = false
        log('[DEBUG] Debug privilege heartbeat expired; debug logging disabled.')
        return true
    end

    return false
end

local function debug(text)
    if not debug_enabled then
        return
    end

    if revoke_debug_if_needed() then
        return
    end

    log('[DEBUG] ' .. tostring(text))
end

local function integer(v)
    local n = tonumber(v)
    if not n or n ~= math.floor(n) then
        return nil
    end
    return n
end

local function zone_id()
    local info = windower.ffxi.get_info()
    return info and info.zone or nil
end

local function me()
    return windower.ffxi.get_mob_by_target('me')
end

local function dist2(a, b)
    if not a or not b
    or not a.x or not a.y
    or not b.x or not b.y then
        return math.huge
    end

    local dx = a.x - b.x
    local dy = a.y - b.y
    return dx * dx + dy * dy
end

local function copy_counts(source)
    local out = {}
    for chapter = 1, 10 do
        out[chapter] = source[chapter] or 0
    end
    return out
end

local function zero_amounts()
    local out = {}
    for chapter = 1, 10 do
        out[chapter] = 0
    end
    return out
end

--------------------------------------------------------------------
-- Monisette lookup
--------------------------------------------------------------------

local function find_monissette()
    local matches = windower.ffxi.get_mob_list(MONISETTE_NAME)
    if not matches then
        return nil, math.huge
    end

    local player = me()
    local best = nil
    local best_d2 = math.huge

    for index in pairs(matches) do
        local mob = windower.ffxi.get_mob_by_index(index)

        if mob and mob.name == MONISETTE_NAME then
            local d = dist2(player, mob)

            if d < best_d2 then
                best = mob
                best_d2 = d
            end
        end
    end

    return best, best_d2
end

--------------------------------------------------------------------
-- Rem count parsing
--------------------------------------------------------------------

local function chapter_counts(params)
    if type(params) ~= 'string'
    or #params < (REM_COUNT_OFFSET + 10) then
        return nil
    end

    local counts = {}

    for chapter = 1, 10 do
        counts[chapter] = params:byte(REM_COUNT_OFFSET + chapter)
    end

    return counts
end

local function counts_to_string(counts)
    if not counts then
        return 'invalid'
    end

    local t = {}
    for chapter = 1, 10 do
        t[#t + 1] = tostring(counts[chapter] or '?')
    end
    return table.concat(t, ',')
end

local function total_counts(counts)
    local total = 0
    for chapter = 1, 10 do
        total = total + (counts[chapter] or 0)
    end
    return total
end

--------------------------------------------------------------------
-- Inventory / stack helpers
--------------------------------------------------------------------

local function rem_stack_size(chapter)
    local id = REM_ITEM_IDS[chapter]
    local item = id and res.items[id]

    if item and item.stack and item.stack > 0 then
        return item.stack
    end

    return 12
end

local function inventory_snapshot()
    local inventory = windower.ffxi.get_items(0)
    local bag_info = windower.ffxi.get_bag_info(0)

    if not inventory or not bag_info or not bag_info.max then
        return nil, 'Unable to read Inventory.'
    end

    local max_slots = bag_info.max
    local used_slots = 0
    local partial_capacity = zero_amounts()

    for slot = 1, max_slots do
        local item = inventory[slot]

        if item and item.id and item.id ~= 0 and item.id ~= 0xFFFF then
            used_slots = used_slots + 1

            for chapter = 1, 10 do
                if item.id == REM_ITEM_IDS[chapter] then
                    local stack = rem_stack_size(chapter)
                    local count = tonumber(item.count) or 0

                    if count < stack then
                        partial_capacity[chapter] =
                            partial_capacity[chapter] + (stack - count)
                    end

                    break
                end
            end
        end
    end

    return {
        max_slots = max_slots,
        used_slots = used_slots,
        free_slots = max_slots - used_slots,
        partial_capacity = partial_capacity,
    }
end

local function slots_needed_for(amounts, snapshot)
    local slots_needed = 0
    local detail = {}

    for chapter = 1, 10 do
        local amount = amounts[chapter] or 0

        if amount > 0 then
            local partial = snapshot.partial_capacity[chapter] or 0
            local remaining = math.max(0, amount - partial)
            local stack = rem_stack_size(chapter)
            local new_slots = math.ceil(remaining / stack)

            slots_needed = slots_needed + new_slots

            detail[chapter] = {
                amount = amount,
                partial_capacity = partial,
                new_slots = new_slots,
                stack_size = stack,
            }
        end
    end

    return slots_needed, detail
end

local function partial_room_used(amounts, snapshot)
    local total = 0

    for chapter = 1, 10 do
        total = total + math.min(
            amounts[chapter] or 0,
            snapshot.partial_capacity[chapter] or 0
        )
    end

    return total
end

local function inventory_can_hold(amounts)
    local snapshot, err = inventory_snapshot()
    if not snapshot then
        return false, nil, nil, err
    end

    local needed, detail = slots_needed_for(amounts, snapshot)

    if needed > snapshot.free_slots then
        return false, snapshot, detail,
            string.format(
                'Need %d free inventory slot%s, but only %d free.',
                needed,
                needed == 1 and '' or 's',
                snapshot.free_slots
            )
    end

    return true, snapshot, detail, nil
end

local function single_amount_table(chapter, amount)
    local t = zero_amounts()
    t[chapter] = amount
    return t
end

--------------------------------------------------------------------
-- Display / summary helpers
--------------------------------------------------------------------

local function mode_label()
    if not pending then
        return 'Idle'
    end

    if pending.mode == 'all' then
        return 'ALL'
    elseif pending.mode == 'selected_all' then
        return 'SELECTED ALL'
    elseif pending.mode == 'queue' then
        return 'QUEUE'
    elseif pending.mode == 'inspect' then
        return string.upper(tostring(pending.inspect_kind or 'inspect'))
    elseif pending.quantity == 'all' then
        return 'CHAPTER ALL'
    end

    return 'SINGLE'
end

local function update_status()
    if not hud_enabled then
        status_box:hide()
        return
    end

    if not pending then
        status_box:hide()
        return
    end

    local line1 = 'Rems Receiver v' .. tostring(_addon.version)
    local line2 = mode_label() .. ' | ' .. tostring(pending.stage or 'starting')
    local line3

    if pending.mode == 'all'
    or pending.mode == 'selected_all'
    or pending.mode == 'queue' then
        local current = pending.plan_index or 0
        local total_entries = pending.plan and #pending.plan or 0
        local chapter = pending.chapter and ('Ch.' .. pending.chapter) or 'Scanning'
        line3 = string.format(
            '%s | %d/%d | %d/%s received',
            chapter,
            current,
            total_entries,
            pending.total_retrieved or 0,
            tostring(pending.planned_total or '?')
        )
    elseif pending.mode == 'inspect' then
        line3 = 'Reading Monisette...'
    else
        line3 = string.format(
            'Ch.%s x%s | %d received',
            tostring(pending.chapter or '?'),
            tostring(pending.quantity or '?'),
            pending.total_retrieved or 0
        )
    end

    if pending.stop_after_release then
        line2 = line2 .. ' | STOPPING'
    end

    status_box:text(line1 .. '\n' .. line2 .. '\n' .. line3)
    status_box:show()
end

local function hide_status_later()
    local marker = serial_counter

    coroutine.schedule(function()
        if not pending and serial_counter == marker then
            status_box:hide()
        end
    end, STATUS_HIDE_DELAY)
end

local function summary_parts(retrieved)
    local parts = {}

    for chapter = 1, 10 do
        local amount = retrieved[chapter] or 0
        if amount > 0 then
            parts[#parts + 1] = string.format('Ch%d %d', chapter, amount)
        end
    end

    return parts
end

local function print_completion_summary(prefix, retrieved, total)
    msg(string.format('%s: %d total Rem\'s Tale%s.',
        prefix,
        total,
        total == 1 and '' or 's'
    ))

    local parts = summary_parts(retrieved)

    if #parts > 0 then
        local first = {}
        local second = {}

        for i, part in ipairs(parts) do
            if i <= 5 then
                first[#first + 1] = part
            else
                second[#second + 1] = part
            end
        end

        if #first > 0 then
            msg(table.concat(first, ' | '))
        end

        if #second > 0 then
            msg(table.concat(second, ' | '))
        end
    end
end

local function finish_notification()
    if not notify_enabled then
        return
    end

    msg('Finished all requested Rem\'s Tales.')

    if windower.file_exists(notify_sound) then
        windower.play_sound(notify_sound)
    else
        debug('Notification sound not found: ' .. tostring(notify_sound))
    end
end

local function print_stored_list(counts)
    msg(string.format(
        'Stored: Ch1 %d | Ch2 %d | Ch3 %d | Ch4 %d | Ch5 %d',
        counts[1], counts[2], counts[3], counts[4], counts[5]
    ))
    msg(string.format(
        '        Ch6 %d | Ch7 %d | Ch8 %d | Ch9 %d | Ch10 %d | Total %d',
        counts[6], counts[7], counts[8], counts[9], counts[10],
        total_counts(counts)
    ))
end

local function print_space_report(counts)
    local snapshot, err = inventory_snapshot()

    if not snapshot then
        msg(tostring(err))
        return
    end

    local needed = slots_needed_for(counts, snapshot)
    local partial = partial_room_used(counts, snapshot)
    local total = total_counts(counts)
    local ready = needed <= snapshot.free_slots

    msg(string.format(
        'Space: %d stored | %d partial-stack room | %d new slot%s needed | %d free.',
        total,
        partial,
        needed,
        needed == 1 and '' or 's',
        snapshot.free_slots
    ))

    if ready then
        msg('Ready for //rr all.')
    else
        msg(string.format(
            'Need %d more free inventory slot%s for //rr all.',
            needed - snapshot.free_slots,
            (needed - snapshot.free_slots) == 1 and '' or 's'
        ))
    end
end

--------------------------------------------------------------------
-- Request lifecycle helpers
--------------------------------------------------------------------

local function clear_pending()
    pending = nil
    hide_status_later()
end

local function abort(reason)
    if pending then
        log(string.format(
            'ABORT mode=%s ch=%s qty=%s stage=%s reason=%s',
            tostring(pending.mode),
            tostring(pending.chapter),
            tostring(pending.quantity),
            tostring(pending.stage),
            tostring(reason)
        ))
    else
        log('ABORT reason=' .. tostring(reason))
    end

    clear_pending()
end

local function finalize_success()
    if not pending then
        return
    end

    local total = pending.total_retrieved or 0
    local retrieved = pending.retrieved_by_chapter or zero_amounts()
    local is_multi = pending.mode == 'all'
        or pending.mode == 'selected_all'
        or pending.mode == 'queue'

    if is_multi then
        print_completion_summary('Complete', retrieved, total)
        log(string.format('MULTI COMPLETE mode=%s total=%d', pending.mode, total))
        finish_notification()
    else
        local chapter = pending.chapter
        local amount = retrieved[chapter] or total
        msg(string.format('Complete: received %d x Chapter %d.', amount, chapter))
        log(string.format('SINGLE COMPLETE ch=%d total=%d', chapter, total))
    end

    clear_pending()
end

local function finalize_stopped()
    if not pending then
        return
    end

    local total = pending.total_retrieved or 0
    local retrieved = pending.retrieved_by_chapter or zero_amounts()

    if total > 0 then
        print_completion_summary('Stopped after receiving', retrieved, total)
    else
        msg('Request stopped. Nothing was retrieved.')
    end

    log(string.format('STOP COMPLETE total=%d', total))
    clear_pending()
end

local function clear_log()
    local f = io.open(log_file, 'w')

    if not f then
        msg('Could not clear log.')
        return
    end

    f:write('Rems Receiver v' .. tostring(_addon.version) .. '\n')
    f:write('Valid Rem menu IDs: 385, 387\n')
    f:write('Cleared: ' .. os.date('%Y-%m-%d %H:%M:%S') .. '\n\n')
    f:close()

    msg('Log cleared.')
end

local function help()
    msg('Retrieval:')
    msg('//rr 1 5 | //rr 1 all | //rr all')
    msg('//rr all 1 2 5 6')
    msg('//rr 1 5 2 3 6 all')
    msg('Info: //rr list | space | missing | status')
    msg('Control: //rr retry | stop | cancel')
    msg('Options: //rr hud on|off | notify on|off | debug | clearlog')
    msg('Debug requires the RemsReceiverDebug companion addon.')
end

--------------------------------------------------------------------
-- Plan building
--------------------------------------------------------------------

local function build_all_plan(counts, selected_chapters)
    local plan = {}
    local amounts = zero_amounts()
    local selected = nil

    if selected_chapters then
        selected = {}
        for _, chapter in ipairs(selected_chapters) do
            selected[chapter] = true
        end
    end

    for chapter = 1, 10 do
        local amount = counts[chapter] or 0
        local wanted = not selected or selected[chapter]

        -- Zero chapters are silently omitted from the plan.
        if wanted and amount > 0 then
            plan[#plan + 1] = {
                chapter = chapter,
                amount = amount,
                requested = 'all',
            }
            amounts[chapter] = amounts[chapter] + amount
        end
    end

    return plan, amounts
end

local function build_queue_plan(counts, specs)
    local plan = {}
    local amounts = zero_amounts()
    local remaining = copy_counts(counts)

    for _, spec in ipairs(specs) do
        local chapter = spec.chapter
        local available = remaining[chapter] or 0
        local amount = 0

        if spec.quantity == 'all' then
            amount = available
        else
            amount = math.min(spec.quantity, available)
        end

        if amount > 0 then
            plan[#plan + 1] = {
                chapter = chapter,
                amount = amount,
                requested = spec.quantity,
            }

            amounts[chapter] = amounts[chapter] + amount
            remaining[chapter] = available - amount
        end
    end

    return plan, amounts
end

local function set_current_plan_entry()
    if not pending or not pending.plan then
        return nil
    end

    local entry = pending.plan[pending.plan_index]
    if not entry then
        return nil
    end

    pending.chapter = entry.chapter
    pending.quantity = entry.requested
    pending.planned_amount = entry.amount
    return entry
end

--------------------------------------------------------------------
-- NPC interaction and timeout handling
--------------------------------------------------------------------

local function inject_interaction()
    if not pending then
        return
    end

    pending.open_token = (pending.open_token or 0) + 1
    local token = pending.open_token
    local serial = pending.serial
    local chapter = pending.chapter

    pending.stage = 'opening'
    update_status()

    debug(string.format(
        'OPEN token=%d chapter=%s retry=%d',
        token,
        tostring(chapter),
        pending.interaction_retries or 0
    ))

    local interact = packets.new('outgoing', 0x01A, {
        ['Target'] = pending.npc_id,
        ['Target Index'] = pending.npc_index,
    })

    packets.inject(interact)

    coroutine.schedule(function()
        if not pending
        or pending.serial ~= serial
        or pending.open_token ~= token
        or pending.stage ~= 'opening' then
            return
        end

        pending.interaction_retries =
            (pending.interaction_retries or 0) + 1

        if pending.interaction_retries <= MAX_INTERACTION_RETRIES then
            msg(string.format(
                'Monisette did not answer for Chapter %s; retrying (%d/%d)...',
                tostring(pending.chapter or 'scan'),
                pending.interaction_retries,
                MAX_INTERACTION_RETRIES
            ))

            log(string.format(
                'AUTO RETRY chapter=%s old_token=%d retry=%d',
                tostring(pending.chapter),
                token,
                pending.interaction_retries
            ))

            coroutine.schedule(function()
                if pending and pending.serial == serial then
                    inject_interaction()
                end
            end, NEXT_REQUEST_DELAY)
        else
            pending.stage = 'paused_timeout'
            update_status()

            msg(string.format(
                'Paused: Monisette timed out on Chapter %s.',
                tostring(pending.chapter or 'scan')
            ))
            msg('Use //rr retry to retry this step, or //rr stop to stop.')

            log(string.format(
                'PAUSED TIMEOUT chapter=%s token=%d',
                tostring(pending.chapter),
                token
            ))
        end
    end, INTERACTION_TIMEOUT)
end

local function advance_plan()
    if not pending or not pending.plan then
        return
    end

    pending.plan_index = pending.plan_index + 1

    local entry = set_current_plan_entry()

    if not entry then
        finalize_success()
        return
    end

    pending.interaction_retries = 0
    pending.stage = 'between'
    update_status()

    debug(string.format(
        'ADVANCE index=%d chapter=%d planned=%d',
        pending.plan_index,
        entry.chapter,
        entry.amount
    ))

    local serial = pending.serial

    coroutine.schedule(function()
        if pending and pending.serial == serial then
            inject_interaction()
        end
    end, NEXT_REQUEST_DELAY)
end

--------------------------------------------------------------------
-- Dialog choice injection
--------------------------------------------------------------------

local function send_choice(serial)
    if not pending
    or pending.serial ~= serial
    or pending.stage ~= 'validated' then
        return
    end

    local option = pending.amount * 256 + pending.chapter

    local packet = packets.new('outgoing', 0x05B, {
        ['Target'] = pending.npc_id,
        ['Option Index'] = option,
        ['_unknown1'] = 0,
        ['Target Index'] = pending.npc_index,
        ['Automated Message'] = false,
        ['_unknown2'] = 0,
        ['Zone'] = PORT_JEUNO_ZONE,
        ['Menu ID'] = pending.menu_id,
    })

    pending.option = option
    pending.stage = 'sent'
    update_status()

    log(string.format(
        'SEND mode=%s menu=%d ch=%d amount=%d stored=%d option=%d',
        tostring(pending.mode),
        pending.menu_id,
        pending.chapter,
        pending.amount,
        pending.stored,
        option
    ))

    packets.inject(packet)
end

--------------------------------------------------------------------
-- Request start helpers
--------------------------------------------------------------------

local function get_ready_monissette()
    if zone_id() ~= PORT_JEUNO_ZONE then
        msg('You must be in Port Jeuno.')
        return nil
    end

    local npc, d2 = find_monissette()

    if not npc then
        msg('Monisette is not loaded. Move closer to her.')
        return nil
    end

    if d2 > MAX_DISTANCE_SQUARED then
        msg('Move closer to Monisette.')
        return nil
    end

    return npc
end

local function begin_pending(request)
    if pending then
        msg('A request is already active. Use //rr stop first.')
        return false
    end

    local npc = get_ready_monissette()
    if not npc then
        return false
    end

    serial_counter = serial_counter + 1

    request.serial = serial_counter
    request.npc_id = npc.id
    request.npc_index = npc.index
    request.stage = 'starting'
    request.total_retrieved = 0
    request.retrieved_by_chapter = zero_amounts()
    request.interaction_retries = 0
    request.open_token = 0
    request.stop_after_release = false

    pending = request
    update_status()
    inject_interaction()
    return true
end

local function start_single(chapter, quantity)
    local request = {
        mode = 'single',
        chapter = chapter,
        quantity = quantity,
    }

    if quantity == 'all' then
        msg(string.format('Requesting ALL stored Chapter %d tales...', chapter))
        log(string.format('START mode=chapter_all ch=%d', chapter))
    else
        msg(string.format('Requesting %d x Chapter %d...', quantity, chapter))
        log(string.format('START mode=single ch=%d qty=%d', chapter, quantity))
    end

    begin_pending(request)
end

local function start_all(selected_chapters)
    local request = {
        mode = selected_chapters and 'selected_all' or 'all',
        selected_chapters = selected_chapters,
        chapter = nil,
        quantity = 'all',
        plan = nil,
        plan_index = 0,
        planned_total = nil,
        preflight_done = false,
    }

    if selected_chapters then
        local labels = {}
        for _, chapter in ipairs(selected_chapters) do
            labels[#labels + 1] = tostring(chapter)
        end
        msg('Requesting ALL stored tales for Chapters ' .. table.concat(labels, ', ') .. '...')
        log('START mode=selected_all chapters=' .. table.concat(labels, ','))
    else
        msg('Requesting ALL stored Rem\'s Tales...')
        log('START mode=all')
    end

    begin_pending(request)
end

local function start_queue(specs)
    local request = {
        mode = 'queue',
        queue_specs = specs,
        chapter = nil,
        quantity = nil,
        plan = nil,
        plan_index = 0,
        planned_total = nil,
        preflight_done = false,
    }

    local labels = {}
    for _, spec in ipairs(specs) do
        labels[#labels + 1] = string.format('Ch%d x%s', spec.chapter, tostring(spec.quantity))
    end

    msg('Queued: ' .. table.concat(labels, ' | '))
    log('START mode=queue ' .. table.concat(labels, ';'))
    begin_pending(request)
end

local function start_inspection(kind)
    local request = {
        mode = 'inspect',
        inspect_kind = kind,
        chapter = nil,
        quantity = nil,
    }

    msg('Reading Monisette...')
    log('START inspect=' .. tostring(kind))
    begin_pending(request)
end

--------------------------------------------------------------------
-- Parser helpers
--------------------------------------------------------------------

local function parse_selected_chapters(args, start_index)
    local result = {}
    local seen = {}

    for i = start_index, #args do
        local chapter = integer(args[i])

        if not chapter or chapter < 1 or chapter > 10 then
            return nil, 'Selected chapters must be numbers from 1 through 10.'
        end

        if not seen[chapter] then
            seen[chapter] = true
            result[#result + 1] = chapter
        end
    end

    table.sort(result)
    return result
end

local function parse_queue(args)
    if #args % 2 ~= 0 then
        return nil, 'Queued requests must be chapter/quantity pairs.'
    end

    local specs = {}

    for i = 1, #args, 2 do
        local chapter = integer(args[i])

        if not chapter or chapter < 1 or chapter > 10 then
            return nil, 'Queue chapters must be 1 through 10.'
        end

        local raw_qty = tostring(args[i + 1]):lower()
        local quantity

        if raw_qty == 'all' then
            quantity = 'all'
        else
            quantity = integer(args[i + 1])

            if not quantity or quantity < 1 or quantity > MAX_QUANTITY then
                return nil, 'Queue quantities must be 1 through 255, or "all".'
            end
        end

        specs[#specs + 1] = {
            chapter = chapter,
            quantity = quantity,
        }
    end

    return specs
end

--------------------------------------------------------------------
-- Command handler
--------------------------------------------------------------------

windower.register_event('addon command', function(...)
    local args = {...}

    if not args[1] then
        help()
        return
    end

    local first = tostring(args[1]):lower()

    if first == 'status' then
        if pending then
            msg(string.format(
                'Active: %s | Chapter %s | stage=%s | retrieved=%d/%s.',
                mode_label(),
                tostring(pending.chapter or '-'),
                tostring(pending.stage),
                pending.total_retrieved or 0,
                tostring(pending.planned_total or '?')
            ))
        else
            msg('Idle.')
        end

        if debug_privilege_active() then
            msg('Debug privilege: ACTIVE | logging: ' .. (debug_enabled and 'ON' or 'OFF'))
        else
            if debug_enabled then
                revoke_debug_if_needed()
            end
            msg('Debug privilege: LOCKED')
        end

        return
    end

    if first == 'stop' or first == 'cancel' then
        if not pending then
            msg('No active request.')
            return
        end

        if pending.stage == 'sent' then
            pending.stop_after_release = true
            update_status()
            msg('Stop requested. The current retrieval was already sent; stopping after it completes.')
            log('STOP REQUESTED after current sent choice')
        else
            finalize_stopped()
        end
        return
    end

    if first == 'retry' then
        if not pending then
            msg('No active request to retry.')
            return
        end

        if pending.stage == 'sent' then
            msg('The current retrieval choice was already sent. Wait for it to complete.')
            return
        end

        if pending.stage == 'validated' then
            msg('The current retrieval is already being processed.')
            return
        end

        pending.interaction_retries = 0
        pending.open_token = (pending.open_token or 0) + 1
        msg('Retrying the current Monisette step...')
        log('MANUAL RETRY chapter=' .. tostring(pending.chapter))
        inject_interaction()
        return
    end

    if first == 'debug' then
        if debug_enabled then
            debug_enabled = false
            log('[DEBUG] Debug logging disabled by user.')
            msg('Debug logging OFF.')
            return
        end

        if not debug_privilege_active() then
            msg('Debug privilege is LOCKED.')
            msg('Load the companion first: //lua load RemsReceiverDebug')
            msg('Then run //rr debug again.')
            return
        end

        debug_enabled = true
        log('[DEBUG] Debug logging enabled with companion privilege.')
        msg('Debug logging ON (privileged).')
        return
    end

    if first == 'hud' then
        local value = args[2] and tostring(args[2]):lower() or nil

        if value == 'on' then
            hud_enabled = true
            msg('HUD ON.')
            update_status()
        elseif value == 'off' then
            hud_enabled = false
            status_box:hide()
            msg('HUD OFF.')
        else
            msg('HUD is ' .. (hud_enabled and 'ON.' or 'OFF.'))
            msg('Use //rr hud on or //rr hud off')
        end
        return
    end

    if first == 'notify' then
        local value = args[2] and tostring(args[2]):lower() or nil

        if value == 'on' then
            notify_enabled = true
            msg('Finish notification ON.')
        elseif value == 'off' then
            notify_enabled = false
            msg('Finish notification OFF.')
        else
            msg('Finish notification is ' .. (notify_enabled and 'ON.' or 'OFF.'))
            msg('Use //rr notify on or //rr notify off')
        end
        return
    end

    if first == 'clearlog' then
        clear_log()
        return
    end

    if first == 'help' then
        help()
        return
    end

    if first == 'list' or first == 'space' or first == 'missing' then
        start_inspection(first)
        return
    end

    ----------------------------------------------------------------
    -- //rr all
    -- //rr all 1 2 5 6
    ----------------------------------------------------------------

    if first == 'all' then
        if #args == 1 then
            start_all(nil)
            return
        end

        local selected, err = parse_selected_chapters(args, 2)
        if not selected then
            msg(err)
            return
        end

        if #selected == 0 then
            msg('No chapters selected.')
            return
        end

        start_all(selected)
        return
    end

    ----------------------------------------------------------------
    -- Single pair or multi-pair queue.
    -- //rr 1 5
    -- //rr 1 all
    -- //rr 1 5 2 3 6 all
    ----------------------------------------------------------------

    local specs, err = parse_queue(args)

    if not specs then
        msg(err)
        help()
        return
    end

    if #specs == 1 then
        start_single(specs[1].chapter, specs[1].quantity)
    else
        start_queue(specs)
    end
end)

--------------------------------------------------------------------
-- Incoming packet handler
--------------------------------------------------------------------

windower.register_event('incoming chunk', function(id, data)
    ----------------------------------------------------------------
    -- Monisette menu
    ----------------------------------------------------------------

    if id == 0x034 and pending and pending.stage == 'opening' then
        local ok, p = pcall(packets.parse, 'incoming', data)

        if not ok or not p then
            return
        end

        if p['NPC'] ~= pending.npc_id
        or p['NPC Index'] ~= pending.npc_index
        or p['Zone'] ~= PORT_JEUNO_ZONE then
            return
        end

        local menu_id = p['Menu ID']

        debug(string.format(
            'MENU ARRIVED token=%s chapter=%s menu=%s',
            tostring(pending.open_token),
            tostring(pending.chapter),
            tostring(menu_id)
        ))

        if not VALID_REMS_MENUS[menu_id] then
            msg(string.format(
                'Safety stop: unsupported Monisette menu %s.',
                tostring(menu_id)
            ))
            msg('No retrieval packet was sent.')
            abort('unsupported menu ' .. tostring(menu_id))
            return
        end

        local counts = chapter_counts(p['Menu Parameters'])

        if not counts then
            msg('Safety stop: invalid Rem\'s Tale count block.')
            msg('No retrieval packet was sent.')
            abort('invalid count block')
            return
        end

        debug('Menu=' .. tostring(menu_id) .. ' Counts=' .. counts_to_string(counts))

        ----------------------------------------------------------------
        -- Read-only inspection commands.
        -- We deliberately do NOT block the menu or inject a choice.
        ----------------------------------------------------------------

        if pending.mode == 'inspect' then
            local kind = pending.inspect_kind

            if kind == 'list' then
                print_stored_list(counts)
            elseif kind == 'space' then
                print_space_report(counts)
            elseif kind == 'missing' then
                print_stored_list(counts)
                print_space_report(counts)
            end

            msg('Inspection complete; close Monisette\'s menu normally.')
            log('INSPECT COMPLETE kind=' .. tostring(kind) .. ' counts=' .. counts_to_string(counts))
            clear_pending()
            return
        end

        ----------------------------------------------------------------
        -- Build and preflight multi-request plans on the first menu.
        ----------------------------------------------------------------

        if (pending.mode == 'all'
        or pending.mode == 'selected_all'
        or pending.mode == 'queue')
        and not pending.preflight_done then
            local plan
            local amounts

            if pending.mode == 'all' then
                plan, amounts = build_all_plan(counts, nil)
            elseif pending.mode == 'selected_all' then
                plan, amounts = build_all_plan(counts, pending.selected_chapters)
            else
                plan, amounts = build_queue_plan(counts, pending.queue_specs)
            end

            local total = total_counts(amounts)

            if total <= 0 or #plan == 0 then
                msg('None of the requested Rem\'s Tales are stored.')
                abort('nothing requested is stored')
                return
            end

            local fits, snapshot, detail, err = inventory_can_hold(amounts)

            if not fits then
                msg('Inventory check FAILED for the complete request.')
                msg(tostring(err))
                msg(string.format(
                    'Requested retrieval total: %d. Nothing was retrieved.',
                    total
                ))

                if snapshot then
                    log(string.format(
                        'PREFLIGHT SPACE FAIL mode=%s total=%d free_slots=%d',
                        pending.mode,
                        total,
                        snapshot.free_slots
                    ))
                end

                abort('not enough inventory for complete request')
                return
            end

            pending.plan = plan
            pending.plan_index = 1
            pending.planned_amounts = amounts
            pending.planned_total = total
            pending.preflight_done = true
            set_current_plan_entry()
            update_status()

            local needed = slots_needed_for(amounts, snapshot)

            msg(string.format(
                'Inventory check OK: %d total tales, %d new slot%s needed, %d free.',
                total,
                needed,
                needed == 1 and '' or 's',
                snapshot.free_slots
            ))

            log(string.format(
                'PREFLIGHT OK mode=%s total=%d slots=%d free=%d plan=%d',
                pending.mode,
                total,
                needed,
                snapshot.free_slots,
                #plan
            ))
        end

        ----------------------------------------------------------------
        -- Determine current chapter and amount.
        ----------------------------------------------------------------

        local chapter = pending.chapter

        if not chapter then
            msg('Internal error: no chapter selected.')
            abort('missing chapter')
            return
        end

        local stored = counts[chapter] or 0
        local amount

        if pending.mode == 'all'
        or pending.mode == 'selected_all'
        or pending.mode == 'queue' then
            amount = math.min(pending.planned_amount or 0, stored)
        elseif pending.quantity == 'all' then
            amount = stored
        else
            amount = math.min(pending.quantity, stored)
        end

        if amount <= 0 then
            -- Initial zero chapters never enter multi plans. If a planned
            -- chapter becomes zero unexpectedly, abort rather than inventing
            -- a packet or leaving a blocked menu in an unknown state.
            if pending.mode == 'all'
            or pending.mode == 'selected_all'
            or pending.mode == 'queue' then
                msg(string.format(
                    'Chapter %d changed before retrieval; stopping safely.',
                    chapter
                ))
                abort('planned chapter became zero')
                return
            end

            msg(string.format(
                'Monisette has 0 Chapter %d tales stored.',
                chapter
            ))
            abort('zero stored')
            return
        end

        ----------------------------------------------------------------
        -- Per-chapter inventory recheck immediately before receiving.
        ----------------------------------------------------------------

        local current_amounts = single_amount_table(chapter, amount)
        local fits, snapshot, detail, err = inventory_can_hold(current_amounts)

        if not fits then
            msg(string.format('Inventory check FAILED for Chapter %d.', chapter))
            msg(tostring(err))
            msg('No retrieval packet was sent.')
            abort('not enough inventory for current chapter')
            return
        end

        pending.menu_id = menu_id
        pending.stored = stored
        pending.amount = amount
        pending.stage = 'validated'
        update_status()

        if pending.mode == 'all' or pending.mode == 'selected_all' then
            msg(string.format(
                'Chapter %d: receiving all %d stored.',
                chapter,
                amount
            ))
        elseif pending.mode == 'queue' then
            msg(string.format(
                'Queue %d/%d: receiving %d x Chapter %d.',
                pending.plan_index,
                #pending.plan,
                amount,
                chapter
            ))
        elseif pending.quantity == 'all' then
            msg(string.format(
                'Chapter %d: receiving ALL %d stored.',
                chapter,
                amount
            ))
        elseif amount < pending.quantity then
            msg(string.format(
                'Only %d Chapter %d stored; receiving %d.',
                stored,
                chapter,
                amount
            ))
        else
            msg(string.format(
                'Inventory OK. Receiving %d x Chapter %d.',
                amount,
                chapter
            ))
        end

        local serial = pending.serial

        coroutine.schedule(function()
            send_choice(serial)
        end, 0.10)

        -- Only block a positively validated automated Rem menu.
        return true
    end

    ----------------------------------------------------------------
    -- NPC release after successful retrieval
    ----------------------------------------------------------------

    if id == 0x052 and pending and pending.stage == 'sent' then
        local chapter = pending.chapter
        local amount = pending.amount
        local menu_id = pending.menu_id
        local option = pending.option

        pending.total_retrieved = (pending.total_retrieved or 0) + amount
        pending.retrieved_by_chapter[chapter] =
            (pending.retrieved_by_chapter[chapter] or 0) + amount

        log(string.format(
            'COMPLETE menu=%d ch=%d amount=%d option=%d total=%d',
            menu_id,
            chapter,
            amount,
            option,
            pending.total_retrieved
        ))

        update_status()

        if pending.stop_after_release then
            finalize_stopped()
            return
        end

        if pending.mode == 'all'
        or pending.mode == 'selected_all'
        or pending.mode == 'queue' then
            msg(string.format(
                'Received %d x Chapter %d. Total so far: %d/%d.',
                amount,
                chapter,
                pending.total_retrieved,
                pending.planned_total or pending.total_retrieved
            ))

            advance_plan()
            return
        end

        finalize_success()
    end
end)

--------------------------------------------------------------------
-- Debug privilege watchdog
--------------------------------------------------------------------

local last_debug_privilege_check = 0

windower.register_event('prerender', function()
    if not debug_enabled then
        return
    end

    local now = os.time()

    if now == last_debug_privilege_check then
        return
    end

    last_debug_privilege_check = now

    if revoke_debug_if_needed() then
        msg('Debug privilege expired; debug logging automatically disabled.')
    end
end)

--------------------------------------------------------------------
-- Zone / unload safety
--------------------------------------------------------------------

windower.register_event('zone change', function()
    if pending then
        abort('zone change')
    end
end)

windower.register_event('unload', function()
    status_box:hide()
end)

--------------------------------------------------------------------
-- Load
--------------------------------------------------------------------

log('------------------------------------------------------------')
log('Rems Receiver v' .. tostring(_addon.version) .. ' loaded.')
log('Valid menus: 385 normal, 387 gear-traded')

msg('Rems Receiver v' .. tostring(_addon.version) .. ' loaded.')
msg('Debug privilege is locked unless RemsReceiverDebug is loaded.')
msg('Use //rr help for commands.')
