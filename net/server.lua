-- Server role: poll the clients and fold their buffers in with the local ones.
--
-- Remote buffers become ordinary views, so every renderer — dashboard, buffer
-- list, AR card, aggregate — treats them exactly like a local one. The only
-- difference visible in the code is view.remote, used to keep them out of a
-- client's own payload.

local computer = require("computer")
local serialization = require("serialization")

local states = require("core.states")

local server = {}
server.__index = server

function server.new(config, transport)
    return setmetatable({
        config = config,
        transport = transport,
        -- address -> {address, name, lastSeen, distance, buffers}
        nodes = {},
        lastPoll = nil,
    }, server)
end

local function settings(self)
    return self.config.network or {}
end

function server:update(monitor)
    if settings(self).role ~= "server" then return end

    local now = computer.uptime()
    local interval = settings(self).pollInterval or 2

    self.transport:openPort(settings(self).port)

    if not self.lastPoll or (now - self.lastPoll) >= interval then
        self.transport:broadcast(settings(self).port, "poll")
        self.lastPoll = now
    end

    self:publish(monitor, now)
end

-- Hand the remote readings to the monitor, marking anything stale as MISSING.
--
-- Nodes are never dropped on timeout, only marked: a base that went quiet is
-- exactly what the operator needs to see. Wireless has no link-down signal, so
-- silence is the only symptom there is.
function server:publish(monitor, now)
    now = now or computer.uptime()
    local timeout = settings(self).timeout or 15
    local remote = {}

    for address, node in pairs(self.nodes) do
        local offline = (now - node.lastSeen) > timeout
        node.offline = offline

        for _, buffer in ipairs(node.buffers or {}) do
            local entry = {}
            for key, value in pairs(buffer) do entry[key] = value end
            -- Namespaced so two bases with the same machine cannot collide.
            entry.id = "net:" .. address:sub(1, 8) .. ":" .. tostring(buffer.id)
            entry.name = node.name .. " · " .. (buffer.name or "?")
            entry.remote = true
            entry.node = address
            if offline then
                -- Its numbers are last-known and no longer true; showing them as
                -- live would be a lie the operator cannot see through.
                entry.state = states.MISSING
            end
            table.insert(remote, entry)
        end
    end

    monitor:setRemote(remote)
end

function server:onMessage(monitor, localAddress, remoteAddress, port, distance, command, payload)
    if settings(self).role ~= "server" then return false end
    if command ~= "status" then return false end

    local ok, decoded = pcall(serialization.unserialize, payload)
    if not ok or type(decoded) ~= "table" then return false end

    self.nodes[remoteAddress] = {
        address = remoteAddress,
        name = decoded.name or ("node " .. remoteAddress:sub(1, 8)),
        buffers = decoded.buffers or {},
        lastSeen = computer.uptime(),
        distance = tonumber(distance) or 0,
        offline = false,
    }

    self:publish(monitor)
    return true
end

-- Connected clients, for the Network page. Sorted by name so the list does not
-- reshuffle between frames.
function server:list()
    local out = {}
    for _, node in pairs(self.nodes) do table.insert(out, node) end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function server:forget(address)
    self.nodes[address] = nil
end

return server
