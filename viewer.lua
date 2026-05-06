-- ============================================================================
-- viewer.lua — текстовый просмотрщик с прокруткой для OpenComputers (1.12.2)
-- ----------------------------------------------------------------------------
-- Стандартный терминал OC прокручивает только вниз: ушедшие за верхний край
-- строки исчезают навсегда. Этот скрипт открывает файл целиком в память и
-- даёт полный контроль над просмотром.
--
-- Управление (только мышью, без клавиатуры):
--   • колесо мыши       — построчная прокрутка (3 строки за щелчок)
--   • клик по скроллбару — прыжок к позиции
--   • перетаскивание ползунка — плавная навигация
--   • ▲ / ▼ на скроллбаре  — построчно
--   • НАЧАЛО / КОНЕЦ      — к началу/концу файла
--   • СТР◀ / СТР▶         — постранично
--   • ПЕРЕНОС             — переключить перенос длинных строк
--   • ВЫХОД               — закрыть просмотрщик
--
-- Дополнительно:
--   • подсветка строк лога по эвристикам (=== ✓ ✗ ERROR WARN >>>)
--   • нумерация строк
--   • маркер ↪ для продолжения перенесённой строки
--   • анимированная подпись в нижней рамке
--
-- Использование:
--   viewer            — открывает /home/flux_probe.log
--   viewer <путь>     — открывает указанный файл
-- ============================================================================

local component = require("component")
local event     = require("event")
local unicode   = require("unicode")
local computer  = require("computer")
local fs        = require("filesystem")
local term      = require("term")
local Renderer  = require("renderer")

local gpu = component.gpu

-- ---------- Аргументы и проверки ----------
local args = {...}
local DEFAULT_PATH = "/home/flux_probe.log"
local filePath = args[1] or DEFAULT_PATH

if not fs.exists(filePath) then
    print("Ошибка: файл не найден: " .. filePath)
    print("Использование: viewer <путь_к_файлу>")
    return
end

local fileSize = fs.size(filePath) or 0
if fileSize > 1024 * 1024 then
    print(string.format("Файл слишком большой (%.1f МБ). Лимит 1 МБ во избежание OOM.",
        fileSize / (1024 * 1024)))
    return
end

-- ---------- Загрузка файла ----------
local function loadFile(path)
    local f, err = io.open(path, "r")
    if not f then return nil, err end
    local lines = {}
    for line in f:lines() do
        -- Нормализуем: убираем \r, \t заменяем на 4 пробела
        line = line:gsub("\r", ""):gsub("\t", "    ")
        table.insert(lines, line)
    end
    f:close()
    return lines
end

local rawLines, loadErr = loadFile(filePath)
if not rawLines then
    print("Не удалось прочитать файл: " .. tostring(loadErr))
    return
end

-- ---------- Палитра ----------
local C = {
    bg         = 0x000000,
    primary    = 0x00b8d4,
    border     = 0x0d6e8c,
    alarmRed   = 0xff3860,
    posGreen   = 0x00ff88,
    warnYellow = 0xffdd00,
    warnOrange = 0xff8800,
    accent     = 0x9d4edd,
    textLight  = 0xcccccc,
    textMid    = 0x888888,
    textDim    = 0x444444,
    lineNumCol = 0x666666,
    white      = 0xffffff,
}

-- ---------- Подсветка строк по эвристикам ----------
-- Применяется к ОРИГИНАЛЬНОЙ строке. Все её перенесённые куски наследуют цвет.
local function detectLineColor(line)
    if line:match("^%s*[=─-]+%s*$") then return C.border       end
    if line:match("^%s*=+")          then return C.primary     end  -- "=== HEADER ==="
    if line:match("^%s*✓")           then return C.posGreen    end
    if line:match("^%s*✗")           then return C.alarmRed    end
    if line:match("^%s*>>>")         then return C.warnYellow  end  -- вызов метода
    if line:match("^%s*•")           then return C.textLight   end
    if line:find("ERROR") or line:find("FAIL")     then return C.alarmRed    end
    if line:find("WARN")  or line:find("ARG_REQ")  then return C.warnOrange  end
    return C.textLight
end

-- ---------- Перенос строк ----------
-- Превращает rawLines в массив записей {orig, text, cont, color}
-- cont=true для всех кусков кроме первого (используется для отступа ↪)
local function wrapAll(lines, width)
    if width < 10 then width = 10 end
    local out = {}
    for origIdx, line in ipairs(lines) do
        local color = detectLineColor(line)
        local len   = unicode.len(line)
        if len == 0 then
            out[#out + 1] = { orig = origIdx, text = "", cont = false, color = color }
        else
            local pos, first = 1, true
            while pos <= len do
                local chunk = unicode.sub(line, pos, pos + width - 1)
                out[#out + 1] = { orig = origIdx, text = chunk, cont = not first, color = color }
                pos   = pos + width
                first = false
            end
        end
    end
    return out
end

-- Без переноса: 1 raw строка = 1 запись (визуально обрезается до contentW)
local function noWrap(lines)
    local out = {}
    for i, line in ipairs(lines) do
        out[#out + 1] = { orig = i, text = line, cont = false, color = detectLineColor(line) }
    end
    return out
end

-- ---------- Состояние ----------
local state = {
    scrollY    = 0,        -- индекс верхней видимой строки в wrapped
    wrapMode   = true,
    wrapped    = nil,
    contentW   = nil,
    viewH      = nil,
    lnW        = nil,      -- ширина колонки номеров строк
    needRewrap = true,
    buttons    = {},
    scrollbar  = nil,
}

-- ---------- Инициализация рендерера и буферов ----------
Renderer.init(6.0)

local sw, sh           = gpu.getResolution()
local secondaryBuffer  = gpu.allocateBuffer(sw, sh)
local mainBuffer       = gpu.getActiveBuffer()

local function cleanupAndExit()
    if secondaryBuffer then pcall(gpu.freeBuffer, secondaryBuffer) end
    if mainBuffer      then pcall(gpu.setActiveBuffer, mainBuffer) end
    gpu.setBackground(0x000000)
    gpu.setForeground(0xffffff)
    term.clear(); term.setCursor(1, 1)
    print("Просмотрщик закрыт.")
    os.exit()
end

-- ---------- Геометрия экрана ----------
-- Раскладка:
--   row 1            — верхняя рамка (с заголовком)
--   row 2            — статус (имя файла + позиция)
--   row 3            — разделитель ╠══╣
--   rows 4..H-3      — содержимое (viewH = H-6)
--   row H-2          — разделитель ╠══╣
--   row H-1          — кнопки
--   row H            — нижняя рамка (с подписью)
--   col 1            — левая рамка ║
--   cols 2..1+lnW    — номера строк
--   col 2+lnW        — разделитель │
--   cols 4+lnW..W-2  — текст
--   col W-1          — скроллбар
--   col W            — правая рамка ║
local function computeGeometry()
    local W, H = Renderer.config.width, Renderer.config.height
    state.viewH = H - 6
    local maxLN = math.max(1, #rawLines)
    state.lnW   = math.max(3, #tostring(maxLN))
    state.contentW = W - 2 - state.lnW - 2 - 2  -- frames + lnum + sep+pad + scrollbar+pad
    if state.contentW < 10 then state.contentW = 10 end
end

local function ensureWrapped()
    if not state.needRewrap and state.wrapped then return end
    state.wrapped = state.wrapMode
        and wrapAll(rawLines, state.contentW)
        or  noWrap(rawLines)
    state.needRewrap = false
    -- Обрезать прокрутку под новую длину
    local maxY = math.max(0, #state.wrapped - state.viewH)
    if state.scrollY > maxY then state.scrollY = maxY end
    if state.scrollY < 0    then state.scrollY = 0    end
end

-- ---------- Прокрутка ----------
local function clampScroll()
    local maxY = math.max(0, #state.wrapped - state.viewH)
    if state.scrollY > maxY then state.scrollY = maxY end
    if state.scrollY < 0    then state.scrollY = 0    end
end

local function scrollBy(dy)     state.scrollY = state.scrollY + dy; clampScroll() end
local function scrollPage(dir)  scrollBy(dir * math.max(1, state.viewH - 2))      end
local function scrollHome()     state.scrollY = 0                                  end
local function scrollEnd()      state.scrollY = math.max(0, #state.wrapped - state.viewH) end
local function jumpToFraction(frac)
    local maxY = math.max(0, #state.wrapped - state.viewH)
    state.scrollY = math.max(0, math.min(maxY, math.floor(maxY * frac + 0.5)))
end

-- ---------- Скроллбар ----------
local function drawScrollbar(x, y1, y2, total, visible, pos)
    local h = y2 - y1 + 1
    if h < 3 then return nil end

    gpu.setForeground(C.primary)
    gpu.set(x, y1, "▲")
    gpu.set(x, y2, "▼")

    local trackTop = y1 + 1
    local trackH   = h - 2

    gpu.setForeground(C.textDim)
    gpu.fill(x, trackTop, 1, trackH, "░")

    if total > visible then
        local thumbSize = math.max(1, math.floor(trackH * visible / total))
        local maxPos    = math.max(1, total - visible)
        local thumbY    = trackTop + math.floor((pos / maxPos) * (trackH - thumbSize))
        if thumbY > trackTop + trackH - thumbSize then
            thumbY = trackTop + trackH - thumbSize
        end
        gpu.setForeground(C.primary)
        gpu.fill(x, thumbY, 1, thumbSize, "█")
    elseif total > 0 then
        -- Всё помещается — ползунок занимает всю дорожку
        gpu.setForeground(C.primary)
        gpu.fill(x, trackTop, 1, trackH, "█")
    end

    return {
        upArrow   = { x = x, y = y1, w = 1, h = 1 },
        downArrow = { x = x, y = y2, w = 1, h = 1 },
        track     = { x = x, y = trackTop, w = 1, h = trackH },
        trackTop  = trackTop,
        trackH    = trackH,
    }
end

-- ---------- Содержимое ----------
local function drawContent()
    local W, H    = Renderer.config.width, Renderer.config.height
    local startRow = 4
    local lnW     = state.lnW
    local sepX    = 1 + lnW + 1
    local textX   = sepX + 2

    -- Очистить область
    gpu.setBackground(C.bg)
    gpu.fill(2, startRow, W - 2, state.viewH, " ")

    -- Пустой файл
    if #state.wrapped == 0 then
        gpu.setForeground(C.textMid)
        local msg = "(файл пуст)"
        gpu.set(math.floor((W - unicode.len(msg)) / 2) + 1,
                startRow + math.floor(state.viewH / 2),
                msg)
        return
    end

    -- Вертикальный разделитель колонки номеров (тусклым)
    gpu.setForeground(C.textDim)
    gpu.fill(sepX, startRow, 1, state.viewH, "│")

    -- Рисуем строки
    local lastOrig = -1
    for i = 1, state.viewH do
        local entry = state.wrapped[state.scrollY + i]
        if not entry then break end
        local row = startRow + i - 1

        -- Номер строки только для первой части перенесённой группы
        if not entry.cont and entry.orig ~= lastOrig then
            local ln = tostring(entry.orig)
            gpu.setForeground(C.lineNumCol)
            gpu.set(2 + lnW - unicode.len(ln), row, ln)
            lastOrig = entry.orig
        end

        -- Текст
        if entry.cont then
            -- Маркер продолжения
            gpu.setForeground(C.textDim)
            gpu.set(textX, row, "↪")
            gpu.setForeground(entry.color)
            gpu.set(textX + 2, row, entry.text)
        else
            gpu.setForeground(entry.color)
            -- Если перенос выключен и строка длиннее — обрезаем визуально
            local txt = entry.text
            if not state.wrapMode and unicode.len(txt) > state.contentW then
                txt = unicode.sub(txt, 1, state.contentW - 1) .. "…"
            end
            gpu.set(textX, row, txt)
        end
    end
end

-- ---------- Шапка ----------
local function drawHeader()
    local W, H = Renderer.config.width, Renderer.config.height

    Renderer.drawBox(1, 1, W, H, C.primary, " ТЕКСТОВЫЙ ПРОСМОТРЩИК ", "double")

    local total = #state.wrapped
    local viewStart = total > 0 and (state.scrollY + 1) or 0
    local viewEnd   = math.min(total, state.scrollY + state.viewH)
    local pct
    if total <= state.viewH then
        pct = 100
    else
        pct = (state.scrollY / math.max(1, total - state.viewH)) * 100
    end

    -- Имя файла (с многоточием слева если длинное)
    local fname = filePath
    local maxFnameW = W - 50
    if maxFnameW < 20 then maxFnameW = 20 end
    if unicode.len(fname) > maxFnameW then
        fname = "…" .. unicode.sub(fname, unicode.len(fname) - maxFnameW + 2)
    end

    gpu.setForeground(C.textMid)
    gpu.set(3, 2, "Файл:")
    gpu.setForeground(C.warnYellow)
    gpu.set(9, 2, fname)

    local statusRight = string.format("Стр %d-%d из %d  •  %d%%",
        viewStart, viewEnd, total, math.floor(pct + 0.5))
    gpu.setForeground(C.textLight)
    gpu.set(W - unicode.len(statusRight) - 2, 2, statusRight)

    -- Разделитель ╠══╣ под шапкой
    gpu.setForeground(C.border)
    gpu.set(1, 3, "╠")
    gpu.fill(2, 3, W - 2, 1, "═")
    gpu.set(W, 3, "╣")
end

-- ---------- Кнопки ----------
local function drawButtons()
    local W, H = Renderer.config.width, Renderer.config.height
    local btnY = H - 1
    state.buttons = {}

    local btnDefs = {
        { "НАЧАЛО",  "home", C.accent     },
        { "СТР◀",    "pgup", C.warnYellow },
        { "СТР▶",    "pgdn", C.warnYellow },
        { "КОНЕЦ",   "end",  C.accent     },
        { "ПЕРЕНОС " .. (state.wrapMode and "ON" or "OFF"),
                     "wrap", state.wrapMode and C.posGreen or C.textMid },
        { "ВЫХОД",   "exit", C.alarmRed   },
    }

    -- Разделитель над кнопками
    gpu.setForeground(C.border)
    gpu.set(1, H - 2, "╠")
    gpu.fill(2, H - 2, W - 2, 1, "═")
    gpu.set(W, H - 2, "╣")

    -- Считаем общую ширину для центрирования
    local sep    = 3
    local totalW = 0
    for i, d in ipairs(btnDefs) do
        totalW = totalW + unicode.len("[ " .. d[1] .. " ]")
        if i < #btnDefs then totalW = totalW + sep end
    end

    local fx = math.floor((W - totalW) / 2) + 1
    for _, d in ipairs(btnDefs) do
        local b = Renderer.drawButton(fx, btnY, d[1], d[3])
        b.action = d[2]
        table.insert(state.buttons, b)
        fx = fx + b.w + sep
    end
end

-- ---------- Главная отрисовка ----------
local function drawAll()
    gpu.setActiveBuffer(secondaryBuffer)
    Renderer.clear(C.bg)
    Renderer.updateAnimation()

    computeGeometry()
    ensureWrapped()

    drawHeader()
    drawContent()

    -- Скроллбар внутри content области (col W-1, rows 4..H-3)
    local W, H = Renderer.config.width, Renderer.config.height
    state.scrollbar = drawScrollbar(W - 1, 4, H - 3,
        #state.wrapped, state.viewH, state.scrollY)

    drawButtons()

    -- Подпись автора, встроенная в нижнюю рамку справа
    local sigText = " by ShadowStormOne "
    local sigW    = unicode.len(sigText)
    if W > sigW + 6 then
        Renderer.drawAnimatedSignature(W - sigW - 3, H, sigText)
    end

    gpu.setActiveBuffer(mainBuffer)
    gpu.bitblt(mainBuffer, 1, 1, W, H, secondaryBuffer, 1, 1)
end

-- ---------- Действия ----------
local function handleAction(action)
    if     action == "exit" then cleanupAndExit()
    elseif action == "home" then scrollHome()
    elseif action == "end"  then scrollEnd()
    elseif action == "pgup" then scrollPage(-1)
    elseif action == "pgdn" then scrollPage(1)
    elseif action == "wrap" then
        state.wrapMode   = not state.wrapMode
        state.needRewrap = true
    end
end

-- ---------- Цикл событий ----------
computeGeometry()
ensureWrapped()

local lastRedraw     = 0
local redrawInterval = 0.2  -- 5 FPS — достаточно для плавной анимации подписи

while true do
    local now = computer.uptime()
    if now - lastRedraw >= redrawInterval then
        local ok, err = pcall(drawAll)
        if not ok then
            cleanupAndExit()
        end
        lastRedraw = now
    end

    local ev    = { event.pull(0.05) }
    local eType = ev[1]

    if eType == "scroll" then
        -- ev[5] = направление: +1 от пользователя (вверх), -1 к пользователю (вниз)
        local direction = ev[5] or 0
        scrollBy(-direction * 3)
        lastRedraw = 0  -- немедленный перерисовывание

    elseif eType == "touch" then
        local tx, ty = ev[3], ev[4]
        local handled = false

        for _, b in ipairs(state.buttons) do
            if Renderer.hitTest(b, tx, ty) then
                handleAction(b.action)
                handled = true
                break
            end
        end
        if not handled and state.scrollbar then
            local sb = state.scrollbar
            if Renderer.hitTest(sb.upArrow, tx, ty) then
                scrollBy(-1); handled = true
            elseif Renderer.hitTest(sb.downArrow, tx, ty) then
                scrollBy(1); handled = true
            elseif Renderer.hitTest(sb.track, tx, ty) then
                local frac = (ty - sb.trackTop) / math.max(1, sb.trackH - 1)
                jumpToFraction(frac); handled = true
            end
        end
        if handled then lastRedraw = 0 end

    elseif eType == "drag" then
        -- Перетаскивание ползунка — приятная мелочь для дальних монитор-сборок
        local tx, ty = ev[3], ev[4]
        if state.scrollbar and Renderer.hitTest(state.scrollbar.track, tx, ty) then
            local sb = state.scrollbar
            local frac = (ty - sb.trackTop) / math.max(1, sb.trackH - 1)
            jumpToFraction(frac)
            lastRedraw = 0
        end

    elseif eType == "interrupted" then
        cleanupAndExit()
    end
end
