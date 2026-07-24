-- The ME stock panel (AR glasses HUD).
--
-- A third independent card next to the energy and crafting ones: the watched
-- item/fluid amounts for whichever buffer the glasses are currently showing, one
-- per row, the count first because the count is the point.
--
-- Same rules as ar/panel.lua and ar/craft.lua, for the same reasons:
--   * objects are created ONCE and mutated per tick — the AR API has no frame
--     boundary, so recreating them leaks into the glasses until it chokes;
--   * the rows are real glasses objects, so the count is fixed at construction
--     and unused rows are emptied rather than destroyed.
--
-- Unlike the crafting card there is nothing to page or click: the watchlist is
-- capped at five, which is the whole card, so this carries no hit regions.

local ar = require("lib.graphics.ar")
local palette = require("lib.graphics.colors")
local screen = require("lib.utils.screen")
local text = require("lib.utils.text")

local format = require("ui.format")

local panel = {}
panel.__index = panel

local WIDTH = 156
local HEADER = 13
local ROW_HEIGHT = 9
local MARGIN = 4
local PADDING = 3

-- The watchlist cap, so the card never reserves more rows than can ever fill.
local MAX_ROWS = 5

-- Same corners as the other cards, plus "manual". Duplicated deliberately: the
-- three cards are independent, and sharing an anchor list is the coupling that
-- makes moving one move another later.
panel.ANCHORS = {
    "top-left", "top-center", "top-right",
    "bottom-left", "bottom-center", "bottom-right",
    "manual",
}

local function height(rows)
    return HEADER + rows * ROW_HEIGHT + PADDING
end

panel.height = height

local function anchorPosition(anchor, resolution, width, cardHeight)
    local left = MARGIN
    local center = (resolution[1] - width) / 2
    local right = resolution[1] - width - MARGIN
    local top = MARGIN
    local bottom = resolution[2] - cardHeight - MARGIN

    local positions = {
        ["top-left"]      = {left, top},
        ["top-center"]    = {center, top},
        ["top-right"]     = {right, top},
        ["bottom-left"]   = {left, bottom},
        ["bottom-center"] = {center, bottom},
        ["bottom-right"]  = {right, bottom},
        -- Origin, so the caller's offsets become absolute coordinates.
        ["manual"]        = {0, 0},
    }
    local position = positions[anchor] or positions["bottom-right"]
    return position[1], position[2]
end

panel.anchorPosition = anchorPosition

function panel.new(glasses, settings, theme, resolution)
    local rows = math.max(1, math.min(MAX_ROWS, math.floor(settings.rows or MAX_ROWS)))
    local cardHeight = height(rows)

    local x, y = anchorPosition(settings.anchor, resolution, WIDTH, cardHeight)
    x = x + (settings.offsetX or 0)
    y = y + (settings.offsetY or 0)

    local self = setmetatable({
        glasses = glasses,
        theme = theme,
        rows = rows,
        width = WIDTH,
        height = cardHeight,
        x = x,
        y = y,
        static = {},
        dynamic = {},
        rowObjects = {},
    }, panel)

    -- Chrome. A green stripe sets this card apart from the energy (primary) and
    -- crafting (accent) ones at a glance when more than one is worn.
    table.insert(self.static, ar.rectangle(glasses, {x, y}, WIDTH, cardHeight, theme.background, 0.55))
    table.insert(self.static, ar.rectangle(glasses, {x, y}, 2, cardHeight, palette.green, 0.9))

    -- Header: the card name and the buffer it is showing.
    self.dynamic.title = ar.text(glasses, "ME STOCK", {x + 7, y + 3}, palette.green, 0.7)
    self.dynamic.buffer = ar.text(glasses, "", {x + 52, y + 3}, theme.muted, 0.6)

    -- The count column is left of the label so the numbers line up down the card;
    -- item names are ragged and would push the counts around otherwise.
    for i = 1, rows do
        local rowY = y + HEADER + (i - 1) * ROW_HEIGHT
        self.rowObjects[i] = {
            count = ar.text(glasses, "", {x + 7, rowY}, palette.text, 0.7),
            label = ar.text(glasses, "", {x + 52, rowY}, palette.text, 0.7),
        }
    end

    -- Shown instead of the rows when there is nothing to list, so an enabled card
    -- is never a blank rectangle with no explanation.
    self.dynamic.empty = ar.text(glasses, "", {x + 7, y + HEADER + 1}, theme.muted, 0.6)

    return self
end

local function clearRow(row)
    row.count.setText("")
    row.label.setText("")
end

-- `rows` is the watchlist for the displayed buffer (from core.stock:rowsForView);
-- `view` is that buffer, for the header. An empty list is the common case — the
-- glasses may be showing the aggregate, or a buffer with nothing watched — so it
-- gets a plain explanation rather than a blank card.
function panel:update(rows, view)
    rows = rows or {}

    self.dynamic.buffer.setText(view and text.fit(view.name or "?", 18) or "")

    if #rows == 0 then
        for i = 1, self.rows do clearRow(self.rowObjects[i]) end
        self.dynamic.empty.setText("nothing watched here")
        return
    end
    self.dynamic.empty.setText("")

    for i = 1, self.rows do
        local row = self.rowObjects[i]
        local item = rows[i]
        if not item then
            clearRow(row)
        else
            row.count.setText(format.stock(item.kind, item.count))
            -- Green when in stock, red at zero: a watched item that ran out is
            -- the reading worth catching from across the room.
            row.count.setColor(screen.toRGB(item.present and palette.green or palette.red))

            row.label.setText(text.fit(item.label or "?", 22))
            row.label.setColor(screen.toRGB(item.present and palette.text or self.theme.muted))
        end
    end
end

function panel:remove()
    ar.remove(self.glasses, self.static)

    local dynamic = {}
    for _, object in pairs(self.dynamic) do table.insert(dynamic, object) end
    for _, row in ipairs(self.rowObjects) do
        table.insert(dynamic, row.count)
        table.insert(dynamic, row.label)
    end
    ar.remove(self.glasses, dynamic)

    self.static, self.dynamic, self.rowObjects = {}, {}, {}
end

return panel
