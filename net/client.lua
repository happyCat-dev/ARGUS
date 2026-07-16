-- Client role: answer the server's polls with this base's readings.
--
-- Sends finished NUMBERS, not component proxies. Proxying calls across the
-- network would be the obvious-looking design and is a trap: components are not
-- visible off their own network (by design — see DETAILS.md), and even faking it
-- would pay a round trip per getter.
--
-- Pull, not push: the server asks. That keeps the rate under the server's
-- control, avoids a broadcast storm when several bases start at once, and lets
-- a client reboot without anyone tracking subscriptions.

local serialization = require("serialization")

local monitorLib = require("core.monitor")

local client = {}
client.__index = client

-- One message carries the whole base. Well under the 8192-byte default packet
-- size for any sane number of buffers, but truncate rather than have the send
-- silently fail and the base look offline.
local MAX_BUFFERS = 24

function client.new(config, transport)
    return setmetatable({
        config = config,
        transport = transport,
        lastAnswer = nil,
    }, client)
end

-- Trim a view down to what the server needs to render it. Dropping the tracker
-- matters: it holds hundreds of samples and must never reach the wire.
local function summarise(view)
    return {
        id = view.id,
        name = view.name,
        kind = view.kind,
        state = view.state,
        stored = view.stored,
        -- The exact decimal string: an LSC past 2^53 cannot survive as a double,
        -- and serialization would round it silently.
        storedText = view.storedText,
        capacity = view.capacity,
        euIn = view.euIn,
        euOut = view.euOut,
        passiveLoss = view.passiveLoss,
        problems = view.problems,
        -- The client samples far more finely than the server polls it, so its
        -- own long-window averages are better than anything the server could
        -- derive from these snapshots.
        avg5m = view.avg5m,
        avg1h = view.avg1h,
    }
end

function client:payload(monitor)
    local buffers = {}
    for _, view in ipairs(monitor:list()) do
        -- The aggregate is the server's job to compute across every base, and
        -- forwarding another base's data would double-count it.
        if view.id ~= monitorLib.AGGREGATE_ID and not view.remote then
            table.insert(buffers, summarise(view))
            if #buffers >= MAX_BUFFERS then break end
        end
    end
    return {name = self.transport:nodeName(), buffers = buffers}
end

-- Keeps the port open; a card plugged in later would otherwise never listen.
function client:update()
    if self.config.network.role ~= "client" then return end
    self.transport:openPort(self.config.network.port)
end

function client:onMessage(monitor, localAddress, remoteAddress, port, command)
    if self.config.network.role ~= "client" then return false end
    if command ~= "poll" and command ~= "discover" then return false end

    local ok, encoded = pcall(serialization.serialize, self:payload(monitor))
    if not ok then return false end

    self.transport:reply(localAddress, remoteAddress, port, "status", encoded)
    self.lastAnswer = command
    return true
end

return client
