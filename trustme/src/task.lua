local chat = require('chat')
local taskTypes = require('data.taskTypes')
local trustData = require('data.trustData')

local task = {}
-- This is recovery AFTER an observed completion, never an estimate of cast time.
-- FFXI may reject another /ma after the previous spell completes. Rejected
-- commands must remain pending; completion is not permission to discard them.
local RECOVERY_MS = 3000
local ACK_MS = 1500
local MAX_ATTEMPTS = 5
local VERIFY_MS = RECOVERY_MS + 1000
local CAST_TIMEOUT_MS = 12000
local MAX_VERIFY_RETRIES = 2
local active, playerId, zoneId, externalCast
local completedId, completedAt
local readyAt, debugEnabled, paused, waitReason = 0, false, nil, nil

local function nowMs()
    return tonumber(ashita.time.get_tick64())
end

local function log(message, warning)
    print(chat.header(addon.name):append((warning and chat.warning or chat.message)(message)))
end

local function debugLog(message)
    if debugEnabled then log(string.format('[queue %.3f] %s', nowMs() / 1000, message)) end
end

-- Party names omit spaces and the spell-only Unity suffix, e.g. KingofHearts
-- and Yoran-Oran. Keep II distinct from the original trust.
local function key(name)
    return tostring(name or ''):lower():gsub('%s*%(uc%)', ''):gsub('[^%w]', '')
end

local byName = {}
for id, entry in pairs(trustData) do byName[key(entry.en)] = { id = id, data = entry } end

local function state()
    local mm = AshitaCore:GetMemoryManager()
    local party, player, entity = mm:GetParty(), mm:GetPlayer(), mm:GetEntity()
    local index = party:GetMemberTargetIndex(0)
    local s = {
        id = party:GetMemberServerId(0), zone = party:GetMemberZone(0),
        zoning = player:GetIsZoning() ~= 0, hp = party:GetMemberHP(0),
        status = entity:GetStatus(index),
        moving = mm:GetTarget():GetIsPlayerMoving() ~= 0,
        names = {}, ids = {}, count = 0, player = player, recast = mm:GetRecast(),
    }
    for i = 0, 5 do
        if party:GetMemberIsActive(i) ~= 0 and party:GetMemberServerId(i) ~= 0 then
            s.count = s.count + 1
            if i > 0 then
                local id = party:GetMemberServerId(i)
                s.names[key(party:GetMemberName(i))] = id
                s.ids[id] = true
            end
        end
    end
    return s
end

-- The spell's II suffix is not necessarily part of the NPC/party name.
-- Live example: Arciela II casts successfully and joins as "Arciela".
-- Keep spell keys distinct. During a summon, accept a base-name alias only
-- for a newly joined server ID, never for an unrelated pre-existing member.
local function partyMatch(s, name, beforeIds)
    local canonical = key(name)
    if s.names[canonical] then return canonical end
    local base = tostring(name):match('^(.-)%s+II$')
    local alias = base and key(base)
    local id = alias and s.names[alias]
    if id and (beforeIds == nil or not beforeIds[id]) then return alias end
end

local function removeEntry(entry)
    for i, queued in ipairs(tme.queue) do
        if queued == entry then table.remove(tme.queue, i); return end
    end
end

local function recover(at)
    readyAt = math.max(readyAt, at + RECOVERY_MS)
end

local function pause(reason)
    if paused == nil then
        paused = reason
        log('Queue paused: ' .. reason .. ' Pending trusts kept. Use /tme resume or /tme clear.', true)
    end
end

local function waitFor(reason)
    if waitReason ~= reason then
        waitReason = reason
        if reason then log('Waiting: ' .. reason .. '. Use /tme clear to cancel.', true) end
    end
end

local function confirm(reason)
    local a = active
    debugLog(a.entry.trustName .. ': confirmed (' .. (reason or 'party') .. ')')
    -- If the completion packet was unavailable, membership is an independent
    -- completion signal. Use the first observation, never unrelated growth.
    if not a.finishedAt then recover(nowMs()) end
    removeEntry(a.entry)
    active, paused, waitReason = nil, nil, nil
end

local function send(s, now, verification)
    local a = active
    if verification then a.verifyRetries = a.verifyRetries + 1
    else a.attempts = a.attempts + 1 end
    a.phase, a.sentAt, a.deadline = verification and 'probe' or 'requested', now, now + ACK_MS
    a.beforeIds = a.beforeIds or s.ids
    a.beforeRecast = s.recast:GetSpellTimer(a.id)
    debugLog(string.format('%s: %s %d', a.entry.trustName,
        verification and 'verification retry' or 'request', verification and a.verifyRetries or a.attempts))
    AshitaCore:GetChatManager():QueueCommand(-1, string.format('/ma "%s" <me>', a.name))
end

function task.enqueue(entry)
    local resolved = byName[key(entry.trustName)]
    if entry.type ~= taskTypes.summon or not resolved then
        log('Unknown trust: ' .. tostring(entry.trustName), true)
        return false
    end
    for _, queued in ipairs(tme.queue) do
        if key(queued.trustName) == key(entry.trustName) then return false end
    end
    -- Includes the in-flight entry so the UI and duplicate check see it too.
    tme.queue[#tme.queue + 1] = entry
    return true
end

function task.handleQueue()
    if #tme.queue == 0 and active == nil then return end
    local now, s = nowMs(), state()
    if s.zoning or s.id == 0 or s.hp == 0
        or (playerId and (s.id ~= playerId or s.zone ~= zoneId)) then
        task.clear('zone, character, or life state changed', true)
        return
    end
    playerId, zoneId = s.id, s.zone

    if active then
        local match = partyMatch(s, active.name, active.beforeIds)
        if match then confirm('party ' .. match); return end
        local recast = s.recast:GetSpellTimer(active.id)
        if active.attempts > 0 and recast > active.beforeRecast then
            active.recastSeen = true
            if not active.finishedAt then
                active.finishedAt, active.phase, active.deadline = now, 'verifying', now + VERIFY_MS
                recover(now)
                debugLog(active.entry.trustName .. ': recast started; checking party')
            end
        end
        -- UI cancellation removes the entry, but cannot recall a command already
        -- sent to FFXI. Drain that attempt before starting anything else.
        if active.completionSeen and active.recastSeen then
            confirm('matching completed Trust spell and recast'); return
        end
        if active.phase == 'verifying' then
            if now < active.deadline then return end
            active.phase = 'probe_ready'
        elseif active.phase == 'casting' then
            if now < active.deadline then return end
            -- A stale start signal must not become a permanent gate. Retry
            -- the same trust after a generous cast watchdog, not the next one.
            active.phase, active.deadline = 'requested', now
            recover(now)
            debugLog(active.entry.trustName .. ': cast result missing; retrying same trust')
        end
        if active.phase == 'requested' and now < active.deadline then return end
        if active.phase == 'probe' and now < active.deadline then return end
    end
    if paused then return end
    if externalCast then
        if now >= externalCast.deadline then pause('another player action has not completed') end
        return
    end
    if now < readyAt then return end
    if s.status ~= 0 then waitFor('stand idle and leave combat'); return end
    if s.moving then waitFor('stop moving to summon'); return end
    if active and not task.contains(active.entry) then active = nil end
    if active and (active.phase == 'probe_ready' or active.phase == 'probe') then
        if active.verifyRetries >= MAX_VERIFY_RETRIES then
            pause(active.entry.trustName .. ': no confirmation after two verification retries')
            return
        end
        -- Two ordinary /ma rechecks only. They may be rejected by the game's
        -- recast/duplicate rules; never inject packets or send per frame.
        waitFor(nil)
        send(s, now, true)
        return
    end
    if active == nil then
        local entry = tme.queue[1]
        if not entry then return end
        local resolved = byName[key(entry.trustName)]
        local match = partyMatch(s, entry.trustName)
        if match then
            if match ~= key(entry.trustName) then
                log(entry.trustName .. ': ' .. match .. ' is already in the party; skipping this trust family.')
            else debugLog(entry.trustName .. ': already in party') end
            removeEntry(entry); return
        end
        if not s.player:HasSpell(resolved.id) then
            log('Skipping unlearned trust: ' .. entry.trustName, true)
            removeEntry(entry); return
        end
        active = { entry = entry, id = resolved.id, name = resolved.data.en,
            castMs = (resolved.data.cast_time or 2) * 1000,
            attempts = 0, verifyRetries = 0, phase = 'ready', beforeRecast = s.recast:GetSpellTimer(resolved.id) }
    end
    if s.count >= 6 then pause('party is full'); return end
    local recast = s.recast:GetSpellTimer(active.id)
    if recast > 0 then waitFor(active.entry.trustName .. ' recast'); return end
    if active.attempts >= MAX_ATTEMPTS then
        pause(active.entry.trustName .. ': summon was not accepted after ' .. MAX_ATTEMPTS .. ' attempts')
        return
    end
    waitFor(nil)
    send(s, now)
end

function task.contains(entry)
    for _, queued in ipairs(tme.queue) do if queued == entry then return true end end
    return false
end

-- Ashita's incoming 0x028 layout; the first target's action parameter at bit
-- 213 identifies a STARTING spell. The header ID identifies a FINISHED spell.
-- Bounds are checked before each optional read. Never silently swallow errors.
function task.handleActionPacket(e)
    if e.id == 0x00B or e.id == 0x00A then
        task.clear('zone changed', true)
        return
    end
    if e.id ~= 0x028 or e.data_raw == nil or e.size < 14 then return end
    local actor = ashita.bits.unpack_be(e.data_raw, 0, 40, 32)
    if actor == 0 or actor ~= AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0) then return end
    local category = ashita.bits.unpack_be(e.data_raw, 0, 82, 4)
    local param = ashita.bits.unpack_be(e.data_raw, 0, 86, 17)
    local now = nowMs()
    if category == 8 and param == 0x6163 and e.size >= 29 then
        local id = ashita.bits.unpack_be(e.data_raw, 0, 213, 17)
        if id == completedId and now - completedAt < RECOVERY_MS
            and AshitaCore:GetMemoryManager():GetRecast():GetSpellTimer(id) > 0 then
            debugLog('Ignoring stale start for completed spell ' .. id)
            return
        end
        if active and active.id == id and active.attempts > 0 then
            if active.finishedAt and active.phase ~= 'probe' then return end
            if active.phase == 'probe' then
                active.finishedAt, active.completionSeen, active.recastSeen = nil, nil, nil
            end
            active.phase = 'casting'
            active.deadline = now + math.max(CAST_TIMEOUT_MS, active.castMs * 3 + 5000)
            debugLog(active.entry.trustName .. ': cast accepted')
        elseif #tme.queue > 0 or active then
            externalCast = { id = id, deadline = now + 60000 }
            debugLog('Waiting for other spell ' .. id)
        end
    elseif category == 4 then
        completedId, completedAt = param, now
        recover(now)
        if externalCast and externalCast.id == param then externalCast = nil end
        if active and active.id == param and active.attempts > 0 then
            -- A matched completed spell plus its new recast is an independent
            -- confirmation when roster names are missing. Require a self-target
            -- result with a normal success message, not merely category 4.
            if e.size >= 30 and ashita.bits.unpack_be(e.data_raw, 0, 72, 6) > 0
                and ashita.bits.unpack_be(e.data_raw, 0, 182, 4) > 0 then
                local target = ashita.bits.unpack_be(e.data_raw, 0, 150, 32)
                local message = ashita.bits.unpack_be(e.data_raw, 0, 230, 10)
                local result = ashita.bits.unpack_be(e.data_raw, 0, 213, 17)
                active.completionSeen = target == actor and result == 0 and (message == 0 or message == 42)
                debugLog(string.format('%s: completion result message=%d target=%d', active.entry.trustName, message, target))
            end
            if not active.finishedAt then
                active.finishedAt, active.phase, active.deadline = now, 'verifying', now + VERIFY_MS
                debugLog(active.entry.trustName .. ': spell finished; checking party')
            end
        end
    elseif category == 8 and param == 0x6F73 then
        recover(now)
        if externalCast then externalCast = nil
        elseif active and active.phase == 'casting' then
            active.phase, active.deadline = 'requested', now + RECOVERY_MS
            debugLog(active.entry.trustName .. ': interrupted; retained for retry')
        end
    end
end

function task.clear(reason, reset)
    local count = #tme.queue
    tme.queue, tme.eta, paused, waitReason = {}, 0, nil, nil
    if reset then
        active, externalCast, playerId, zoneId, readyAt = nil, nil, nil, nil, 0
        completedId, completedAt = nil, nil
    elseif active and active.attempts == 0 then active = nil end
    if count > 0 then log('Cleared ' .. count .. ' queued trusts' .. (reason and (': ' .. reason) or '') .. '.', true) end
end

function task.resume()
    -- Explicit recovery after bounded automatic retries were exhausted.
    paused, waitReason, externalCast = nil, nil, nil
    if active then
        active.phase, active.attempts, active.finishedAt = 'ready', 0, nil
        active.verifyRetries, active.completionSeen, active.recastSeen = 0, nil, nil
        active.beforeRecast = AshitaCore:GetMemoryManager():GetRecast():GetSpellTimer(active.id)
    end
    recover(nowMs())
    log('Queue resumed; existing party members and recasts will be checked.')
end

function task.setDebug(value)
    debugEnabled = value == 'on' or (value ~= 'off' and not debugEnabled)
    log('Queue debug ' .. (debugEnabled and 'on' or 'off') .. '.')
end

function task.status()
    local remaining = math.max(0, readyAt - nowMs()) / 1000
    return string.format('%d queued | %s%s', #tme.queue,
        paused and ('paused: ' .. paused) or waitReason or
        (active and (active.entry.trustName .. ': ' .. active.phase)) or
        (externalCast and 'waiting for another spell') or (remaining > 0 and string.format('recovery %.1fs', remaining)) or 'ready',
        active and string.format(' | attempt %d/%d%s', active.attempts, MAX_ATTEMPTS,
            active.verifyRetries > 0 and string.format(' | recheck %d/%d', active.verifyRetries, MAX_VERIFY_RETRIES) or '') or '')
end

function task.printStatus()
    log(addon.version .. ' | ' .. task.status())
    local mm = AshitaCore:GetMemoryManager()
    local index = mm:GetParty():GetMemberTargetIndex(0)
    -- Diagnostic only: these animation/action counters have not been validated
    -- as a global magic-ready flag on this client. Never hard-gate on them.
    log(string.format('Action counters: %s / %s', tostring(mm:GetEntity():GetActionTimer1(index)), tostring(mm:GetEntity():GetActionTimer2(index))))
    local partyNames = {}
    for i = 1, 5 do
        local p = mm:GetParty()
        partyNames[#partyNames + 1] = string.format('%d:%s(id=%s,active=%s)', i,
            p:GetMemberName(i), tostring(p:GetMemberServerId(i)), tostring(p:GetMemberIsActive(i)))
    end
    log('Party: ' .. table.concat(partyNames, ', '))
end

return task
