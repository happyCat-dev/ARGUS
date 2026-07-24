-- On-screen application: dashboard, buffer picker, glasses setup.
--
-- Redraws the whole screen each frame. NIDAS kept every window in a GPU buffer
-- and bitblt'd them, which is faster but needs a Tier 3 GPU; at this refresh
-- rate (a few frames per second) a plain redraw is cheap enough and keeps the
-- hardware requirement down.

local component = require("component")
local computer = require("computer")

local graphics = require("lib.graphics.graphics")
local palette = require("lib.graphics.colors")
local text = require("lib.utils.text")
local time = require("lib.utils.time")

local time = require("lib.utils.time")

local configuration = require("config")
local craftLib = require("core.craft")
local monitorLib = require("core.monitor")
local sources = require("core.sources")
local stockLib = require("core.stock")
local updateLib = require("core.update")

local format = require("ui.format")
local panel = require("ui.panel")
local widgets = require("ui.widgets")

-- For the anchor list: ar.panel owns the HUD layout, so it owns the corners.
local arPanel = require("ar.panel")
local arCraft = require("ar.craft")
local arStock = require("ar.stock")

local app = {}
app.__index = app

-- Graph windows offered by the footer button, in seconds. The sample step
-- follows from the window (window / 120 columns), so 120 gives one point per
-- second and 30 gives four per second — anything finer than the poll rate is
-- floored by metrics.intervalFor.
local GRAPH_WINDOWS = {30, 60, 120, 300, 600, 1800, 3600}

-- Build identity, shown in the footer. An install that silently did not update
-- is otherwise indistinguishable from one that did — mirrors serve cached
-- copies of a branch for hours without saying so.
local function buildLabel()
    local ok, version = pcall(require, "version")
    local label = "v" .. (ok and tostring(version) or "?")
    local ref = configuration.installedRef()
    return ref and (label .. " @" .. ref) or label
end

-- `hud`, `server`, `craft` and `stock` are optional: the Glasses page uses hud
-- to report the viewport detected from glasses_on, the Network page uses server
-- to list connected clients, the Crafting page uses craft to list ME CPUs, and
-- the Buffers page uses stock to pick and show ME item/fluid amounts. None is
-- required for the app to run — a nil monitor means that feature is switched
-- off, and the page says so rather than failing.
function app.new(monitor, config, hud, server, craft, stock)
    return setmetatable({
        monitor = monitor,
        config = config,
        hud = hud,
        server = server,
        craft = craft,
        stock = stock,
        page = "dashboard",
        running = true,
        dirty = true,
        status = nil,
    }, app)
end

function app:notify(message)
    self.status = message
end

function app:nextGraphWindow()
    local current = self.config.screen.graphWindow or 600
    -- Land on the next preset larger than the current value, so a typed window
    -- rejoins the cycle at a sensible place instead of jumping to the start.
    for _, window in ipairs(GRAPH_WINDOWS) do
        if window > current then
            self.config.screen.graphWindow = window
            return
        end
    end
    self.config.screen.graphWindow = GRAPH_WINDOWS[1]
end

function app:typeGraphWindow(rows)
    local typed = widgets.prompt(2, rows - 2, 20,
        self.config.screen.graphWindow or 600, self.config.theme, true)
    local seconds = tonumber(typed)
    if seconds then
        -- Below ~15s the window is shorter than the graph is wide and the curve
        -- is mostly empty; above a day it is meaningless.
        self.config.screen.graphWindow = math.floor(math.min(86400, math.max(15, seconds)))
        self:notify("Graph window: " .. format.window(self.config.screen.graphWindow))
    end
    self.dirty = true
end

function app:save()
    local ok, err = configuration.save(self.config)
    self:notify(ok and "Settings saved" or ("Save failed: " .. tostring(err)))
end

-- Pages ---------------------------------------------------------------------

-- The config buffer entry backing a view, or nil for the aggregate, a virtual
-- wireless view, or a remote buffer — none of which is a local ME-adjacent
-- component and so none of which can carry a watchlist.
function app:bufferEntryFor(view)
    if not view or not view.address or view.remote then return nil end
    if view.kind == "wireless" or view.kind == "aggregate" then return nil end
    for _, entry in ipairs(self.config.buffers) do
        if entry.address == view.address then return entry end
    end
    return nil
end

-- The watched ME rows for a view, as a right-hand column beside the buffer.
local STOCK_COL_WIDTH = 26

function app:drawStockColumn(x, row, width, bottom, stockRows, theme)
    graphics.text(x, row, "ME network", theme.muted, true)
    row = row + 1
    for _, item in ipairs(stockRows) do
        if row > bottom then break end
        -- Count first and highlighted: it is the field that matters. A count of
        -- zero (watched but out of stock) is muted so it reads as "gone", not as
        -- a live figure.
        local amount = format.stock(item.kind, item.count)
        graphics.text(x, row, amount, item.present and palette.text or palette.red, true)
        graphics.text(x + 10, row, text.fit(item.label, width - 10),
            item.present and theme.text or theme.muted, true)
        row = row + 1
    end
end

function app:drawDashboard(width, rows, theme)
    local view = self.monitor:resolve(self.config.screen.source)
    if not view then
        graphics.text(2, 4, "No buffers configured — open Buffers", theme.muted, true)
        return
    end

    -- A watchlist only belongs to a physical local buffer; the aggregate and the
    -- virtual wireless view have no ME network of their own to read.
    local stockRows = {}
    if self.stock then
        local entry = self:bufferEntryFor(view)
        if entry then stockRows = self.stock:rowsFor(entry) end
    end

    local bodyWidth = width - 3
    if #stockRows > 0 then bodyWidth = bodyWidth - STOCK_COL_WIDTH - 2 end

    panel.header(2, 1, width - 2, view, theme, palette)
    panel.rule(2, 2, width - 2, theme)
    panel.draw(2, 4, bodyWidth, rows - 6, view, theme, palette,
        self.config.screen.graphWindow or 600)

    if #stockRows > 0 then
        self:drawStockColumn(2 + bodyWidth + 2, 4, STOCK_COL_WIDTH, rows - 2,
            stockRows, theme)
    end
end

-- The Buffers page is two columns: the buffer list on the left (pick which one
-- the dashboard shows, rename it, switch it on or off), and the ME item/fluid
-- picker for the selected buffer on the right. The picker lives here rather than
-- in its own footer page because the watchlist is per-buffer — it belongs next
-- to the buffer it decorates.
function app:drawBuffers(width, rows, theme)
    graphics.text(2, 1, "Buffers", theme.primary, true)
    graphics.text(10, 1, "· click a buffer to show it; pick ME items to watch beside it",
        theme.muted, true)
    panel.rule(2, 2, width - 2, theme)

    -- Split near the middle, but keep the picker wide enough for its list.
    local split = math.min(58, math.floor(width / 2))
    self:drawBufferList(2, split - 3, rows, theme)
    self:drawStockEditor(split, width - split - 1, rows, theme)
end

function app:drawBufferList(x, width, rows, theme)
    local row = 4
    local views = self.monitor:list()
    local selected = self.config.screen.source

    -- Button columns, measured from the right edge of this column.
    local onX = x + width - 6
    local renameX = onX - 10
    local captionW = renameX - x - 1

    local function toggle(entry)
        return function()
            entry.enabled = not (entry.enabled ~= false)
            self.dirty = true
        end
    end

    -- A custom name replaces the machine's own everywhere: the dashboard header,
    -- the AR card, this list. sources.read prefers entry.name, and syncBuffers
    -- only ever refreshes detectedName, so a rescan cannot clobber it.
    local function rename(entry)
        return function()
            local typed = widgets.prompt(2, rows - 2, 40,
                entry.name or entry.detectedName or "", theme)
            if typed then
                typed = typed:gsub("^%s+", ""):gsub("%s+$", "")
                -- An empty name falls back to what the machine reports rather
                -- than leaving a nameless row.
                entry.name = (typed ~= "") and typed or entry.detectedName
                self:notify("Renamed — press Save to keep it")
            end
            self.dirty = true
        end
    end

    local nameW = math.max(8, captionW - 16)

    for _, view in ipairs(views) do
        if row > rows - 4 then break end

        local isAggregate = view.id == monitorLib.AGGREGATE_ID
        local isSelected = (selected == view.id) or (selected == nil and isAggregate)

        -- text.fit, not :sub — a byte-slice can cut a UTF-8 name mid-character.
        local caption = string.format("%s %6s %8s",
            text.fit(view.name or "?", nameW),
            format.percent(view.percent),
            format.rate(view.net))

        -- The aggregate and the virtual wireless views are not components, so
        -- there is nothing to enable, disable, or watch items beside.
        local entry
        if not isAggregate and view.kind ~= "wireless" then
            for _, candidate in ipairs(self.config.buffers) do
                if candidate.address == view.address then entry = candidate break end
            end
        end

        widgets.listItem(x, row, captionW, caption, theme, isSelected, function()
            self.config.screen.source = isAggregate and nil or view.id
            -- Follow the selection into the picker, but only for a real buffer.
            if entry then self.selectedBuffer = entry.address end
            self.dirty = true
        end, nil, entry and entry.enabled)

        if entry then
            widgets.button(renameX, row, "rename", theme, rename(entry), nil, false)
            widgets.button(onX, row, "on", theme, toggle(entry), nil, true)
        end
        row = row + 1
    end

    -- Disabled buffers are not polled, so the monitor builds no view for them
    -- and the loop above cannot show them. Listing them from the config too is
    -- what makes switching one back on possible at all.
    for _, entry in ipairs(self.config.buffers) do
        if entry.enabled == false and row <= rows - 4 then
            widgets.listItem(x, row, captionW,
                text.fit((entry.name or entry.address) .. "  not monitored", captionW),
                theme, false, toggle(entry), nil, false)
            widgets.button(renameX, row, "rename", theme, rename(entry), nil, false)
            widgets.button(onX, row, "off", theme, toggle(entry), nil, false)
            row = row + 1
        end
    end

    row = row + 1
    widgets.button(x, row, "Rescan components", theme, function()
        local found = sources.discover()
        configuration.syncBuffers(self.config, found)
        self:notify(#found .. " component(s) found")
        self.dirty = true
    end, nil, true)

    if #self.config.buffers == 0 then
        graphics.text(x, row + 2, "Nothing detected. The Adapter must", theme.muted, true)
        graphics.text(x, row + 3, "touch the multiblock CONTROLLER block", theme.muted, true)
        graphics.text(x, row + 4, "and be wired to this computer.", theme.muted, true)
        graphics.text(x, row + 5, "tools/sensordump.lua lists everything.", theme.muted, true)
    end
end

-- Which config buffer the picker is editing. Kept valid: a buffer can be removed
-- or renamed while the page is open, so the selection is repaired to the first
-- real buffer rather than left dangling.
function app:selectedStockEntry()
    local buffers = self.config.buffers or {}
    for _, entry in ipairs(buffers) do
        if entry.address == self.selectedBuffer then return entry end
    end
    -- Fall back to whatever the dashboard is showing, then to the first buffer.
    local view = self.monitor:resolve(self.config.screen.source)
    local entry = self:bufferEntryFor(view) or buffers[1]
    if entry then self.selectedBuffer = entry.address end
    return entry
end

-- The full network inventory for the picker is cached in self.stockSnapshot:
-- getItemsInNetwork is heavy (every stack in the network), so it is pulled once
-- when the editor opens and only re-pulled on Refresh, never per frame.
function app:ensureStockSnapshot()
    if self.stockSnapshot then return end
    local listing, err = self.stock:networkListing()
    self.stockSnapshot = listing or {items = {}, fluids = {}, error = err}
end

local STOCK_MAX = 5

function app:drawStockEditor(x, width, rows, theme)
    local bottom = rows - 3

    if not self.stock then
        graphics.text(x, 4, "ME stock watch is unavailable.", theme.muted, true)
        return
    end

    local entry = self:selectedStockEntry()
    if not entry then
        graphics.text(x, 4, "No buffer selected.", theme.muted, true)
        return
    end

    local list = configuration.stockFor(entry)
    local row = 4

    -- Header: which buffer, and this buffer's own on/off for the column.
    graphics.text(x, row, "ME items · " .. text.fit(entry.name or entry.address, width - 18),
        theme.text, true)
    row = row + 1

    local x2 = x + widgets.button(x, row, list.enabled ~= false and "shown" or "hidden", theme,
        function() list.enabled = not (list.enabled ~= false) self.dirty = true end,
        nil, list.enabled ~= false) + 1
    if self.config.stock and self.config.stock.enabled == false then
        graphics.text(x2, row, "feature off globally", palette.amber, true)
    else
        graphics.text(x2, row, "beside this buffer on the dashboard", theme.muted, true)
    end
    row = row + 2

    -- Chosen list -------------------------------------------------------------
    graphics.text(x, row, string.format("Watching (%d/%d)", #list.watch, STOCK_MAX),
        theme.muted, true)
    row = row + 1

    if #list.watch == 0 then
        graphics.text(x, row, "nothing yet — pick from the network below", theme.muted, true)
        row = row + 1
    end
    for i, w in ipairs(list.watch) do
        local snap = self.stock.snapshot[stockLib.key(w.kind, w.name, w.damage)]
        local amount = snap and format.stock(w.kind, snap.count) or "—"
        graphics.text(x, row, amount, (snap and snap.present) and palette.text or theme.muted, true)
        graphics.text(x + 10, row, text.fit(w.label or w.name, width - 16), theme.text, true)
        widgets.button(x + width - 5, row, "x", theme, function()
            table.remove(list.watch, i)
            self:notify("Removed — Save to keep")
            self.dirty = true
        end, nil, false)
        row = row + 1
    end
    row = row + 1

    panel.rule(x, row, width, theme)
    row = row + 1

    -- Picker controls ---------------------------------------------------------
    self:ensureStockSnapshot()
    local snapshot = self.stockSnapshot
    local tab = self.stockTab or stockLib.ITEM

    local cx = x
    cx = cx + widgets.button(cx, row, "Items", theme, function()
        self.stockTab = stockLib.ITEM self.dirty = true
    end, nil, tab == stockLib.ITEM) + 1
    cx = cx + widgets.button(cx, row, "Fluids", theme, function()
        self.stockTab = stockLib.FLUID self.dirty = true
    end, nil, tab == stockLib.FLUID) + 1
    cx = cx + widgets.button(cx, row, "Refresh", theme, function()
        self.stockSnapshot = nil
        self:notify("Reloading network…")
        self.dirty = true
    end, nil, false) + 1
    row = row + 1

    local filter = self.stockFilter or ""
    cx = x + widgets.button(x, row, filter == "" and "filter: (all)"
        or ("filter: " .. text.fit(filter, 14)), theme, function()
            local typed = widgets.prompt(2, rows - 2, 30, self.stockFilter or "", theme)
            if typed ~= nil then self.stockFilter = typed end
            self.dirty = true
        end, nil, filter ~= "") + 1
    if filter ~= "" then
        widgets.button(cx, row, "clear", theme, function()
            self.stockFilter = "" self.dirty = true
        end, nil, false)
    end
    row = row + 1

    -- Network list ------------------------------------------------------------
    if snapshot.error then
        graphics.text(x, row, "No ME network: " .. text.fit(snapshot.error, width - 14),
            palette.amber, true)
        graphics.text(x, row + 1, "Adapter must touch an ME Controller/Interface.",
            theme.muted, true)
        return
    end

    local pool = (tab == stockLib.FLUID) and snapshot.fluids or snapshot.items
    local needle = filter:lower()
    local matches = {}
    for _, item in ipairs(pool) do
        if needle == "" or item.label:lower():find(needle, 1, true) then
            table.insert(matches, item)
        end
    end

    if #pool == 0 then
        graphics.text(x, row, "network reports no " .. tab .. "s", theme.muted, true)
        return
    end
    if #matches == 0 then
        graphics.text(x, row, "nothing matches \"" .. text.fit(filter, 16) .. "\"", theme.muted, true)
        return
    end

    local shown = 0
    for _, item in ipairs(matches) do
        if row > bottom then break end
        local amount = format.stock(item.kind, item.count)
        graphics.text(x, row, amount, palette.text, true)
        graphics.text(x + 10, row, text.fit(item.label, width - 12), theme.text, true)
        widgets.region(x, row, width, 1, function()
            self:addWatch(list, item)
        end)
        row = row + 1
        shown = shown + 1
    end
    if shown < #matches then
        graphics.text(x, row, "+" .. (#matches - shown) .. " more — type to filter",
            theme.muted, true)
    end
end

-- Add one network item/fluid to a buffer's watchlist, capped at STOCK_MAX and
-- de-duplicated by the same key the poll uses.
function app:addWatch(list, item)
    if #list.watch >= STOCK_MAX then
        self:notify("Watchlist full (max " .. STOCK_MAX .. ")")
        return
    end
    local key = stockLib.key(item.kind, item.name, item.damage)
    for _, w in ipairs(list.watch) do
        if stockLib.key(w.kind, w.name, w.damage) == key then
            self:notify("Already watching " .. (item.label or item.name))
            return
        end
    end
    table.insert(list.watch, {
        kind = item.kind, name = item.name, damage = item.damage, label = item.label,
    })
    self:notify("Added " .. (item.label or item.name) .. " — Save to keep")
    self.dirty = true
end

-- Step to the next entry of a list, wrapping around.
local function cycleValue(list, current, step)
    local index = 1
    for i, value in ipairs(list) do
        if value == current then index = i break end
    end
    return list[(index - 1 + (step or 1)) % #list + 1]
end

local NUDGE = 4
local SCALES = {1, 2, 3, 4}
local INTERVALS = {4, 8, 15, 30}
-- Rows the crafting card offers. Capped at 8 to match ar/craft.lua, which
-- clamps there for the same reason: past that the card covers the game.
local CRAFT_ROWS = {2, 3, 4, 5, 6, 8}
-- The stock card can never show more than the watchlist cap of 5.
local STOCK_ROWS = {2, 3, 4, 5}

function app:nextSource(settings)
    local views = self.monitor:list()
    if #views == 0 then return end
    local index = 1
    for i, view in ipairs(views) do
        if view.id == (settings.source or monitorLib.AGGREGATE_ID) then index = i break end
    end
    local nextView = views[index % #views + 1]
    settings.source = (nextView.id ~= monitorLib.AGGREGATE_ID) and nextView.id or nil
    self.dirty = true
end

function app:drawGlasses(width, rows, theme)
    graphics.text(2, 1, "AR Glasses", theme.primary, true)
    graphics.text(13, 1, "· click a pair to configure it below", theme.muted, true)
    panel.rule(2, 2, width - 2, theme)

    local addresses = {}
    for address in component.list("glasses") do table.insert(addresses, address) end
    table.sort(addresses)

    if #addresses == 0 then
        graphics.text(2, 4, "No glasses component found.", theme.muted, true)
        graphics.text(2, 5, "Link a Terminal Glasses Bridge to this computer,", theme.muted, true)
        graphics.text(2, 6, "and put the glasses in the bridge.", theme.muted, true)
        return
    end

    -- Keep the selection valid: glasses can be unlinked while this page is open.
    local stillPresent = false
    for _, address in ipairs(addresses) do
        if address == self.selectedGlasses then stillPresent = true break end
    end
    if not stillPresent then self.selectedGlasses = addresses[1] end

    local row = 4
    for _, address in ipairs(addresses) do
        if row > rows - 12 then break end
        local settings = configuration.glassesFor(self.config, address)
        local view = self.monitor:resolve(settings.source)
        local caption = string.format("%-10s %-4s %s",
            address:sub(1, 8),
            settings.enabled and "on" or "off",
            settings.cycle and "cycling all buffers" or ("→ " .. ((view and view.name) or "?")))

        widgets.listItem(2, row, width - 4, caption, theme, address == self.selectedGlasses,
            function() self.selectedGlasses = address self.dirty = true end, nil, settings.enabled)
        row = row + 1
    end

    -- Detail panel for the selected pair --------------------------------------
    local settings = configuration.glassesFor(self.config, self.selectedGlasses)
    row = row + 1
    panel.rule(2, row, width - 2, theme)
    row = row + 1
    graphics.text(2, row, "Configuring " .. self.selectedGlasses:sub(1, 8), theme.text, true)
    row = row + 2

    local function label(name) graphics.text(2, row, name, theme.muted, true) end

    label("Display")
    widgets.button(14, row, settings.enabled and "on" or "off", theme, function()
        settings.enabled = not settings.enabled self.dirty = true
    end, nil, settings.enabled)
    row = row + 1

    label("Mode")
    local x = 14
    x = x + widgets.button(x, row, settings.cycle and "cycle" or "pinned", theme, function()
        settings.cycle = not settings.cycle self.dirty = true
    end, nil, settings.cycle) + 2

    if settings.cycle then
        graphics.text(x, row, "every", theme.muted, true)
        widgets.button(x + 6, row, settings.cycleInterval .. "s", theme, function()
            settings.cycleInterval = cycleValue(INTERVALS, settings.cycleInterval)
            self.dirty = true
        end, nil, true)
    else
        local view = self.monitor:resolve(settings.source)
        widgets.button(x, row, "source: " .. ((view and view.name) or "?"), theme, function()
            self:nextSource(settings)
        end, nil, true)
    end
    row = row + 1

    -- Position ---------------------------------------------------------------
    local manual = settings.anchor == "manual"

    label("Position")
    x = 14
    x = x + widgets.button(x, row, settings.anchor, theme, function()
        settings.anchor = cycleValue(arPanel.ANCHORS, settings.anchor)
        self.dirty = true
    end, nil, true) + 2
    graphics.text(x, row, manual and "← X/Y are exact coordinates in the glasses viewport"
        or "← chat sits bottom-left, hotbar bottom-centre", theme.muted, true)
    row = row + 1

    -- With a corner anchor these nudge the card away from it; with "manual"
    -- they ARE the position, so the same two numbers serve both.
    label(manual and "X / Y" or "Nudge")
    x = 14
    local function nudge(dx, dy)
        return function()
            settings.offsetX = (settings.offsetX or 0) + dx
            settings.offsetY = (settings.offsetY or 0) + dy
            self.dirty = true
        end
    end
    x = x + widgets.button(x, row, "←", theme, nudge(-NUDGE, 0), nil, true) + 1
    x = x + widgets.button(x, row, "→", theme, nudge(NUDGE, 0), nil, true) + 1
    x = x + widgets.button(x, row, "↑", theme, nudge(0, -NUDGE), nil, true) + 1
    x = x + widgets.button(x, row, "↓", theme, nudge(0, NUDGE), nil, true) + 2
    x = x + widgets.button(x, row, "reset", theme, function()
        settings.offsetX, settings.offsetY = 0, 0
        self.dirty = true
    end, nil, false) + 2

    -- Typing beats nudging four pixels at a time when you know the number.
    local function typeCoordinate(axis)
        return function()
            local typed = widgets.prompt(2, rows - 2, 20, settings[axis] or 0, theme, true)
            local number = tonumber(typed)
            if number then settings[axis] = math.floor(number) end
            self.dirty = true
        end
    end
    x = x + widgets.button(x, row, "X " .. (settings.offsetX or 0), theme,
        typeCoordinate("offsetX"), nil, false) + 1
    x = x + widgets.button(x, row, "Y " .. (settings.offsetY or 0), theme,
        typeCoordinate("offsetY"), nil, false) + 2
    graphics.text(x, row, "click X/Y to type exact values", theme.muted, true)
    row = row + 1

    -- Rendering --------------------------------------------------------------
    label("Card")
    x = 14
    x = x + widgets.button(x, row, settings.compact and "compact" or "full", theme, function()
        settings.compact = not settings.compact self.dirty = true
    end, nil, settings.compact) + 2

    -- Viewport comes from the glasses_on signal; the manual GUI scale is only a
    -- fallback for before they have been worn.
    local viewport = self.hud and self.hud.viewport[self.selectedGlasses]
    x = x + widgets.button(x, row, settings.autoResolution ~= false and "auto size" or "manual",
        theme, function()
            settings.autoResolution = not (settings.autoResolution ~= false)
            self.dirty = true
        end, nil, settings.autoResolution ~= false) + 2

    if settings.autoResolution ~= false then
        if viewport then
            graphics.text(x, row, string.format("detected %dx%d", viewport.width, viewport.height),
                theme.muted, true)
        else
            graphics.text(x, row, "put the glasses on to detect the size", theme.muted, true)
        end
    else
        graphics.text(x, row, "GUI scale", theme.muted, true)
        x = x + 10
        widgets.button(x, row, tostring(settings.scale), theme, function()
            settings.scale = cycleValue(SCALES, settings.scale)
            self.dirty = true
        end, nil, true)
    end
    row = row + 2

    -- Crafting card ----------------------------------------------------------
    -- A second card on the same glasses, with its own placement. It is deliberately
    -- independent of "Display" above: that switch owns the energy card, so these
    -- glasses can wear either card, both, or neither.
    local craftCard = settings.craft

    label("Craft card")
    x = 14
    x = x + widgets.button(x, row, craftCard.enabled and "on" or "off", theme, function()
        craftCard.enabled = not craftCard.enabled
        self.dirty = true
    end, nil, craftCard.enabled) + 2

    if not craftCard.enabled then
        graphics.text(x, row, self.craft and "← shows ME crafting jobs and stalls"
            or "← crafting monitoring is off in the config", theme.muted, true)
        row = row + 2
    else
        x = x + widgets.button(x, row, craftCard.anchor, theme, function()
            craftCard.anchor = cycleValue(arCraft.ANCHORS, craftCard.anchor)
            self.dirty = true
        end, nil, true) + 1

        local function nudgeCraft(dx, dy)
            return function()
                craftCard.offsetX = (craftCard.offsetX or 0) + dx
                craftCard.offsetY = (craftCard.offsetY or 0) + dy
                self.dirty = true
            end
        end
        x = x + widgets.button(x, row, "←", theme, nudgeCraft(-NUDGE, 0), nil, true) + 1
        x = x + widgets.button(x, row, "→", theme, nudgeCraft(NUDGE, 0), nil, true) + 1
        x = x + widgets.button(x, row, "↑", theme, nudgeCraft(0, -NUDGE), nil, true) + 1
        x = x + widgets.button(x, row, "↓", theme, nudgeCraft(0, NUDGE), nil, true) + 2

        -- Row count is capped where the card stops being a HUD and starts being
        -- a wall; the Crafting page is where the full list belongs.
        x = x + widgets.button(x, row, "rows " .. (craftCard.rows or 4), theme, function()
            craftCard.rows = cycleValue(CRAFT_ROWS, craftCard.rows)
            self.dirty = true
        end, nil, false) + 1

        x = x + widgets.button(x, row, "stalled only", theme, function()
            craftCard.stalledOnly = not craftCard.stalledOnly
            self.dirty = true
        end, nil, craftCard.stalledOnly) + 2

        graphics.text(x, row, string.format("at %d,%d", craftCard.offsetX or 0,
            craftCard.offsetY or 0), theme.muted, true)
        row = row + 1

        graphics.text(14, row, "In free cursor: [ ] page · F stalled-only · - fold  (or click the - on the card).",
            theme.muted, true)
        row = row + 1

        if not self.craft then
            graphics.text(14, row, "Crafting monitoring is off in the config — the card stays hidden.",
                palette.amber, true)
            row = row + 1
        end
        row = row + 1
    end

    -- Stock card -------------------------------------------------------------
    -- A third card, independent again: shows the watched ME item/fluid amounts
    -- for whichever buffer these glasses display (it follows a cycle). What each
    -- buffer watches is picked on the Buffers page.
    local stockCard = settings.stock

    label("Stock card")
    x = 14
    x = x + widgets.button(x, row, stockCard.enabled and "on" or "off", theme, function()
        stockCard.enabled = not stockCard.enabled
        self.dirty = true
    end, nil, stockCard.enabled) + 2

    if not stockCard.enabled then
        graphics.text(x, row, "← shows up to 5 watched ME items beside the buffer",
            theme.muted, true)
        row = row + 2
    else
        x = x + widgets.button(x, row, stockCard.anchor, theme, function()
            stockCard.anchor = cycleValue(arStock.ANCHORS, stockCard.anchor)
            self.dirty = true
        end, nil, true) + 1

        local function nudgeStock(dx, dy)
            return function()
                stockCard.offsetX = (stockCard.offsetX or 0) + dx
                stockCard.offsetY = (stockCard.offsetY or 0) + dy
                self.dirty = true
            end
        end
        x = x + widgets.button(x, row, "←", theme, nudgeStock(-NUDGE, 0), nil, true) + 1
        x = x + widgets.button(x, row, "→", theme, nudgeStock(NUDGE, 0), nil, true) + 1
        x = x + widgets.button(x, row, "↑", theme, nudgeStock(0, -NUDGE), nil, true) + 1
        x = x + widgets.button(x, row, "↓", theme, nudgeStock(0, NUDGE), nil, true) + 2

        x = x + widgets.button(x, row, "rows " .. (stockCard.rows or 5), theme, function()
            stockCard.rows = cycleValue(STOCK_ROWS, stockCard.rows)
            self.dirty = true
        end, nil, false) + 2

        graphics.text(x, row, string.format("at %d,%d", stockCard.offsetX or 0,
            stockCard.offsetY or 0), theme.muted, true)
        row = row + 1

        graphics.text(14, row, "In free cursor: = fold  (or click the = on the card). Pick items on the Buffers page.",
            theme.muted, true)
        row = row + 1

        if not self.stock then
            graphics.text(14, row, "ME stock watch is off — the card stays hidden.",
                palette.amber, true)
            row = row + 1
        end
        row = row + 1
    end

    -- The category shows up as "OC Glasses"; openGlasses is only the lang key.
    -- Both bindings ship unbound, which is the single most common reason the HUD
    -- looks unresponsive.
    graphics.text(2, row, "In-game: Controls → \"OC Glasses\" → bind \"Free Cursor (Toggle)\".",
        theme.muted, true)
    graphics.text(2, row + 1, "UNBOUND by default — that is why the HUD can look dead. Energy card: ← → switch, 1-9 pick, C cycles.",
        theme.muted, true)
    row = row + 3
    graphics.text(2, row, "Changes apply instantly. Press Save to keep them.", theme.muted, true)
end

local ROLES = {"standalone", "server", "client"}

local ROLE_HELP = {
    standalone = "this computer only — no networking",
    server     = "collects buffers from the clients below and shows them alongside its own",
    client     = "answers a server's polls with this base's buffers",
}

function app:drawNetwork(width, rows, theme)
    local network = self.config.network

    graphics.text(2, 1, "Network", theme.primary, true)
    graphics.text(10, 1, "· one server, one client per remote base", theme.muted, true)
    panel.rule(2, 2, width - 2, theme)

    local row = 4
    local function label(name) graphics.text(2, row, name, theme.muted, true) end

    -- Role -------------------------------------------------------------------
    label("Role")
    local x = 14
    for _, role in ipairs(ROLES) do
        x = x + widgets.button(x, row, role, theme, function()
            network.role = role
            self.dirty = true
        end, nil, network.role == role) + 1
    end
    row = row + 1
    graphics.text(14, row, ROLE_HELP[network.role] or "", theme.muted, true)
    row = row + 2

    -- Settings ---------------------------------------------------------------
    local function typeNumber(key, low, high, suffix)
        return function()
            local typed = widgets.prompt(2, rows - 2, 20, network[key] or 0, theme, true)
            local value = tonumber(typed)
            if value then
                network[key] = math.floor(math.min(high, math.max(low, value)))
                self:notify(key .. ": " .. network[key] .. (suffix or ""))
            end
            self.dirty = true
        end
    end

    label("Port")
    -- Both ends must agree, and a modem silently drops messages on a port it
    -- has not opened — so a mismatch looks exactly like "no clients".
    x = 14 + widgets.button(14, row, tostring(network.port), theme,
        typeNumber("port", 1, 65535), nil, false) + 2
    graphics.text(x, row, "must match on every base", theme.muted, true)
    row = row + 1

    -- The one setting a shared server makes non-optional.
    label("Network key")
    local key = self.server and self.server.transport:key() or "?"
    x = 14 + widgets.button(14, row, key, theme, function()
        local typed = widgets.prompt(2, rows - 2, 32, network.key or key, theme)
        if typed then
            typed = typed:gsub("%s+", ""):upper()
            network.key = (typed ~= "") and typed or nil
            self:notify("Key set — every base must use the same one")
        end
        self.dirty = true
    end, nil, true) + 2
    if network.role == "server" then
        graphics.text(x, row, "copy this onto every client of yours", theme.muted, true)
    else
        graphics.text(x, row, "must match your server's key", theme.muted, true)
    end
    row = row + 1
    graphics.text(14, row, "keeps other players' ARGUS out — a broadcast reaches everyone in range",
        theme.muted, true)
    row = row + 1

    label("This node")
    x = 14 + widgets.button(14, row, self.server and self.server.transport:nodeName() or "?",
        theme, function()
            local typed = widgets.prompt(2, rows - 2, 32, network.name or "", theme)
            if typed then
                typed = typed:gsub("^%s+", ""):gsub("%s+$", "")
                network.name = (typed ~= "") and typed or nil
            end
            self.dirty = true
        end, nil, false) + 2
    graphics.text(x, row, "name this base reports to the server", theme.muted, true)
    row = row + 1

    if network.role == "server" then
        label("Poll")
        x = 14 + widgets.button(14, row, (network.pollInterval or 2) .. "s", theme,
            typeNumber("pollInterval", 1, 60, "s"), nil, false) + 2
        x = x + widgets.button(x, row, "timeout " .. (network.timeout or 15) .. "s", theme,
            typeNumber("timeout", 5, 300, "s"), nil, false) + 2
        graphics.text(x, row, "silence longer than the timeout marks a base offline",
            theme.muted, true)
        row = row + 1
    end
    row = row + 1

    -- Cards ------------------------------------------------------------------
    label("Cards")
    local modems, tunnels = 0, 0
    if self.server then
        for _, card in pairs(self.server.transport:cardList()) do
            if card.kind == "tunnel" then tunnels = tunnels + 1 else modems = modems + 1 end
        end
    end
    if modems + tunnels == 0 then
        graphics.text(14, row, "none — install a Network Card, Wireless Network Card,",
            palette.amber, true)
        graphics.text(14, row + 1, "or a Linked Card (crosses dimensions, pairs 1:1)",
            palette.amber, true)
        row = row + 2
    else
        graphics.text(14, row, string.format("%d modem, %d tunnel (linked card)", modems, tunnels),
            theme.text, true)
        row = row + 1
    end
    row = row + 1

    -- Clients ----------------------------------------------------------------
    if network.role ~= "server" then
        graphics.text(2, row, "Switch to `server` to see connected clients here.",
            theme.muted, true)
        return
    end

    local nodes = self.server and self.server:list() or {}
    panel.rule(2, row, width - 2, theme)
    row = row + 1
    graphics.text(2, row, "Clients (" .. #nodes .. ")", theme.primary, true)
    row = row + 1

    if #nodes == 0 then
        graphics.text(2, row, "None yet. On the other base: set role to `client`, use the",
            theme.muted, true)
        graphics.text(2, row + 1, "same port, and make sure a card links the two (wireless",
            theme.muted, true)
        graphics.text(2, row + 2, "range is 400 blocks at T2 and does not cross dimensions).",
            theme.muted, true)
        return
    end

    local now = computer.uptime()
    for _, node in ipairs(nodes) do
        if row > rows - 3 then break end
        local age = now - node.lastSeen
        local status = node.offline and "OFFLINE" or "online"
        local color = node.offline and palette.red or palette.green

        graphics.text(2, row, text.fit(node.name, 26), theme.text, true)
        graphics.text(29, row, node.address:sub(1, 8), theme.muted, true)
        graphics.text(39, row, #(node.buffers or {}) .. " buf", theme.muted, true)
        graphics.text(47, row, status, color, true)
        -- Distance is 0 over a wired modem or a linked card, which is not a
        -- fault — only a wireless hop has one.
        local detail = time.format(math.floor(age)) .. " ago"
        if (node.distance or 0) > 0 then
            detail = detail .. string.format("  %.0f blocks", node.distance)
        end
        graphics.text(57, row, detail, theme.muted, true)

        widgets.button(width - 11, row, "forget", theme, function()
            self.server:forget(node.address)
            self.dirty = true
        end, nil, false)
        row = row + 1
    end
end

-- Settings -------------------------------------------------------------------
--
-- Graph resolution (moved off the footer, where it crowded the page tabs) and
-- the in-app updater. The updater only ever reports and hands off to setup.lua —
-- see core/update.lua for why the check and the install both go through
-- cdn.jsdelivr.net and why the install pins to a tag.

function app:drawSettings(width, rows, theme)
    graphics.text(2, 1, "Settings", theme.primary, true)
    graphics.text(11, 1, "· graph resolution and app updates", theme.muted, true)
    panel.rule(2, 2, width - 2, theme)

    local row = 4
    local function label(name) graphics.text(2, row, name, theme.muted, true) end

    -- Graph ------------------------------------------------------------------
    label("Graph window")
    local x = 16
    x = x + widgets.button(x, row, format.window(self.config.screen.graphWindow or 600), theme,
        function() self:nextGraphWindow() self.dirty = true end, nil, false) + 1
    x = x + widgets.button(x, row, "type…", theme, function() self:typeGraphWindow(rows) end,
        nil, false) + 2
    graphics.text(x, row, "the dashboard chart's span; the sample step follows from it",
        theme.muted, true)
    row = row + 2

    -- Updates ----------------------------------------------------------------
    panel.rule(2, row, width - 2, theme)
    row = row + 1
    graphics.text(2, row, "Updates", theme.primary, true)
    row = row + 1

    label("Installed")
    graphics.text(16, row, self.build or buildLabel(), theme.text, true)
    row = row + 1

    label("Auto-check")
    local upd = self.config.update or {}
    x = 16 + widgets.button(16, row, upd.checkOnStart and "on boot" or "off", theme, function()
        self.config.update = self.config.update or {}
        self.config.update.checkOnStart = not self.config.update.checkOnStart
        self.dirty = true
    end, nil, upd.checkOnStart) + 2
    graphics.text(x, row, "check for a newer release when ARGUS starts", theme.muted, true)
    row = row + 2

    -- Check + result ---------------------------------------------------------
    x = 2 + widgets.button(2, row, "Check for updates", theme, function()
        -- A synchronous wget of a tiny file; a second's pause is fine here.
        self:notify("Checking cdn.jsdelivr.net…")
        self.updateInfo = nil
        local info, err = updateLib.check()
        self.updateInfo = info or {error = err}
        self.dirty = true
    end, nil, true) + 2

    local info = self.updateInfo
    if not info then
        graphics.text(x, row, "reads cdn.jsdelivr.net (raw.githubusercontent is blocked from many servers)",
            theme.muted, true)
    elseif info.error then
        graphics.text(x, row, "check failed: " .. tostring(info.error), palette.amber, true)
    elseif info.newer then
        graphics.text(x, row, string.format("update available: %s  (installed %s)",
            info.latest, info.current), palette.green, true)
        row = row + 2
        widgets.button(2, row, "Update now  →  " .. info.latest, theme, function()
            -- Just flag it and quit: the download and install run after the app
            -- exits, with visible output, rather than frozen behind a static
            -- frame. init.lua picks this up. setup.lua keeps the settings.
            self.pendingUpdate = info.latest
            self:notify("Quitting to install " .. info.latest .. "…")
            self.running = false
        end, nil, true)
        row = row + 1
        graphics.text(2, row, "installs the pinned tag and reboots into it — settings kept, no prompts",
            theme.muted, true)
    else
        graphics.text(x, row, "up to date (" .. info.current .. ")", palette.green, true)
    end
end

-- Frame ---------------------------------------------------------------------

-- Crafting -------------------------------------------------------------------

local CRAFT_STATE_COLORS = {
    [craftLib.CRAFTING] = palette.green,
    [craftLib.STALLED]  = palette.amber,
    [craftLib.IDLE]     = palette.muted,
    [craftLib.MISSING]  = palette.red,
}

-- One column of the chain breakdown.
--
-- The three lists are shown side by side because that IS the shape of the data:
-- AE2 keeps a set per category, not a sequence, so a numbered list would invent
-- an order the network does not have.
local function itemColumn(x, row, width, title, list, theme, limit)
    graphics.text(x, row, title, theme.muted, true)
    if #list == 0 then
        graphics.text(x, row + 1, "—", theme.muted, true)
        return
    end
    for i = 1, math.min(#list, limit) do
        local item = list[i]
        graphics.text(x, row + i, text.fit(item.size .. "x " .. item.label, width),
            palette.text, true)
    end
    if #list > limit then
        graphics.text(x, row + limit + 1, "+" .. (#list - limit) .. " more", theme.muted, true)
    end
end

function app:drawCrafting(width, rows, theme)
    graphics.text(2, 1, "Crafting", theme.primary, true)
    graphics.text(11, 1, "· click a CPU to break down its chain", theme.muted, true)
    panel.rule(2, 2, width - 2, theme)

    if not self.craft then
        graphics.text(2, 4, "Crafting monitoring is switched off in the config.", theme.muted, true)
        graphics.text(2, 5, "Set craft.enabled = true in settings/config and restart.",
            theme.muted, true)
        return
    end

    local summary = self.craft:summary()
    if summary.error then
        graphics.text(2, 4, "No ME network: " .. summary.error, palette.amber, true)
        graphics.text(2, 6, "ARGUS reads crafting through an Adapter touching an ME Controller",
            theme.muted, true)
        graphics.text(2, 7, "(or an ME Interface), connected to this computer.", theme.muted, true)
        graphics.text(2, 9, "Run tools/medump.lua to see every component and what the",
            theme.muted, true)
        graphics.text(2, 10, "driver exposes.", theme.muted, true)
        return
    end

    local jobs = self.craft:list()
    graphics.text(2, 3, string.format("%d CPU(s) · %d busy · %d stalled",
        summary.total, summary.busy, summary.stalled),
        summary.stalled > 0 and palette.amber or theme.muted, true)

    -- List -------------------------------------------------------------------
    local row = 5
    local listBottom = math.min(rows - 14, 5 + #jobs - 1)

    for _, job in ipairs(jobs) do
        if row > listBottom then break end

        local ordered = "—"
        if job.output then
            ordered = job.output.size .. "x " .. job.output.label
        elseif job.outputError and tostring(job.outputError):find("monitor") then
            ordered = "(no Crafting Monitor)"
        end

        local caption = string.format("%-14s %-30s %s",
            text.fit(job.cpuName, 14),
            text.fit(ordered, 30),
            job.state == craftLib.STALLED
                and ("STALLED " .. time.format(job.stalledFor or 0))
                or job.state)

        widgets.listItem(2, row, width - 4, caption, theme, job.id == self.selectedCpu,
            function() self.selectedCpu = job.id self.dirty = true end, nil, job.busy)
        row = row + 1
    end

    if #jobs == 0 then
        graphics.text(2, 5, "The ME network reports no crafting CPUs.", theme.muted, true)
        graphics.text(2, 6, "Assemble at least one CPU from Crafting Storage blocks.",
            theme.muted, true)
        return
    end

    -- Detail ------------------------------------------------------------------
    -- Keep the selection valid: a CPU can be dismantled while this page is open,
    -- and the previous selection would then address a job that no longer exists.
    local job = self.craft:get(self.selectedCpu)
    if not job then
        job = jobs[1]
        self.selectedCpu = job.id
    end

    row = row + 1
    panel.rule(2, row, width - 2, theme)
    row = row + 1

    graphics.text(2, row, job.cpuName, theme.text, true)
    graphics.text(2 + text.len(job.cpuName) + 2, row,
        string.format("· %d bytes · %d co-processor(s)", job.storage, job.coprocessors),
        theme.muted, true)
    row = row + 2

    if not job.busy then
        graphics.text(2, row, "Idle — no job on this CPU.", theme.muted, true)
        return
    end

    -- Ordered ----------------------------------------------------------------
    graphics.text(2, row, "Ordered", theme.muted, true)
    if job.output then
        graphics.text(14, row, job.output.size .. "x " .. job.output.label, palette.text, true)
    elseif job.outputError and tostring(job.outputError):find("monitor") then
        -- Not a bug and not fixable in software: the driver reads the final
        -- output off a Crafting Monitor block inside the CPU cluster.
        graphics.text(14, row, "unknown — this CPU has no Crafting Monitor block",
            palette.amber, true)
        graphics.text(14, row + 1, "add one to the CPU multiblock and it appears here",
            theme.muted, true)
        row = row + 1
    else
        graphics.text(14, row, "unknown — " .. tostring(job.outputError or "?"), theme.muted, true)
    end
    row = row + 2

    -- Stall banner ------------------------------------------------------------
    if job.state == craftLib.STALLED then
        graphics.text(2, row, "PAUSED", palette.amber, true)
        graphics.text(14, row, string.format("nothing has changed for %s — %s",
            time.format(job.stalledFor or 0), job.stallReason or "no progress"),
            palette.amber, true)
        row = row + 1
        if job.next then
            graphics.text(14, row, "expected next: " .. job.next.size .. "x " .. job.next.label,
                palette.amber, true)
            row = row + 1
        end
        row = row + 1
    end

    -- Chain -------------------------------------------------------------------
    local column = math.floor((width - 6) / 3)
    local limit = math.max(1, rows - row - 3)

    itemColumn(2, row, column - 2, "In machines now", job.active, theme, limit)
    itemColumn(2 + column, row, column - 2, "Waiting", job.pending, theme, limit)
    itemColumn(2 + column * 2, row, column - 2, "Already made", job.stored, theme, limit)

    -- Said once, plainly, rather than implied by the column heading: AE2 hands
    -- out a set here, and a player reading "Waiting" top-to-bottom would
    -- otherwise reasonably assume it is the running order.
    graphics.text(2, rows - 2,
        "Order is not exposed by AE2 — a job is a tree of parallel tasks, so \"Waiting\" is sorted by amount, not by turn.",
        theme.muted, true)
end

function app:footer(width, rows, theme)
    local row = rows
    panel.rule(2, rows - 1, width - 2, theme)

    local x = 2
    x = x + widgets.button(x, row, "Dashboard", theme, function()
        self.page = "dashboard" self.dirty = true
    end, nil, self.page == "dashboard") + 1

    x = x + widgets.button(x, row, "Buffers", theme, function()
        self.page = "buffers" self.dirty = true
    end, nil, self.page == "buffers") + 1

    x = x + widgets.button(x, row, "Glasses", theme, function()
        self.page = "glasses" self.dirty = true
    end, nil, self.page == "glasses") + 1

    x = x + widgets.button(x, row, "Crafting", theme, function()
        self.page = "crafting" self.dirty = true
    end, nil, self.page == "crafting") + 1

    x = x + widgets.button(x, row, "Network", theme, function()
        self.page = "network" self.dirty = true
    end, nil, self.page == "network") + 1

    x = x + widgets.button(x, row, "Settings", theme, function()
        self.page = "settings" self.dirty = true
    end, nil, self.page == "settings") + 1

    x = x + widgets.button(x, row, "Save", theme, function() self:save() end, nil, false) + 1
    x = x + widgets.button(x, row, "Quit", theme, function() self.running = false end, nil, false) + 2

    local build = self.build or buildLabel()
    self.build = build
    graphics.text(width - text.len(build) - 1, row, build, theme.muted, true)

    if self.status then
        graphics.text(x, row, self.status, theme.primary, true)
    end
end

function app:draw()
    local context = graphics.context()
    local width, rows = context.width, context.height
    local theme = self.config.theme

    widgets.reset()
    -- Render the whole frame offscreen, then blit it in one go. Painting
    -- directly to the screen shows the clear() and the repaint as separate
    -- steps, which is what made the UI flicker.
    graphics.beginFrame()
    graphics.clear()

    if self.page == "buffers" then
        self:drawBuffers(width, rows, theme)
    elseif self.page == "glasses" then
        self:drawGlasses(width, rows, theme)
    elseif self.page == "crafting" then
        self:drawCrafting(width, rows, theme)
    elseif self.page == "network" then
        self:drawNetwork(width, rows, theme)
    elseif self.page == "settings" then
        self:drawSettings(width, rows, theme)
    else
        self:drawDashboard(width, rows, theme)
    end

    self:footer(width, rows, theme)
    graphics.endFrame()
end

function app:onTouch(x, row)
    self.status = nil
    widgets.dispatch(math.floor(x), math.floor(row))
end

return app
