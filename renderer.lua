-- ============================================================================
-- renderer.lua — улучшенный рендерер для OpenComputers (MC 1.12.2)
-- Новое: палитра, субсимвольный прогресс-бар (1/8), спарклайны, big-font
-- на полублоках, кнопки, оптимизация через gpu.fill, тач-хит-тест
-- ============================================================================

local component  = require("component")
local computer   = require("computer")
local unicode    = require("unicode")
local gpu        = component.gpu

local Renderer = {}

-- ---------- Стили рамок ----------
local borders = {
    single = {
        topLeft = "┌", topRight = "┐", bottomLeft = "└", bottomRight = "┘",
        horizontal = "─", vertical = "│",
    },
    double = {
        topLeft = "╔", topRight = "╗", bottomLeft = "╚", bottomRight = "╝",
        horizontal = "═", vertical = "║",
    },
    rounded = {
        topLeft = "╭", topRight = "╮", bottomLeft = "╰", bottomRight = "╯",
        horizontal = "─", vertical = "│",
    },
}

-- ---------- Подсимвольные блоки для прогресс-бара (1/8 ячейки) ----------
local subBlocks = {[0] = " ", "▏","▎","▍","▌","▋","▊","▉","█"}

-- ---------- Уровни для спарклайнов (8 высот в одной строке) ----------
local sparkBlocks = {"▁","▂","▃","▄","▅","▆","▇","█"}

-- ---------- Кадры спиннера (Брайль) ----------
local spinnerChars = {"⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"}

Renderer.config = {
    width = nil, height = nil,
    scale = 1.0, minScale = 0.5, maxScale = 8.0,
    animationFrame = 1,
    lastAnimTime = 0,
    animationSpeed = 0.1,
    borderStyle = "double",
    paletteApplied = false,
    palette = nil,
}

-- ---------- Палитра в киберпанк-стиле ----------
-- T2+ GPU поддерживает gpu.setPaletteColor для индексов 0..15
local CYBER_PALETTE = {
    [0]  = 0x000000, [1]  = 0x0a1929, [2]  = 0x00b8d4, [3]  = 0x0d6e8c,
    [4]  = 0xff3860, [5]  = 0x00ff88, [6]  = 0xffdd00, [7]  = 0xff8800,
    [8]  = 0x9d4edd, [9]  = 0xcccccc, [10] = 0x666666, [11] = 0x333333,
    [12] = 0x40e0d0, [13] = 0xffffff, [14] = 0x00ffff, [15] = 0x88ddff,
}

function Renderer.applyPalette(palette)
    palette = palette or CYBER_PALETTE
    local depth = gpu.getDepth()
    if depth < 4 then return false end
    for i, c in pairs(palette) do
        pcall(gpu.setPaletteColor, i, c)
    end
    Renderer.config.palette = palette
    Renderer.config.paletteApplied = true
    return true
end

-- ---------- Инициализация ----------
function Renderer.init(scale)
    if scale then Renderer.setScale(scale) end
    local maxW, maxH = gpu.maxResolution()
    local sw = math.floor(maxW * Renderer.config.scale)
    local sh = math.floor(maxH * Renderer.config.scale)
    sw = math.max(40, math.min(sw, maxW))
    sh = math.max(20, math.min(sh, maxH))
    pcall(gpu.setResolution, sw, sh)
    Renderer.config.width, Renderer.config.height = gpu.getResolution()
    if not Renderer.config.paletteApplied then Renderer.applyPalette() end
    return Renderer.config.width, Renderer.config.height
end

function Renderer.setScale(scale)
    scale = math.max(Renderer.config.minScale, math.min(scale, Renderer.config.maxScale))
    Renderer.config.scale = scale
    if Renderer.config.width then Renderer.init() end
end

-- ---------- Очистка экрана ----------
function Renderer.clear(bgColor)
    gpu.setBackground(bgColor or 0x000000)
    gpu.fill(1, 1, Renderer.config.width, Renderer.config.height, " ")
end

-- ---------- Анимация (вызывать раз за кадр) ----------
function Renderer.updateAnimation()
    local now = computer.uptime()
    if now - Renderer.config.lastAnimTime >= Renderer.config.animationSpeed then
        Renderer.config.animationFrame = (Renderer.config.animationFrame % #spinnerChars) + 1
        Renderer.config.lastAnimTime = now
    end
end

function Renderer.spinnerChar()
    return spinnerChars[Renderer.config.animationFrame]
end

-- ---------- Рамка (использует gpu.fill вместо string.rep+set) ----------
function Renderer.drawBox(x, y, width, height, color, title, style)
    style = style or Renderer.config.borderStyle
    local b = borders[style] or borders.double
    gpu.setForeground(color)

    -- верхняя кромка
    gpu.set(x, y, b.topLeft)
    if width > 2 then gpu.fill(x + 1, y, width - 2, 1, b.horizontal) end
    gpu.set(x + width - 1, y, b.topRight)

    -- боковины: одна gpu.fill на каждую сторону
    if height > 2 then
        gpu.fill(x,             y + 1, 1, height - 2, b.vertical)
        gpu.fill(x + width - 1, y + 1, 1, height - 2, b.vertical)
    end

    -- нижняя кромка
    gpu.set(x, y + height - 1, b.bottomLeft)
    if width > 2 then gpu.fill(x + 1, y + height - 1, width - 2, 1, b.horizontal) end
    gpu.set(x + width - 1, y + height - 1, b.bottomRight)

    -- заголовок
    if title then
        local titleStr = " " .. title .. " "
        local tx = x + math.floor((width - unicode.len(titleStr)) / 2)
        gpu.set(tx, y, titleStr)
    end
    -- Тень убрана: символ ▀ под рамкой создавал тонкую тёмную линию,
    -- которая визуально "разрывала" соседние стэк-панели на 1 пиксель.
end

-- ---------- Прогресс-бар: 8 субуровней на ячейку ----------
-- ВНИМАНИЕ: занимает width+2 ячеек (с обрамлением ▕ ▏)
function Renderer.drawProgressBar(x, y, width, current, max, color, label)
    local ratio = 0
    if max and max > 0 and current then
        ratio = math.max(0, math.min(1, current / max))
    end
    local total = width * 8
    local filled = math.floor(total * ratio)
    local fullCells = math.floor(filled / 8)
    local remainder = filled % 8

    gpu.setForeground(color)
    gpu.set(x, y, "▕")

    -- заполненная часть
    if fullCells > 0 then
        gpu.fill(x + 1, y, fullCells, 1, "█")
    end
    -- частичная ячейка (1/8...7/8)
    if remainder > 0 and fullCells < width then
        gpu.set(x + 1 + fullCells, y, subBlocks[remainder])
    end
    -- пустая часть тёмным цветом
    local usedCells = fullCells + (remainder > 0 and 1 or 0)
    if usedCells < width then
        gpu.setForeground(0x333333)
        gpu.fill(x + 1 + usedCells, y, width - usedCells, 1, "░")
    end
    gpu.setForeground(color)
    gpu.set(x + width + 1, y, "▏")

    -- текст процента под баром
    local pctText = label or string.format("%.1f%%", ratio * 100)
    local pctX = x + math.floor((width + 2 - unicode.len(pctText)) / 2)
    gpu.set(pctX, y + 1, pctText)
    return ratio * 100
end

-- ---------- Спарклайн: 1 строка, 8 уровней высоты ----------
function Renderer.drawSparkline(x, y, history, color, fixedMax)
    if not history or #history == 0 then return end
    local maxV = fixedMax or 0
    if not fixedMax then
        for _, v in ipairs(history) do if v and v > maxV then maxV = v end end
    end
    if maxV <= 0 then maxV = 1 end
    gpu.setForeground(color)
    local line = ""
    for _, v in ipairs(history) do
        local val = v or 0
        local ratio = math.max(0, math.min(1, val / maxV))
        local idx = math.max(1, math.min(8, math.ceil(ratio * 8)))
        if val == 0 then idx = 1 end
        line = line .. sparkBlocks[idx]
    end
    gpu.set(x, y, line)
end

-- ---------- Спарклайн в 2 строки: 17 уровней высоты ----------
-- Использует комбинацию сабблоков в верхней и нижней строке.
-- Нижняя строка заполняется первой (уровни 1..8 — частичный нижний блок,
-- уровень 8 — полный █). Уровни 9..16 = нижняя █ + верхняя строка с
-- частичным блоком, который визуально появляется над серединой 2-строчного
-- блока. Получается единый "столбик" растущий снизу вверх.
function Renderer.drawSparkline2(x, y, history, color, fixedMax)
    if not history or #history == 0 then return end
    local maxV = fixedMax or 0
    if not fixedMax then
        for _, v in ipairs(history) do if v and v > maxV then maxV = v end end
    end
    if maxV <= 0 then maxV = 1 end

    gpu.setForeground(color)
    local topLine, botLine = "", ""
    for _, v in ipairs(history) do
        local val   = v or 0
        local ratio = math.max(0, math.min(1, val / maxV))
        local level = math.floor(ratio * 16 + 0.5)
        if val > 0 and level == 0 then level = 1 end

        if level == 0 then
            topLine = topLine .. " "
            botLine = botLine .. " "
        elseif level <= 8 then
            topLine = topLine .. " "
            botLine = botLine .. sparkBlocks[level]
        else
            topLine = topLine .. sparkBlocks[level - 8]
            botLine = botLine .. "█"
        end
    end
    gpu.set(x, y,     topLine)
    gpu.set(x, y + 1, botLine)
end

-- ---------- Текст ----------
function Renderer.text(x, y, str, color)
    if color then gpu.setForeground(color) end
    gpu.set(x, y, str)
    return unicode.len(str)
end

function Renderer.centerText(text, y, color)
    gpu.setForeground(color)
    local x = math.floor((Renderer.config.width - unicode.len(text)) / 2) + 1
    gpu.set(x, y, text)
    return 1
end

function Renderer.drawAdaptiveText(x, y, text, color, maxWidth)
    gpu.setForeground(color)
    local words = {}
    for w in text:gmatch("%S+") do table.insert(words, w) end
    local line, cy = "", y
    for _, w in ipairs(words) do
        if unicode.len(line) + unicode.len(w) + 1 <= maxWidth then
            line = line .. (line == "" and "" or " ") .. w
        else
            gpu.set(x, cy, line); cy = cy + 1; line = w
        end
    end
    if line ~= "" then gpu.set(x, cy, line) end
    return cy - y + 1
end

-- ---------- Шрифт 3×6 пикселей на полублоках для крупных цифр ----------
-- Каждый глиф: 3 строки × 3 символа = 6 пиксельных рядов высотой
local font3x6 = {
    ["0"] = {"█▀█","█ █","█▄█"},
    ["1"] = {"▄█ "," █ ","▄█▄"},
    ["2"] = {"▀▀█","▄█▀","█▄▄"},
    ["3"] = {"▀▀█"," ▀█","▄▄█"},
    ["4"] = {"█ █","▀▀█","  █"},
    ["5"] = {"█▀▀","▀▀█","▄▄█"},
    ["6"] = {"█▀▀","█▀█","█▄█"},
    ["7"] = {"▀▀█","  █","  █"},
    ["8"] = {"█▀█","█▀█","█▄█"},
    ["9"] = {"█▀█","▀▀█","▄▄█"},
    ["."] = {"   ","   "," ▄ "},
    [","] = {"   ","   ","▗▘ "},
    [":"] = {" ▄ ","   "," ▀ "},
    ["%"] = {"█ █"," ▄ ","█ █"},
    ["/"] = {"  █"," █ ","█  "},
    [" "] = {"   ","   ","   "},
    ["-"] = {"   ","▄▄▄","   "},
    ["+"] = {"   ","▄█▄"," ▀ "},
    ["k"] = {"█ █","█▀ ","█ ▀"},
    ["M"] = {"█▄█","█ █","█ █"},
    ["G"] = {"█▀▀","█ █","█▄█"},
    ["T"] = {"▀█▀"," █ "," █ "},
    ["P"] = {"█▀█","█▀ ","█  "},
    ["R"] = {"█▀█","█▀ ","█ █"},
    ["F"] = {"█▀▀","█▀ ","█  "},
    ["E"] = {"█▀▀","█▀ ","█▄▄"},
    ["?"] = {"▀▀█"," ▄▀"," ▀ "},
}

-- Возвращает количество КОЛОНОК которые займёт `str` (3 кол + 1 разделитель)
function Renderer.measureHugeNumber(str)
    return #str * 4
end

function Renderer.drawHugeNumber(x, y, str, color)
    gpu.setForeground(color)
    for row = 1, 3 do
        local line = ""
        for i = 1, #str do
            local ch = str:sub(i, i)
            local glyph = font3x6[ch] or font3x6[ch:upper()] or font3x6["?"]
            line = line .. glyph[row] .. " "
        end
        gpu.set(x, y + row - 1, line)
    end
    return Renderer.measureHugeNumber(str)
end

-- ---------- Старый "big text" (Unicode-bold) — для совместимости ----------
local bigChars = {
    ["0"]="𝟎",["1"]="𝟏",["2"]="𝟐",["3"]="𝟑",["4"]="𝟒",
    ["5"]="𝟓",["6"]="𝟔",["7"]="𝟕",["8"]="𝟖",["9"]="𝟗",
    ["A"]="𝐀",["B"]="𝐁",["C"]="𝐂",["D"]="𝐃",["E"]="𝐄",
    ["F"]="𝐅",["G"]="𝐆",["H"]="𝐇",["I"]="𝐈",["J"]="𝐉",
    ["K"]="𝐊",["L"]="𝐋",["M"]="𝐌",["N"]="𝐍",["O"]="𝐎",
    ["P"]="𝐏",["Q"]="𝐐",["R"]="𝐑",["S"]="𝐒",["T"]="𝐓",
    ["U"]="𝐔",["V"]="𝐕",["W"]="𝐖",["X"]="𝐗",["Y"]="𝐘",["Z"]="𝐙",
}

function Renderer.drawBigText(x, y, text, color)
    gpu.setForeground(color)
    local out = ""
    for i = 1, unicode.len(text) do
        local c = unicode.sub(text, i, i):upper()
        out = out .. (bigChars[c] or c)
    end
    gpu.set(x, y, out)
    return unicode.len(out)
end

-- ---------- Кнопка с возвратом hit-rect ----------
function Renderer.drawButton(x, y, label, color, bgColor, active)
    local txt = active and ("◆ " .. label .. " ◆") or ("[ " .. label .. " ]")
    local w = unicode.len(txt)
    if bgColor then gpu.setBackground(bgColor) end
    gpu.setForeground(color)
    gpu.set(x, y, txt)
    if bgColor then gpu.setBackground(0x000000) end
    return { x = x, y = y, w = w, h = 1 }
end

function Renderer.hitTest(rect, tx, ty)
    if not rect then return false end
    return tx >= rect.x and tx < rect.x + rect.w
       and ty >= rect.y and ty < rect.y + rect.h
end

-- ---------- Анимированная подпись с бегущей волной-бликом ----------
-- По тексту слева направо движется яркий блик в 3 ступени:
-- центр (белый) → края (палевый) → остальное (тусклый base).
-- Скорость подобрана под redraw 4 Hz: ~4 символа в секунду, плавно.
function Renderer.drawAnimatedSignature(x, y, text, baseColor, midColor, hotColor)
    text       = text       or "by ShadowStormOne"
    baseColor  = baseColor  or 0x0d6e8c    -- тусклый cyan (фон)
    midColor   = midColor   or 0x00b8d4    -- средний cyan (полутон)
    hotColor   = hotColor   or 0xffffff    -- белый (центр блика)

    local now      = computer.uptime()
    local len      = unicode.len(text)
    local cycleLen = len + 8                -- блик уезжает за край перед перезапуском
    local wavePos  = (now * 4) % cycleLen - 4  -- стартует слева за пределом

    for i = 1, len do
        local dist = math.abs(i - wavePos)
        local color
        if     dist < 0.7 then color = hotColor
        elseif dist < 1.7 then color = midColor
        else                   color = baseColor
        end
        gpu.setForeground(color)
        gpu.set(x + i - 1, y, unicode.sub(text, i, i))
    end
end

return Renderer