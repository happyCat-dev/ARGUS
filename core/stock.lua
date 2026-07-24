-- Watches a handful of item/fluid amounts in an Applied Energistics network.
--
-- Reads through the same OpenComputers ME driver as core/craft.lua (an Adapter
-- touching an ME Controller or ME Interface). The GTNH fork's NetworkControl.scala
-- exposes three getters this leans on:
--
--   * getItemInNetwork(name[, damage])  — ONE item, cheap and targeted.
--   * getFluidsInNetwork()              — ALL fluids (a short list, dozens).
--   * getItemsInNetwork([filter])       — the WHOLE inventory (thousands of
--     stacks). Heavy, so it is only pulled on demand for the picker, never in
--     the poll loop.
--
-- The poll path therefore costs one getItemInNetwork per watched item plus a
-- single getFluidsInNetwork when any fluid is watched — a fixed, small number of
-- calls regardless of network size. Watched items are collected as the UNION
-- across every buffer's list, so the same item watched beside two buffers is one
-- call, not two.
--
-- Unlike the LSC's charge, item and fluid counts are plain numbers well under
-- 2^53, so no exact-decimal-string trick is needed here.
--
-- convert() in the driver returns null for a stack it cannot describe, which
-- lands in Lua as a HOLE in the array — every list is walked with pairs(), never
-- ipairs(), which would stop at the first gap and silently under-count.

local component = require("component")

local craft = require("core.craft")
local util = require("core.util")

local stock = {}
stock.__index = stock

stock.ITEM = "item"
stock.FLUID = "fluid"

-- A key that survives being compared between polls and identifies a watched
-- entry. Items are keyed by name+damage (the identity the user picked); fluids
-- have no damage, so name alone.
function stock.key(kind, name, damage)
    if kind == stock.FLUID then
        return "fluid\0" .. tostring(name)
    end
    return "item\0" .. tostring(name) .. "\0" .. tostring(damage or 0)
end

function stock.new(config)
    return setmetatable({
        config = config,
        -- key -> {kind, label, count, present}
        snapshot = {},
        error = nil,
    }, stock)
end

-- Whether the feature is switched on at all. The per-buffer list still governs
-- what a given buffer shows; this is the master switch and the poll gate.
function stock:enabled()
    return not self.config.stock or self.config.stock.enabled ~= false
end

-- First reachable ME proxy that actually exposes the network getters.
--
-- The method check matters: core/craft.lua discovers the same component types,
-- and on a pack with stock (non-GTNH) OpenComputers a controller answers
-- getCpus but not these, so picking the first proxy blindly could land on one
-- that cannot answer at all.
function stock:controller()
    for _, found in ipairs(craft.discover()) do
        local ok, proxy = pcall(component.proxy, found.address)
        if ok and proxy and util.callable(proxy.getItemsInNetwork) then
            return proxy
        end
    end
    return nil
end

-- The union of every buffer's watched entries, unique by key. Only buffers whose
-- own stock list is enabled contribute, and only when the feature is on.
function stock:watched()
    local out, seen = {}, {}
    if not self:enabled() then return out end

    for _, entry in ipairs(self.config.buffers or {}) do
        local list = entry.stock
        if list and list.enabled ~= false and type(list.watch) == "table" then
            for _, w in ipairs(list.watch) do
                if type(w) == "table" and w.name then
                    local key = stock.key(w.kind, w.name, w.damage)
                    if not seen[key] then
                        seen[key] = true
                        table.insert(out, {
                            kind = w.kind or stock.ITEM,
                            name = w.name,
                            damage = w.damage,
                            label = w.label,
                            key = key,
                        })
                    end
                end
            end
        end
    end
    return out
end

-- Poll the network for every watched amount. Cheap and bounded (see the header).
function stock:update()
    self.error = nil
    local wanted = self:watched()
    local snapshot = {}

    if #wanted == 0 then
        self.snapshot = snapshot
        return self
    end

    local proxy = self:controller()
    if not proxy then
        self.error = "no ME controller or interface found"
        self.snapshot = snapshot
        return self
    end

    -- Fluids: one call for all of them, then indexed by name. Only made when a
    -- fluid is actually watched.
    local fluidsByName
    for _, w in ipairs(wanted) do
        if w.kind == stock.FLUID then fluidsByName = {} break end
    end
    if fluidsByName then
        local list = util.call(proxy, "getFluidsInNetwork")
        if type(list) == "table" then
            for _, fluid in pairs(list) do  -- pairs: convert() can leave holes
                if type(fluid) == "table" and fluid.name then
                    fluidsByName[fluid.name] = fluid
                end
            end
        end
    end

    for _, w in ipairs(wanted) do
        local count, label = 0, w.label
        if w.kind == stock.FLUID then
            local fluid = fluidsByName and fluidsByName[w.name]
            if type(fluid) == "table" then
                count = tonumber(fluid.amount) or 0
                label = fluid.label or label
            end
        else
            local item = util.call(proxy, "getItemInNetwork", w.name, w.damage or 0)
            if type(item) == "table" then
                count = tonumber(item.size) or 0
                label = item.label or label
            end
        end
        snapshot[w.key] = {
            kind = w.kind,
            label = label or w.name,
            count = count,
            -- Absent is a valid reading (the item ran out), not an error: the
            -- row still shows, as 0.
            present = count > 0,
        }
    end

    self.snapshot = snapshot
    return self
end

-- Display rows for one buffer, in the user's chosen order. An item the last poll
-- did not see still appears at 0 rather than vanishing, so a stock that ran out
-- reads as "0", not as a row that quietly disappeared.
function stock:rowsFor(entry)
    local out = {}
    if not self:enabled() then return out end
    local list = entry and entry.stock
    if not (list and list.enabled ~= false and type(list.watch) == "table") then
        return out
    end

    for _, w in ipairs(list.watch) do
        if type(w) == "table" and w.name then
            local snap = self.snapshot[stock.key(w.kind, w.name, w.damage)]
            table.insert(out, {
                kind = w.kind or stock.ITEM,
                label = (snap and snap.label) or w.label or w.name,
                count = snap and snap.count or 0,
                present = snap and snap.present or false,
            })
        end
    end
    return out
end

-- Rows for a monitor view's backing buffer. A convenience over rowsFor for
-- callers that hold a view rather than a config entry (the AR card follows
-- whichever buffer the glasses show). The aggregate, a virtual wireless view and
-- a remote buffer have no local ME network of their own, so they get nothing.
function stock:rowsForView(view)
    if not view or not view.address or view.remote then return {} end
    if view.kind == "wireless" or view.kind == "aggregate" then return {} end
    for _, entry in ipairs(self.config.buffers or {}) do
        if entry.address == view.address then return self:rowsFor(entry) end
    end
    return {}
end

-- The whole network inventory, for the picker. HEAVY — getItemsInNetwork returns
-- every stack in the network — so this is called on demand (opening the editor,
-- or Refresh), never from the poll loop. Returns {items=..., fluids=...} sorted
-- by amount descending, or nil plus a reason.
function stock:networkListing()
    local proxy = self:controller()
    if not proxy then return nil, "no ME controller or interface found" end

    local function collect(raw, kind, amountKey)
        local out = {}
        if type(raw) ~= "table" then return out end
        for _, stack in pairs(raw) do  -- pairs: convert() holes
            if type(stack) == "table" and stack.name then
                local count = tonumber(stack[amountKey]) or 0
                if count > 0 then
                    table.insert(out, {
                        kind = kind,
                        name = stack.name,
                        damage = tonumber(stack.damage) or 0,
                        label = stack.label or stack.name,
                        count = count,
                    })
                end
            end
        end
        table.sort(out, function(a, b)
            if a.count ~= b.count then return a.count > b.count end
            return (a.label or "") < (b.label or "")
        end)
        return out
    end

    return {
        items = collect(util.call(proxy, "getItemsInNetwork"), stock.ITEM, "size"),
        fluids = collect(util.call(proxy, "getFluidsInNetwork"), stock.FLUID, "amount"),
    }
end

return stock
