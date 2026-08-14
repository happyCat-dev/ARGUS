-- cauldron.lua — автоматизация Witches' Cauldron (мод Witchery) через OpenComputers.
-- Отдельная самостоятельная утилита, НЕ часть ARGUS: запускается сама по себе.
-- Лицензия проекта — GPL-3.0.
--
-- Единственный режим — ЗАКАЗ ИЗ AE (по требованию):
--   1. Ждёт, пока AE положит ингредиенты в буфер-сундук (ты заказал крафт в ME).
--   2. Распознаёт по составу буфера ОДИН полный рецепт и роняет РОВНО ОДНУ его порцию
--      в котёл СТРОГО ПО ПОРЯДКУ (transposer кладёт 1 предмет -> редстоун-импульс -> роняет).
--   3. Ждёт продукт в вакуум-сундуке EnderIO -> перекладывает его в ME.
--   4. Повторяет. Смесь из нескольких заказов разбирается по одной варке за раз;
--      размер порции задаёт РЕЦЕПТ (не AE) -> перекорма нет. Неполный остаток не роняется.
--
-- Порядок вброса детерминирован, потому что в дроппере в каждый момент лежит РОВНО
-- один тип предмета — случайность слота дроппера роли не играет.
--
-- ┌─ Подключение (см. схему в чате) ─────────────────────────────────────────┐
-- │  Dropper смотрит ВНИЗ, стоит над котлом — роняет предмет-сущность в воду.  │
-- │  Основной transposer касается буфер-сундука И дроппера (возит по 1).       │
-- │  Redstone I/O даёт импульс на дроппер (1 предмет за импульс).              │
-- │  ME Interface кладёт заказанные ингредиенты в буфер-сундук.                │
-- │  Продукт всплывает над водой -> вакуум-сундук EnderIO; отдельный transposer│
-- │  у него читает продукт и перекладывает в ME (cfg.output).                  │
-- └───────────────────────────────────────────────────────────────────────────┘
--
-- ВНИМАНИЕ — два узла нельзя проверить без игры, они помечены [ПРОВЕРИТЬ]:
--   * расходует ли котёл воду за варку (нужен ли долив) — cfg.side.water;
--   * чистый сбор всплывшего продукта вакуум-сундуком (радиус, вайтлист) — расстановка.

local component = require("component")
local sides     = require("sides")
local event     = require("event")
local computer  = require("computer")

--==========================================================================--
--                         ГРАФИЧЕСКИЙ ИНТЕРФЕЙС (GPU)                         --
--==========================================================================--
-- Экран OC рисует шрифтом Unifont (только BMP) — настоящих цветных эмодзи там
-- нет, поэтому иконки — BMP-символы (рендерятся), а "картинка" — блок-арт.

local COL = {
  bg=0x0F0F17, bar=0x2A2140, panel=0x15151F,
  text=0xE8E8F0, dim=0x8A8A9A, accent=0xB794F6,
  green=0x53E08A, amber=0xF5A623, red=0xF87171, blue=0x6AA6FF, cyan=0x35D6E8,
  pot=0x555565,
}
local IC = {
  start="⚗", info="•", drop="▼", ok="✔", err="✖",
  water="≈", wait="…", fire="♨",
}

local ui
do
  local gpuAddr    = component.list("gpu")()
  local screenAddr = component.list("screen")()

  if not gpuAddr or not screenAddr then
    -- нет экрана (headless / десктоп-тест) — всё уходит в print
    ui = {
      init  = function() end,
      close = function() end,
      state = function(txt) print("== " .. tostring(txt)) end,
      stat  = function() end,
      log   = function(icon, _, txt) print((icon or IC.info) .. " " .. tostring(txt)) end,
      tick  = function() end,
      boil  = function() end,
      flame = function() end,
    }
  else
    local unicode = require("unicode")
    local gpu = component.proxy(gpuAddr)
    local W, H = gpu.getResolution()

    local lines, stats = {}, {}       -- журнал и счётчики
    local liquid   = COL.blue         -- цвет зелья, меняется со статусом
    local frame    = 0                -- счётчик кадров анимации
    local boiling  = false            -- true при вбросе (кипит), false в ожидании
    local flameCol = nil              -- временный цвет пламени (вспышка при доливе)
    local logX, logY, logW, logH

    -- «Ведьмин» котёл: широкий рим внахлёст, пузатый корпус, три ножки, огонь.
    -- Живые строки — зелье (3,4) и огонь (9); остальное статично.
    -- Над римом (artY-2, artY-1) поднимается дымок.
    local artX, artY = 2, 5
    -- дымок по кадрам: { r(0 верхний,1 нижний), смещение X от artX }
    local SMK = {
      { {1,5},{1,8},{0,6} }, { {1,6},{1,9},{0,7} },
      { {1,4},{1,7},{0,5} }, { {1,7},{1,5},{0,8} },
    }
    local RIM   = "▗▄▄▄▄▄▄▄▄▄▄▄▖"       -- 1: рим (самый широкий)
    local SHLD  = " ▟█████████▙ "       -- 2: плечи внахлёст
    local BODY  = " ███████████ "       -- 5: пузо
    local TAPER = " ▜█████████▛ "       -- 6: сужение
    local FOOT  = "  ▝▀▀▀▀▀▀▀▘  "       -- 7: округлое дно
    local LEGS  = "   ┃  ┃  ┃   "       -- 8: три ножки
    local FLM   = { "   ♨  ♨  ♨   ", "  ♨   ♨   ♨  " }  -- 9: кадры огня
    -- пузырьки: { строка(3|4), смещение X от artX }; для стр.3 X=3..9, стр.4 X=2..10
    local BUB = {
      { {3,4},{4,7} }, { {4,3},{3,8} }, { {3,6},{4,9} },
      { {4,5},{3,3} }, { {3,9},{4,4} }, { {4,8},{3,5} },
    }
    local BUBX = { {3,7},{4,6},{3,5},{4,8},{3,4},{4,9} }  -- доп. пузырь при кипении
    local BUBCOL = 0xCFF6E6                                -- светлый блик пузырька

    local function fit(s, w)
      s = tostring(s)
      if unicode.wlen(s) <= w then return s end
      local out, ww = "", 0
      for i = 1, unicode.len(s) do
        local ch = unicode.sub(s, i, i)
        local cw = unicode.charWidth(ch)
        if ww + cw > w then break end
        out, ww = out .. ch, ww + cw
      end
      return out
    end

    local function put(x, y, s, fg, bg)
      gpu.setForeground(fg or COL.text)
      gpu.setBackground(bg or COL.bg)
      gpu.set(x, y, s)
    end

    local function drawArt()
      local f = frame
      -- дымок над римом (две строки, каждый кадр перерисовываем)
      gpu.setBackground(COL.bg)
      gpu.fill(artX, artY - 2, 13, 1, " ")
      gpu.fill(artX, artY - 1, 13, 1, " ")
      for _, s in ipairs(SMK[(f % #SMK) + 1]) do
        local upper = s[1] == 0
        put(artX + s[2], upper and (artY - 2) or (artY - 1),
            upper and "·" or "░", upper and 0x44444F or 0x6A6A78, COL.bg)
      end
      -- статичный корпус
      put(artX, artY + 0, RIM,   COL.dim, COL.bg)   -- рим
      put(artX, artY + 1, SHLD,  COL.pot, COL.bg)   -- плечи
      put(artX, artY + 4, BODY,  COL.pot, COL.bg)   -- пузо
      put(artX, artY + 5, TAPER, COL.pot, COL.bg)   -- сужение
      put(artX, artY + 6, FOOT,  COL.dim, COL.bg)   -- дно
      put(artX, artY + 7, LEGS,  COL.pot, COL.bg)   -- ножки
      -- зелье: строка 3 (уже) и строка 4 (шире) — стенки котла + заливка
      put(artX,      artY + 2, " ██",     COL.pot, COL.bg)
      put(artX + 3,  artY + 2, "▓▓▓▓▓▓▓", liquid,  COL.bg)
      put(artX + 10, artY + 2, "██ ",     COL.pot, COL.bg)
      put(artX,      artY + 3, " █",         COL.pot, COL.bg)
      put(artX + 2,  artY + 3, "▓▓▓▓▓▓▓▓▓", liquid,  COL.bg)
      put(artX + 11, artY + 3, "█ ",         COL.pot, COL.bg)
      -- пузырьки: при кипении густо (3/кадр), в ожидании редко (1 раз в 3 кадра)
      local bubbles
      if boiling then
        local base = BUB[(f % #BUB) + 1]
        bubbles = { base[1], base[2], BUBX[(f % #BUBX) + 1] }
      elseif f % 3 == 0 then
        bubbles = { BUB[(f % #BUB) + 1][1] }
      else
        bubbles = {}
      end
      local g = (f % 2 == 0) and "∘" or "°"
      for _, b in ipairs(bubbles) do
        put(artX + b[2], artY + b[1] - 1, g, BUBCOL, liquid)
      end
      -- огонь: вспышка (долив) > кипение (янтарь↔оранж) > спокойный янтарь
      local fc = flameCol or ((boiling and f % 2 == 1) and 0xFF7A3C or COL.amber)
      put(artX, artY + 8, FLM[(f % #FLM) + 1], fc, COL.bg)
    end

    local function drawStats()
      local sx = artX + 15
      for i, s in ipairs(stats) do
        local y = artY + (i - 1)
        gpu.setBackground(COL.bg); gpu.fill(sx, y, W - sx, 1, " ")
        put(sx, y, fit(s.label, 12), COL.dim, COL.bg)
        put(sx + 13, y, fit(s.val, W - sx - 14), COL.text, COL.bg)
      end
    end

    local function drawLog()
      for i = 1, logH do
        local y = logY + i - 1
        gpu.setBackground(COL.bg); gpu.fill(logX, y, logW, 1, " ")
        local e = lines[#lines - logH + i]
        if e then
          put(logX, y, e.icon, e.color, COL.bg)
          put(logX + 2, y, fit(e.text, logW - 2), COL.text, COL.bg)
        end
      end
    end

    ui = {}

    function ui.init()
      gpu.setBackground(COL.bg); gpu.fill(1, 1, W, H, " ")
      gpu.setBackground(COL.bar); gpu.fill(1, 1, W, 1, " ")
      put(2, 1, IC.start .. " ARGUS · Котёл Witchery", COL.accent, COL.bar)
      logX, logY = 2, artY + 11
      logW, logH = W - 2, H - (artY + 11)
      put(2, logY - 1, "Журнал:", COL.dim, COL.bg)
      drawArt(); drawStats(); drawLog()
    end

    function ui.state(txt, color)
      if color then liquid = color end
      gpu.setBackground(COL.panel); gpu.fill(1, 2, W, 1, " ")
      put(2, 2, IC.info .. " " .. fit(txt, W - 4), color or COL.text, COL.panel)
      drawArt()
    end

    function ui.stat(label, val)
      for _, s in ipairs(stats) do
        if s.label == label then s.val = val; drawStats(); return end
      end
      stats[#stats + 1] = { label = label, val = val }
      drawStats()
    end

    function ui.log(icon, color, txt)
      lines[#lines + 1] = { icon = icon or IC.info, color = color or COL.text, text = txt }
      if #lines > 300 then table.remove(lines, 1) end
      drawLog()
    end

    function ui.tick()
      frame = frame + 1
      drawArt()
    end

    function ui.boil(on)
      boiling = on and true or false
      drawArt()
    end

    function ui.flame(color)
      flameCol = color        -- nil = вернуть обычный цвет пламени
      drawArt()
    end

    function ui.close()
      gpu.setForeground(0xFFFFFF); gpu.setBackground(0x000000)
      gpu.fill(1, 1, W, H, " "); gpu.set(1, 1, "")
    end
  end
end

local droppedTotal = 0   -- всего уронено предметов (для счётчика)

--==========================================================================--
--                              КОНФИГУРАЦИЯ                                   --
--==========================================================================--

local cfg = {
  -- Адреса компонентов. nil = взять первый найденный этого типа.
  transposer = "34eeb223-0237-4a3f-ae57-37279b686007",  -- основной, у дроппера/сундука
  redstone   = "f587a0ff-5f5c-439f-9393-594c55d54c6e",  -- Redstone I/O сверху дроппера

  -- Стороны (require("sides")). Как их ВИДИТ соответствующий блок.
  side = {
    stock   = sides.bottom, -- буфер-сундук ПОД transposer'ом
    dropper = sides.east,   -- дроппер к ВОСТОКУ от transposer'а (он с запада)
    pulse   = sides.bottom, -- Redstone I/O сверху дроппера → выход вниз
    water   = nil,          -- [ПРОВЕРИТЬ] редстоун-выход на диспенсер воды; nil = не лить
  },

  -- ВЫХОД: вакуум-сундук EnderIO с продуктом, читается ОТДЕЛЬНЫМ компонентом по адресу.
  --   address   — адрес компонента у вакуум-сундука (узнать: `components` в OpenOS или
  --               `lua> component.list()`). nil = не ждать продукт (менее надёжно).
  --   chestSide — сторона этого компонента к вакуум-сундуку.
  --   toME      — переложить продукт в ME после детекта. ТРЕБУЕТ transposer (Adapter не
  --               умеет transferItem): компонент должен касаться и вакуум-сундука, и ME Interface.
  --   meSide    — сторона компонента к ME Interface (только для toME).
  output = {
    address   = "2683e08d-8f22-4375-9e9b-d082c5ae4ebf",  -- transposer у вакуум-сундука
    chestSide = sides.top,    -- вакуум-сундук СВЕРХУ
    toME      = true,         -- OC сам перекладывает продукт в ME
    meSide    = sides.bottom, -- ME Interface СНИЗУ
  },

  brewTimeout = 60,   -- сек: потолок ожидания продукта в вакуум-сундуке

  -- Тайминги вброса (подобрать под котёл).
  settle = 0.8,       -- пауза после каждого вброса, чтобы котёл "увидел" сущность
  pulse  = 0.1,       -- длительность редстоун-импульса

  stable     = 0.5,   -- пауза для проверки, что AE дозаложил ингредиенты в буфер
  idleNotice = 30,    -- каждые N сек печатать "жду заказ"; 0 = молчать

  -- По какому полю сверять предметы: "label" (отображаемое имя) или "name" (реестровый id).
  -- "name" надёжнее (не зависит от локализации), но нужно знать точный id, напр. "witchery:mandrakeroot".
  matchBy = "label",
}

--==========================================================================--
--                                РЕЦЕПТЫ                                      --
--==========================================================================--
-- Каждый рецепт — СТРОГО упорядоченный список вброса. Длина любая, повторы можно.
-- По этим рецептам скрипт РАСПОЗНАЁТ заказ в буфере (по составу) и роняет одну порцию.
-- product — что и сколько появляется на выходе (для детекта готовности в вакуум-сундуке).
--
-- Записать порядок можно двумя способами (нормализуются одинаково):
--
--   order — компактно, плоский список сверху вниз В ПОРЯДКЕ ВБРОСА.
--           элемент: "Имя"  ИЛИ  {"Имя", N}  (N штук этого предмета подряд).
--
--   steps — подробно, таблицами { label=/name=, count= }.
--
-- Имя сверяется по cfg.matchBy: "label" (отображаемое) или "name" (реестровый id).

-- Рецепты котла Witchery/WitcheryExtras (GTNH 2.8.3). Имена — как в NEI (matchBy="label").
-- Порядок — из NEI. Кол-во каждого принято ПО 1 (в списках не было цифр) — если в NEI
-- на ингредиенте стоит число >1, поправить count/повтор.
local recipes = {

  ["golden_chalk"] = {
    product = { label = "Golden Chalk", count = 1 },
    order = { "Mandrake Root", "Gold Dust", "Diamond Vapor", "Ritual Chalk" },
  },

  ["otherwhere_chalk"] = {
    product = { label = "Otherwhere Chalk", count = 1 },
    order = { "Endereye Dust", "End Powder", "Tear of the Goddess", "Manyullyn Crystal", "Ritual Chalk" },
  },

  ["infernal_chalk"] = {
    product = { label = "Infernal Chalk", count = 1 },
    order = { "Nether Wart", "Blaze Rod", "Nether Star", "Ritual Chalk" },
  },

  ["steak"] = {
    product = { label = "Steak", count = 1 },
    order = { "Raw Beef" },
  },
}

--==========================================================================--
--                                  ДВИЖОК                                     --
--==========================================================================--

-- ленивое разрешение компонентов -------------------------------------------
local _t, _r
local function transposer()
  if _t then return _t end
  local addr = cfg.transposer or component.list("transposer")()
  assert(addr, "не найден компонент transposer")
  _t = component.proxy(addr); return _t
end

local function redstone()
  if _r then return _r end
  local addr = cfg.redstone or component.list("redstone")()
  assert(addr, "не найден компонент redstone (Redstone I/O или карта)")
  _r = component.proxy(addr); return _r
end

-- компонент у вакуум-сундука (адаптер/transposer), задаётся по адресу
local _out
local function outProxy()
  if _out then return _out end
  assert(cfg.output.address, "cfg.output.address не задан (адрес адаптера/transposer'а)")
  _out = component.proxy(cfg.output.address)
  assert(_out, "компонент cfg.output.address не найден: " .. tostring(cfg.output.address))
  return _out
end

-- нормализация рецепта: order -> steps --------------------------------------
local function specFrom(entry)
  local key = (cfg.matchBy == "name") and "name" or "label"
  if type(entry) == "string" then
    return { [key] = entry, count = 1 }
  end
  if entry.label or entry.name then                    -- уже спецификация
    return { label = entry.label, name = entry.name, count = entry.count or 1 }
  end
  return { [key] = entry[1], count = entry[2] or 1 }   -- позиционное {"Имя", N}
end

local function normalizeRecipe(r)
  if r.steps then return r end
  assert(r.order, "у рецепта нет ни steps, ни order")
  local steps = {}
  for i, e in ipairs(r.order) do steps[i] = specFrom(e) end
  r.steps = steps
  return r
end

-- сверка предмета со спецификацией ------------------------------------------
local function itemMatches(stack, spec)
  if cfg.matchBy == "name" and spec.name then
    return stack.name == spec.name
  end
  return stack.label == (spec.label or spec.name)
end

-- подсчёт продукта в вакуум-сундуке (по спецификации) ------------------------
local function chestCount(spec)
  local p    = outProxy()
  local side = cfg.output.chestSide
  local n = p.getInventorySize(side) or 0
  local total = 0
  for s = 1, n do
    local st = p.getStackInSlot(side, s)
    if st and itemMatches(st, spec) then total = total + (st.size or 0) end
  end
  return total
end

-- ждём появления продукта в вакуум-сундуке -----------------------------------
local function waitForProduct(recipe, tag)
  local spec = recipe.product
  local base = chestCount(spec)
  local deadline = computer.uptime() + cfg.brewTimeout
  while computer.uptime() < deadline do
    os.sleep(1)
    if chestCount(spec) >= base + spec.count then return end
  end
  error(("таймаут: продукт '%s' не появился за %d сек (%s)")
    :format(spec.label or spec.name, cfg.brewTimeout, tag))
end

-- редстоун-импульс -----------------------------------------------------------
local function firePulse(side)
  local r = redstone()
  r.setOutput(side, 15)
  os.sleep(cfg.pulse)
  r.setOutput(side, 0)
end

-- вброс одного предмета -------------------------------------------------------
local function findStockSlot(spec)
  local t = transposer()
  local n = t.getInventorySize(cfg.side.stock) or 0
  for s = 1, n do
    local st = t.getStackInSlot(cfg.side.stock, s)
    if st and itemMatches(st, spec) then return s end
  end
  return nil
end

local function dropperEmpty()
  return transposer().getStackInSlot(cfg.side.dropper, 1) == nil
end

local function injectOne(spec)
  local name = spec.label or spec.name
  local slot = findStockSlot(spec)
  assert(slot, "нет ингредиента на складе: " .. name)

  local moved = transposer().transferItem(cfg.side.stock, cfg.side.dropper, 1, slot, 1)
  assert(moved and moved >= 1, "не удалось загрузить дроппер: " .. name)

  firePulse(cfg.side.pulse)
  os.sleep(cfg.settle)

  -- не молчим, если дроппер не выстрелил (провод/сторона PULSE)
  assert(dropperEmpty(), "дроппер не выбросил '" .. name .. "' — проверь редстоун и сторону pulse")

  droppedTotal = droppedTotal + 1
  ui.log(IC.drop, COL.green, "уронил " .. name)
  ui.stat("Уронил", tostring(droppedTotal))
end

local function injectStep(step)
  for _ = 1, step.count do injectOne(step) end
end

-- Переложить весь продукт из вакуум-сундука в ME. Нужен transposer (у Adapter нет
-- transferItem — методы прокси это вызываемые таблицы, проверяем на nil, а не на "function").
local function moveToME()
  if not cfg.output.toME or not cfg.output.address then return end
  local p = outProxy()
  if not p.transferItem then
    ui.log(IC.err, COL.red, "перекладка в ME: у cfg.output нет transferItem — нужен transposer, не Adapter")
    return
  end
  local src, me = cfg.output.chestSide, cfg.output.meSide
  local n, moved = p.getInventorySize(src) or 0, 0
  for s = 1, n do
    local st = p.getStackInSlot(src, s)
    if st then moved = moved + (p.transferItem(src, me, st.size, s) or 0) end
  end
  if moved > 0 then ui.log(IC.info, COL.cyan, ("переложено в ME: %d"):format(moved)) end
end

-- долив воды [ПРОВЕРИТЬ: нужен ли он вообще] ---------------------------------
local function refillWater()
  if not cfg.side.water then return end
  ui.log(IC.water, COL.blue, "долив воды в котёл")
  ui.flame(COL.blue)                  -- синяя вспышка пламени на время долива
  firePulse(cfg.side.water)
  os.sleep(cfg.settle)
  ui.flame(nil)                       -- вернуть обычный огонь
end

-- одна варка -----------------------------------------------------------------
local function brewOnce(recipe, tag)
  refillWater()
  ui.boil(true)                         -- кипит во время вброса
  for _, step in ipairs(recipe.steps) do
    injectStep(step)
  end
  ui.boil(false)                        -- вброс окончен, ждём продукт
  waitForProduct(recipe, tag)
  moveToME()                            -- переложить продукт из вакуум-сундука в ME
end

-- буфер-режим: порядок из слотов буфера --------------------------------------
-- Снимок буфера: массив { slot=, name=, label=, size= } по НЕПУСТЫМ слотам, по порядку.
local function bufferSnapshot()
  local t = transposer()
  local n = t.getInventorySize(cfg.side.stock) or 0
  local snap = {}
  for s = 1, n do
    local st = t.getStackInSlot(cfg.side.stock, s)
    if st then
      snap[#snap + 1] = { slot = s, name = st.name, label = st.label, size = st.size }
    end
  end
  return snap
end

local function snapEqual(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i].slot ~= b[i].slot or a[i].name ~= b[i].name or a[i].size ~= b[i].size then
      return false
    end
  end
  return true
end

-- Ждём непустой И стабильный буфер (защита от гонки частичной выкладки).
-- Возвращает снимок, либо nil при прерывании.
local function waitStableBatch()
  local idle = 0
  while true do
    if event.pull(0, "interrupted") then return nil end
    local snap = bufferSnapshot()
    if #snap > 0 then
      os.sleep(cfg.stable)
      if snapEqual(snap, bufferSnapshot()) then return snap end
    else
      os.sleep(1)
      ui.tick()                       -- анимация котла, пока ждём
      idle = idle + 1
      if cfg.idleNotice > 0 and idle % cfg.idleNotice == 0 then
        ui.log(IC.wait, COL.amber,
          ("жду набор из AE… (%d c — задание кончилось или варка зависла?)"):format(idle))
      end
    end
  end
end

-- auto-режим: заказ из AE, распознать рецепт по буферу, ронять по одной порции ---
-- ключ предмета по matchBy (у Witchery/GT метадата при общем name — различаем лейблом)
local function keyOfStack(st) return (cfg.matchBy == "name") and st.name or st.label end
local function keyOfSpec(sp)
  if cfg.matchBy == "name" then return sp.name or sp.label end
  return sp.label or sp.name
end

-- сколько каждого предмета лежит в буфере (по ключу)
local function bufferCounts()
  local t = transposer()
  local n = t.getInventorySize(cfg.side.stock) or 0
  local counts = {}
  for s = 1, n do
    local st = t.getStackInSlot(cfg.side.stock, s)
    if st then
      local k = keyOfStack(st)
      counts[k] = (counts[k] or 0) + (st.size or 0)
    end
  end
  return counts
end

-- потребность рецепта на ОДНУ порцию: ключ -> сколько
local function recipeReq(recipe)
  local req = {}
  for _, step in ipairs(recipe.steps) do
    local k = keyOfSpec(step)
    req[k] = (req[k] or 0) + (step.count or 1)
  end
  return req
end

-- подобрать рецепт, все ингредиенты которого есть в буфере в достатке.
-- при неоднозначности берём самый «специфичный» (больше разных ингредиентов),
-- имена перебираем по алфавиту — выбор детерминирован.
local function matchRecipe(counts)
  local names = {}
  for name in pairs(recipes) do names[#names + 1] = name end
  table.sort(names)
  local bestName, best, bestSize = nil, nil, -1
  for _, name in ipairs(names) do
    local recipe = normalizeRecipe(recipes[name])
    local req, ok, size = recipeReq(recipe), true, 0
    for k, need in pairs(req) do
      size = size + 1
      if (counts[k] or 0) < need then ok = false; break end
    end
    if ok and size > bestSize then bestName, best, bestSize = name, recipe, size end
  end
  return bestName, best
end

-- подпись состояния буфера (чтобы не спамить одним и тем же предупреждением)
local function bufSig(counts)
  local keys = {}
  for k in pairs(counts) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. counts[k] end
  return table.concat(parts, ",")
end

-- Единственный режим: заказ приходит из AE в буфер. Каждый проход распознаёт
-- ОДИН полный рецепт по составу буфера и роняет РОВНО ОДНУ его порцию, затем
-- повторяет. Так смесь из нескольких заказов разбирается по одной варке за раз;
-- неполный остаток (AE ещё дозакладывает) НЕ роняется — ждём догрузки.
local function runAuto()
  ui.log(IC.start, COL.accent, "заказ из AE, порция за раз по рецепту")
  local made, lastUnknown = 0, nil
  while true do
    ui.state("ожидание заказа из AE", COL.blue)
    local snap = waitStableBatch()          -- ждём стабильный непустой буфер
    if not snap then
      ui.log(IC.info, COL.dim, "прервано пользователем")
      ui.state("остановлено", COL.dim)
      return
    end
    local counts = bufferCounts()
    local name, recipe = matchRecipe(counts)
    if recipe then
      lastUnknown = nil
      made = made + 1
      ui.state(("варка %s #%d"):format(name, made), COL.green)
      ui.stat("Сварено", tostring(made))
      ui.log(IC.info, COL.text, "распознан рецепт: " .. name)
      brewOnce(recipe, ("%s #%d"):format(name, made))
      ui.log(IC.ok, COL.cyan, ("%s #%d готов"):format(name, made))
    else
      -- остаток не складывается ни в один рецепт: не роняем, ждём догрузки.
      -- предупреждаем один раз на каждое НОВОЕ состояние буфера, чтобы не спамить.
      local sig = bufSig(counts)
      if sig ~= lastUnknown then
        ui.log(IC.err, COL.red, "в буфере неполный набор — жду недостающие ингредиенты")
        ui.state("неполный набор — жду", COL.amber)
        lastUnknown = sig
      end
      os.sleep(2); ui.tick()
    end
  end
end

-- проверки перед стартом -----------------------------------------------------
local function preflight()
  local t = transposer()
  local n = t.getInventorySize(cfg.side.dropper) or 0
  assert(n > 0, "transposer не видит дроппер на стороне cfg.side.dropper")
  for s = 1, n do
    assert(not t.getStackInSlot(cfg.side.dropper, s),
      "дроппер не пуст (слот " .. s .. ") — очисти его перед запуском")
  end
  redstone().setOutput(cfg.side.pulse, 0)
  if cfg.side.water then redstone().setOutput(cfg.side.water, 0) end
  -- transposer должен видеть буфер/склад
  assert((transposer().getInventorySize(cfg.side.stock) or 0) > 0,
    "transposer не видит буфер/склад на стороне cfg.side.stock")
  -- компонент у вакуум-сундука (выход) обязателен: детект + перекладка в ME
  assert(cfg.output.address, "cfg.output.address не задан (transposer у вакуум-сундука)")
  local p = outProxy()
  assert((p.getInventorySize(cfg.output.chestSide) or 0) > 0,
    "cfg.output не видит вакуум-сундук на стороне chestSide")
  if cfg.output.toME then
    assert(p.transferItem,
      "cfg.output.toME=true, но у компонента нет transferItem — нужен transposer (Adapter не умеет), " ..
      "касающийся вакуум-сундука и ME Interface")
  end
end

-- главный цикл ---------------------------------------------------------------
local function main()
  ui.init()
  ui.log(IC.start, COL.accent, "cauldron.lua запущен")
  preflight()
  ui.log(IC.ok, COL.green, "проверки пройдены")
  runAuto()
end

--==========================================================================--
--                                  ЗАПУСК                                     --
--==========================================================================--

local ok, err = pcall(main)

-- что бы ни случилось — гасим редстоун, чтобы дроппер не остался под сигналом
pcall(function() redstone().setOutput(cfg.side.pulse, 0) end)
if cfg.side.water then pcall(function() redstone().setOutput(cfg.side.water, 0) end) end

if not ok then
  ui.log(IC.err, COL.red, "ОШИБКА: " .. tostring(err))
  ui.state("ОШИБКА — нажми любую клавишу", COL.red)
  pcall(function() event.pull(15, "key_down") end)   -- дать прочитать перед сбросом экрана
end

ui.close()
if not ok then
  io.stderr:write("ОШИБКА: " .. tostring(err) .. "\n")
end
