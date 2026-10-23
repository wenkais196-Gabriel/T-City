-- server/live_store.lua — in-memory ring buffer for live events (M1).
--
-- Pure Lua (no FiveM/MySQL): loaded by the resource and by the Lua harness.
-- Events are only lost on overflow or resource restart; the DB remains the
-- durable/audit channel.
--
-- Cursor shape is `<epoch>:<seq>` (e.g. "1730000000:42").  The epoch identifies
-- the resource generation; seq starts at 1 and increases by one per event.
-- The ring only stores seq, so a cursor older than the retained window is
-- reported as expired instead of silently returning a gap.

local LiveStore = {}
_G.LiveStore = LiveStore

LiveStore.VERSION = 1
LiveStore.DEFAULT_CAPACITY = 2048
LiveStore.MIN_CAPACITY = 256
LiveStore.MAX_CAPACITY = 8192

LiveStore.__index = LiveStore

local function clampCapacity(value)
    local capacity = tonumber(value)
    if not capacity or capacity ~= capacity then return LiveStore.DEFAULT_CAPACITY end
    capacity = math.floor(capacity)
    if capacity < LiveStore.MIN_CAPACITY then capacity = LiveStore.MIN_CAPACITY end
    if capacity > LiveStore.MAX_CAPACITY then capacity = LiveStore.MAX_CAPACITY end
    return capacity
end

function LiveStore.New(options)
    options = options or {}
    local epoch = options.epoch
    if type(epoch) == 'number' then epoch = tostring(epoch) end
    if type(epoch) ~= 'string' or epoch == '' or epoch:find(':', 1, true) then
        epoch = tostring(os.time())
    end

    local store = setmetatable({
        epoch = epoch,
        seq = 0,
        capacity = clampCapacity(options.capacity),
        dropped = 0,
        items = {},
    }, LiveStore)

    -- Preallocate the ring so pushes do not grow the table.
    for index = 1, store.capacity do store.items[index] = false end
    return store
end

function LiveStore.Default()
    if not LiveStore._default then
        local capacity = LiveStore.DEFAULT_CAPACITY
        if type(GetConvar) == 'function' then
            capacity = tonumber(GetConvar('agent_live_event_buffer', tostring(capacity))) or capacity
        end
        LiveStore._default = LiveStore.New({ capacity = capacity })
    end
    return LiveStore._default
end

function LiveStore:OldestSeq()
    if self.seq == 0 then return 1 end
    local oldest = self.seq - self.capacity + 1
    if oldest < 1 then oldest = 1 end
    return oldest
end

function LiveStore:Encode(seq)
    return self.epoch .. ':' .. tostring(seq)
end

-- Accepts the full cursor and, for convenience, a plain seq number which is
-- interpreted against the current epoch (design 01 §4.3).
function LiveStore:ParseCursor(raw)
    if type(raw) ~= 'string' or raw == '' then return nil, 'invalid_cursor' end

    local plain = raw:match('^(%d+)$')
    if plain then return { epoch = self.epoch, seq = tonumber(plain) } end

    local epoch, seq = raw:match('^([^:]+):(%d+)$')
    if not epoch or epoch == '' then return nil, 'invalid_cursor' end
    return { epoch = epoch, seq = tonumber(seq) }
end

function LiveStore:Push(event)
    event = type(event) == 'table' and event or {}
    self.seq = self.seq + 1

    local payload = type(event.payload) == 'table' and event.payload or {}
    local row = {
        seq = self.seq,
        type = type(event.type) == 'string' and event.type or 'unknown',
        citizenid = type(event.citizenid) == 'string' and event.citizenid or nil,
        at = tonumber(event.at) or (os.time() * 1000),
        payload = payload,
    }

    if self.seq > self.capacity then self.dropped = self.dropped + 1 end
    self.items[((self.seq - 1) % self.capacity) + 1] = row
    return row.seq
end

-- Returns events (ascending) plus meta {next_cursor, newest_seq, oldest_seq,
-- dropped}.  On cursor errors returns nil, {code=...}.
function LiveStore:List(since, limit)
    local maxLimit = self.capacity
    limit = tonumber(limit) or 50
    limit = math.floor(limit)
    if limit < 1 then limit = 1 end
    if limit > maxLimit then limit = maxLimit end

    local oldest = self:OldestSeq()
    local startSeq = oldest
    local lastSeq = 0

    if since then
        if since.epoch ~= self.epoch then
            return nil, {
                code = 'cursor_epoch_mismatch',
                epoch = self.epoch,
                oldest_seq = oldest,
                newest_seq = self.seq,
            }
        end
        local requested = tonumber(since.seq)
        if not requested or requested < 0 then requested = 0 end
        -- A cursor from the future (clock skew, a hand-written seq, or an
        -- epoch reused after a same-second restart) must clamp to newest.
        -- Echoing it back would make next_cursor point past every future
        -- event and strand the consumer forever.
        if requested > self.seq then requested = self.seq end
        if requested < oldest - 1 then
            return nil, {
                code = 'cursor_expired',
                oldest_seq = oldest,
                oldest_cursor = self:Encode(oldest),
            }
        end
        startSeq = requested + 1
        if startSeq < oldest then startSeq = oldest end
        lastSeq = requested
    end

    local events = {}
    if startSeq <= self.seq then
        for seq = startSeq, self.seq do
            if #events >= limit then break end
            local row = self.items[((seq - 1) % self.capacity) + 1]
            if row then
                events[#events + 1] = row
                lastSeq = seq
            end
        end
    end

    return events, {
        epoch = self.epoch,
        newest_seq = self.seq,
        oldest_seq = oldest,
        dropped = self.dropped,
        next_cursor = self:Encode(lastSeq),
        count = #events,
    }
end

function LiveStore:Stats()
    local oldest = self:OldestSeq()
    return {
        epoch = self.epoch,
        seq = self.seq,
        oldest_seq = oldest,
        size = self.seq == 0 and 0 or (self.seq - oldest + 1),
        capacity = self.capacity,
        dropped = self.dropped,
    }
end

return LiveStore
