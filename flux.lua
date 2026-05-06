-- ============================================================================
-- flux.lua — мониторинг Flux Network + ME для OpenComputers (MC 1.12.2)
-- Возможности:
--   • 3 вкладки: ЭНЕРГИЯ / ЦПУ / СЕТЬ ME (Tab или клик / 1-2-3)
--   • История I/O (спарклайны), прогноз ETA до полного/пустого буфера
--   • Звуковые тревоги при низком заряде или дефиците
--   • Сохранение настроек в /etc/fluxmon.cfg
--   • Tach-кнопки внизу + Ctrl-горячие клавиши
--   • pcall на всех вызовах API: монитор не падает при отвале контроллеров
--   • Раздельные интервалы опроса данных и перерисовки
--   • Динамический максимум буфера (auto-tracking максимума)
-- ============================================================================

local component     = require("component")
local event         = require("event")
local unicode       = require("unicode")
local term          = require("term")
local computer      = require("computer")
local serialization = require("serialization")
local fs            = require("filesystem")
local Renderer      = require("renderer")

local flux = component.isAvailable("flux_controller") and component.flux_controller or nil
local me   = component.isAvailable("me_controller")   and component.me_controller   or nil
local gpu  = component.gpu

if not flux then print("Ошибка: Flux контроллер не найден!"); return end
if not me   then print("Ошибка: ME контроллер не найден!");   return end

-- ---------- Палитра ----------
local C = {
    bg         = 0x000000,
    panelBg    = 0x0a1929,
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
    turquoise  = 0x40e0d0,
    white      = 0xffffff,
    paleCyan   = 0x88ddff,
}

local MAX_CPUS    = 54
local CONFIG_PATH = "/etc/fluxmon.cfg"

-- ---------- Конфигурация (загружается с диска) ----------
local config = {
    useCompactFormat = true,
    maxTotalEnergy   = 13000000000,
    autoMaxEnergy    = true,
    alarmLowPct      = 25,
    alarmDeficitSec  = 5,
    soundEnabled     = true,
    activeTab        = 1,
    historyLength    = 60,
    scale            = 6.0,
}

local function saveConfig()
    pcall(function()
        local f = io.open(CONFIG_PATH, "w")
        if f then f:write(serialization.serialize(config)); f:close() end
    end)
end

local function loadConfig()
    if not fs.exists(CONFIG_PATH) then return end
    pcall(function()
        local f = io.open(CONFIG_PATH, "r")
        if not f then return end
        local raw = f:read("*a"); f:close()
        local data = serialization.unserialize(raw)
        if type(data) == "table" then
            for k, v in pairs(data) do config[k] = v end
        end
    end)
end
loadConfig()

-- ---------- Состояние ----------
local state = {
    energyInfo     = nil,
    networkInfo    = nil,
    cpuInfo        = { total = 0, busy = 0, free = 0, cpuDetails = {} },
    meItemCount    = 0,
    meTypeCount    = 0,
    inputHistory   = {},
    outputHistory  = {},
    fillHistory    = {},
    deficitSince   = nil,
    apiOk          = true,
    apiError       = nil,
    lastAlarmBeep  = 0,
    lastDataPoll   = 0,
}

-- ---------- Буфера ----------
local secondaryBuffer, mainBuffer

local function setupBuffers()
    if secondaryBuffer then pcall(gpu.freeBuffer, secondaryBuffer) end
    local sw, sh = gpu.getResolution()
    secondaryBuffer = gpu.allocateBuffer(sw, sh)
    mainBuffer      = gpu.getActiveBuffer()
end

-- ---------- Завершение ----------
local function cleanupAndExit()
    saveConfig()
    if secondaryBuffer then pcall(gpu.freeBuffer, secondaryBuffer) end
    if mainBuffer      then pcall(gpu.setActiveBuffer, mainBuffer) end
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
    term.clear(); term.setCursor(1, 1)
    print("Программа завершена.")
    os.exit()
end

-- ---------- Утилиты ----------
local function formatEnergy(n, compact)
    if not n then return "—" end
    if compact then
        local prefixes = {"", "k", "M", "G", "T", "P"}
        local idx, v = 1, n
        while v >= 1000 and idx < #prefixes do v = v / 1000; idx = idx + 1 end
        local fmt = v >= 100 and "%.0f" or v >= 10 and "%.1f" or "%.2f"
        return string.format(fmt .. " %sRF", v, prefixes[idx])
    else
        local s = tostring(math.floor(n))
        s = s:reverse():gsub("(%d%d%d)", "%1."):reverse():gsub("^%.", "")
        return s .. " RF"
    end
end

local function formatDuration(seconds)
    if not seconds or seconds < 0 or seconds == math.huge then return "∞" end
    if seconds < 60     then return string.format("%dс", math.floor(seconds)) end
    if seconds < 3600   then return string.format("%dм %dс", math.floor(seconds/60), math.floor(seconds%60)) end
    if seconds < 86400  then return string.format("%dч %dм", math.floor(seconds/3600), math.floor((seconds%3600)/60)) end
    return string.format("%.1fд", seconds / 86400)
end

local function getEnergyColor(value, maxValue)
    if not value or not maxValue or maxValue == 0 then return C.alarmRed end
    local r = math.min(value, maxValue) / maxValue
    if r > 0.75 then return C.posGreen
    elseif r > 0.5  then return C.warnYellow
    elseif r > 0.25 then return C.warnOrange
    else return C.alarmRed end
end

local function pct(value, maxValue)
    if not value or not maxValue or maxValue == 0 then return 0 end
    return math.min(100, math.max(0, (math.min(value, maxValue) / maxValue) * 100))
end

local function pushHistory(buf, val, maxLen)
    table.insert(buf, val)
    while #buf > maxLen do table.remove(buf, 1) end
end

local function tryBeep(freq, dur)
    if config.soundEnabled then pcall(computer.beep, freq, dur) end
end

local function getTrendArrow(net)
    if net > 0 then return "▲", C.posGreen
    elseif net < 0 then return "▼", C.alarmRed
    else return "▬", C.textMid end
end

local function getETA(energy, maxE, netPerTick)
    if not netPerTick or netPerTick == 0 then return nil end
    local remaining = netPerTick > 0 and (maxE - energy) or energy
    if remaining <= 0 then return 0 end
    -- 20 тиков в секунду
    return remaining / (math.abs(netPerTick) * 20)
end

-- ---------- Опрос данных ----------
local function pollData()
    local ok1, energy  = pcall(flux.getEnergyInfo)
    local ok2, network = pcall(flux.getNetworkInfo)
    local ok3, cpus    = pcall(me.getCpus)

    if not (ok1 and ok2 and ok3) then
        state.apiOk    = false
        state.apiError = (not ok1 and "Flux: энергия")
                      or (not ok2 and "Flux: сеть")
                      or "ME: CPU"
        return
    end
    state.apiOk       = true
    state.apiError    = nil
    state.energyInfo  = energy
    state.networkInfo = network

    -- CPU
    local total, busy = 0, 0
    local details = {}
    for i = 1, math.min(MAX_CPUS, #cpus) do
        local c = cpus[i]
        total = total + 1
        if c.busy then busy = busy + 1 end
        details[i] = { index = i, busy = c.busy, name = c.name }
    end
    state.cpuInfo = { total = total, busy = busy, free = total - busy, cpuDetails = details }

    -- ME предметы (best-effort, может отсутствовать в некоторых версиях AE2)
    pcall(function()
        local items = me.getItemsInNetwork()
        local count = 0
        for _, it in ipairs(items) do count = count + (it.size or 0) end
        state.meItemCount = count
        state.meTypeCount = #items
    end)

    -- Авто-максимум: отслеживаем фактический пик без накруток.
    -- Прогресс-бар может стоять на 100% длительно — это нормально, значит
    -- сеть полностью заряжена. Лишний % создавал бы фальшивый "запас".
    if config.autoMaxEnergy and energy.totalEnergy
       and energy.totalEnergy > config.maxTotalEnergy then
        config.maxTotalEnergy = energy.totalEnergy
    end

    -- История
    pushHistory(state.inputHistory,  energy.energyInput  or 0, config.historyLength)
    pushHistory(state.outputHistory, energy.energyOutput or 0, config.historyLength)
    pushHistory(state.fillHistory,   energy.totalEnergy  or 0, config.historyLength)

    -- Дефицит
    if (energy.energyOutput or 0) > (energy.energyInput or 0) then
        if not state.deficitSince then state.deficitSince = computer.uptime() end
    else
        state.deficitSince = nil
    end

    -- Тревоги
    local now = computer.uptime()
    if now - state.lastAlarmBeep > 3 then
        local fillPct = pct(energy.totalEnergy, config.maxTotalEnergy)
        if fillPct <= config.alarmLowPct then
            tryBeep(880, 0.15); state.lastAlarmBeep = now
        elseif state.deficitSince and (now - state.deficitSince) >= config.alarmDeficitSec then
            tryBeep(440, 0.10); state.lastAlarmBeep = now
        end
    end
end

-- ---------- Кнопки (заполняются при отрисовке) ----------
local buttons = { tabs = {}, footer = {} }

-- ---------- Вкладка: ЭНЕРГИЯ ----------
local function drawEnergyTab(W, H)
    local e = state.energyInfo
    if not e then return end

    local fillPct   = pct(e.totalEnergy, config.maxTotalEnergy)
    local fillColor = getEnergyColor(e.totalEnergy, config.maxTotalEnergy)

    -- Крупное отображение текущей энергии (3×6 шрифт)
    local hugeY    = 6
    local hugeText = formatEnergy(e.totalEnergy or 0, config.useCompactFormat)
    local hugeW    = Renderer.measureHugeNumber(hugeText)
    local hugeX    = math.floor((W - hugeW) / 2) + 1
    Renderer.drawHugeNumber(hugeX, hugeY, hugeText, fillColor)

    -- Прогресс-бар
    local barWidth = math.min(W - 16, 70)
    local barX     = math.floor((W - barWidth) / 2) + 1
    local barY     = hugeY + 4
    Renderer.drawProgressBar(barX, barY, barWidth, e.totalEnergy or 0, config.maxTotalEnergy, fillColor)

    -- ============================================================
    --   ПАНЕЛЬ СТАТИСТИКИ — увеличена и разбита на 3 смысл-группы
    -- ============================================================
    local panelX = 5
    local panelW = W - 8
    local panelY = barY + 3
    local panelH = 12  -- было 9: + 3 строки для воздуха и группировки
    Renderer.drawBox(panelX, panelY, panelW, panelH, C.border, " СТАТИСТИКА ЭНЕРГИИ ", "single")

    local input  = e.energyInput  or 0
    local output = e.energyOutput or 0
    local net    = input - output
    local arrow, arrowColor = getTrendArrow(net)
    local eta      = getETA(e.totalEnergy or 0, config.maxTotalEnergy, net)
    local etaLabel = net > 0 and "до полного"
                  or net < 0 and "до пустого"
                  or "стабильно"

    local groupFlows = {  -- потоки энергии
        { "БУФЕР", formatEnergy(e.totalBuffer, config.useCompactFormat),  C.paleCyan },
        { "ВХОД",  formatEnergy(input,  config.useCompactFormat) .. "/t", C.posGreen },
        { "ВЫХОД", formatEnergy(output, config.useCompactFormat) .. "/t", C.alarmRed },
    }
    local groupTrend = {  -- аналитика трендов
        { "БАЛАНС " .. arrow, formatEnergy(math.abs(net), config.useCompactFormat) .. "/t", arrowColor   },
        { "ПРОГНОЗ",          etaLabel .. ": " .. (eta and formatDuration(eta) or "—"),     C.warnYellow },
    }
    local groupStatus = {  -- общий статус
        { "ЗАПОЛНЕНО", string.format("%.2f%% (макс. %s)", fillPct,
                          formatEnergy(config.maxTotalEnergy, true)), fillColor },
    }

    local function drawGroup(rows, startY)
        gpu.setForeground(C.textLight)
        for i, r in ipairs(rows) do gpu.set(panelX + 2, startY + i - 1, r[1] .. ":") end
        for i, r in ipairs(rows) do
            gpu.setForeground(r[3])
            gpu.set(panelX + 20, startY + i - 1, r[2])
        end
    end
    -- Раскладка строк панели (между группами 1 пустая строка):
    --  +1..+3 поток   +4 gap   +5..+6 тренд   +7 gap   +8 статус   +9..+10 padding
    drawGroup(groupFlows,  panelY + 1)
    drawGroup(groupTrend,  panelY + 5)
    drawGroup(groupStatus, panelY + 8)

    -- ============================================================
    --   ПАНЕЛЬ ИСТОРИИ I/O — 2-строчные спарклайны + легенда
    -- ============================================================
    local sparkW = math.min(W - 30, config.historyLength)
    local sparkH = 13   -- было 6: 6 строк под графики + gap + 3 строки легенды + padding
    local sparkY = panelY + panelH + 1

    if sparkW > 10 and sparkY + sparkH < H - 3 then
        local sparkX = math.floor((W - sparkW) / 2) + 1
        local boxX   = sparkX - 8
        local boxW   = sparkW + 24
        Renderer.drawBox(boxX, sparkY, boxW, sparkH, C.border,
            " ИСТОРИЯ I/O — последние " .. config.historyLength .. " опросов ", "single")

        -- Каждый спарклайн занимает 2 строки. Подпись и значение
        -- ставим напротив НИЖНЕЙ строки (там основной визуал столбиков).
        local function drawTrack(topY, history, color, fixedMax, label, readout)
            Renderer.drawSparkline2(sparkX, topY, history, color, fixedMax)
            gpu.setForeground(color)
            gpu.set(boxX + 2, topY + 1, label)
            -- Значение прижимаем к правому краю панели
            local rx = boxX + boxW - 2 - unicode.len(readout)
            gpu.set(rx, topY + 1, readout)
        end

        drawTrack(sparkY + 1, state.inputHistory,  C.posGreen, nil,
                  "Вход",  formatEnergy(input,  true) .. "/t")
        drawTrack(sparkY + 3, state.outputHistory, C.alarmRed, nil,
                  "Выход", formatEnergy(output, true) .. "/t")
        drawTrack(sparkY + 5, state.fillHistory,   C.primary,  config.maxTotalEnergy,
                  "Запас", string.format("%.1f%%", fillPct))

        -- Тонкий разделитель между графиками и легендой
        local sepY = sparkY + 7
        gpu.setForeground(C.textDim)
        gpu.fill(boxX + 2, sepY, boxW - 4, 1, "─")

        -- Легенда: расшифровка что значит каждое название
        local legendY = sepY + 1
        local legend = {
            { C.posGreen, "Вход",  "энергия поступающая в сеть (RF/тик)"        },
            { C.alarmRed, "Выход", "энергия покидающая сеть (RF/тик)"           },
            { C.primary,  "Запас", "текущее заполнение общего буфера сети"      },
        }
        for i, item in ipairs(legend) do
            local y = legendY + i - 1
            gpu.setForeground(item[1])
            gpu.set(boxX + 2, y, "●")
            gpu.setForeground(C.textLight)
            gpu.set(boxX + 4, y, item[2] .. " — " .. item[3])
        end
    end
end

-- ---------- Вкладка: ЦПУ ----------
local function drawCpuTab(W, H)
    local ci     = state.cpuInfo
    local panelX = 5
    local panelW = W - 8

    -- Сводка
    local sumY = 6
    Renderer.drawBox(panelX, sumY, panelW, 5, C.border, " СВОДКА ПРОЦЕССОРОВ ", "single")

    local busyPct   = ci.total > 0 and (ci.busy / ci.total) * 100 or 0
    local busyColor = busyPct > 75 and C.alarmRed
                   or busyPct > 50 and C.warnYellow
                   or C.posGreen

    gpu.setForeground(C.textLight); gpu.set(panelX + 2,  sumY + 1, "ВСЕГО:")
    gpu.setForeground(C.primary);   gpu.set(panelX + 12, sumY + 1, string.format("%d / %d", ci.total, MAX_CPUS))
    gpu.setForeground(C.textLight); gpu.set(panelX + 28, sumY + 1, "ЗАНЯТО:")
    gpu.setForeground(C.alarmRed);  gpu.set(panelX + 38, sumY + 1, tostring(ci.busy))
    gpu.setForeground(C.textLight); gpu.set(panelX + 48, sumY + 1, "СВОБОДНО:")
    gpu.setForeground(C.posGreen);  gpu.set(panelX + 60, sumY + 1, tostring(ci.free))

    Renderer.drawProgressBar(panelX + 2, sumY + 3, panelW - 6, ci.busy, math.max(1, ci.total),
        busyColor, string.format("Загрузка: %.0f%%", busyPct))

    -- Сетка состояний CPU
    local gridY = sumY + 6
    local gridH = H - gridY - 4
    if gridH < 6 then return end
    Renderer.drawBox(panelX, gridY, panelW, gridH, C.border, " СОСТОЯНИЕ ЦПУ ", "single")

    local cpusPerCol   = gridH - 3
    local colWidth     = 22
    local colsAvailable = math.floor((panelW - 4) / colWidth)

    -- Группируем по статусу — минимум вызовов setForeground
    -- Сначала свободные
    gpu.setForeground(C.posGreen)
    for i = 1, ci.total do
        local cpu = ci.cpuDetails[i]
        if cpu and not cpu.busy then
            local col = math.floor((i - 1) / cpusPerCol)
            local row = (i - 1) % cpusPerCol
            if col < colsAvailable then
                gpu.set(panelX + 2 + col * colWidth, gridY + 1 + row,
                    string.format("● ЦПУ %02d   СВОБОДЕН", i))
            end
        end
    end
    -- Затем занятые
    gpu.setForeground(C.alarmRed)
    for i = 1, ci.total do
        local cpu = ci.cpuDetails[i]
        if cpu and cpu.busy then
            local col = math.floor((i - 1) / cpusPerCol)
            local row = (i - 1) % cpusPerCol
            if col < colsAvailable then
                gpu.set(panelX + 2 + col * colWidth, gridY + 1 + row,
                    string.format("◉ ЦПУ %02d   В РАБОТЕ", i))
            end
        end
    end
end

-- ---------- Вкладка: СЕТЬ ME ----------
local function drawStorageTab(W, H)
    local panelX = 5
    local panelW = W - 8
    local panelY = 6
    Renderer.drawBox(panelX, panelY, panelW, 8, C.border, " ME СЕТЬ — ХРАНИЛИЩЕ ", "single")

    local rows = {
        { "ТИПОВ ПРЕДМЕТОВ", tostring(state.meTypeCount), C.primary  },
        { "ВСЕГО ШТУК",      tostring(state.meItemCount), C.paleCyan },
    }
    gpu.setForeground(C.textLight)
    for i, r in ipairs(rows) do gpu.set(panelX + 2, panelY + i, r[1] .. ":") end
    for i, r in ipairs(rows) do
        gpu.setForeground(r[3])
        gpu.set(panelX + 22, panelY + i, r[2])
    end

    gpu.setForeground(C.textMid)
    gpu.set(panelX + 2, panelY + 5,
        "Расширенная статистика (хранилища, кристаллы) зависит от версии AE2;")
    gpu.set(panelX + 2, panelY + 6,
        "при отсутствии вызова getItemsInNetwork значения будут 0.")
end

-- ---------- Шапка и вкладки ----------
local function drawHeader(W)
    Renderer.drawBox(1, 1, W, Renderer.config.height, C.primary,
        " FLUX NETWORK & ME МОНИТОРИНГ ", "double")

    local netLine
    local netColor
    if state.apiOk then
        local netName = (state.networkInfo and state.networkInfo.name) or "—"
        netLine = "⚡ Сеть: " .. netName .. " ⚡  " .. Renderer.spinnerChar()
        netColor = C.turquoise
    else
        netLine = "⚠ NO SIGNAL: " .. (state.apiError or "?") .. "  " .. Renderer.spinnerChar()
        netColor = C.alarmRed
    end
    Renderer.centerText(netLine, 3, netColor)
end

local function drawTabs(y, W)
    local labels = { "ЭНЕРГИЯ", "ЦПУ", "СЕТЬ ME" }
    -- Считаем общую ширину
    local total = 0
    for i = 1, #labels do
        local visible = (i == config.activeTab)
            and ("◆ " .. labels[i] .. " ◆")
            or  ("[ " .. labels[i] .. " ]")
        total = total + unicode.len(visible) + 2
    end
    local x = math.floor((W - total) / 2) + 1

    buttons.tabs = {}
    for i = 1, #labels do
        local active = (i == config.activeTab)
        local color  = active and C.white or C.textMid
        local rect   = Renderer.drawButton(x, y, labels[i], color, nil, active)
        rect.tab     = i
        table.insert(buttons.tabs, rect)
        x = x + rect.w + 2
    end
end

-- ---------- Главная функция отрисовки ----------
local function drawScreen()
    local W, H = Renderer.config.width, Renderer.config.height
    gpu.setActiveBuffer(secondaryBuffer)
    Renderer.clear(C.bg)
    Renderer.updateAnimation()

    drawHeader(W)
    drawTabs(4, W)

    if     config.activeTab == 1 then drawEnergyTab(W, H)
    elseif config.activeTab == 2 then drawCpuTab(W, H)
    elseif config.activeTab == 3 then drawStorageTab(W, H)
    end

    -- Кнопки в подвале (по центру, на месте бывшей подсказки)
    local footerY = H - 2
    buttons.footer = {}

    local btnDefs = {
        { "ВЫХОД",      "exit",     C.alarmRed   },
        { "ФОРМАТ",     "format",   C.warnYellow },
        { "ЗВУК " .. (config.soundEnabled and "ON" or "OFF"),
                        "sound",    config.soundEnabled and C.posGreen or C.textMid },
        { "СБРОС МАКС", "resetmax", C.accent     },
    }

    -- Считаем общую ширину чтобы центрировать
    local sep    = 3
    local totalW = 0
    for i, d in ipairs(btnDefs) do
        totalW = totalW + unicode.len("[ " .. d[1] .. " ]")
        if i < #btnDefs then totalW = totalW + sep end
    end

    local fx = math.floor((W - totalW) / 2) + 1
    for _, d in ipairs(btnDefs) do
        local b = Renderer.drawButton(fx, footerY, d[1], d[3])
        b.action = d[2]
        table.insert(buttons.footer, b)
        fx = fx + b.w + sep
    end

    -- Анимированная подпись автора, встроенная в нижнюю рамку справа.
    -- Пробелы вокруг текста "разрезают" символы рамки ═, чтобы подпись
    -- читалась чисто, без слипания с рамкой.
    local sigText = " by ShadowStormOne "
    local sigW    = unicode.len(sigText)
    if W > sigW + 6 then
        local sigX = W - sigW - 3
        Renderer.drawAnimatedSignature(sigX, H, sigText)
    end

    gpu.setActiveBuffer(mainBuffer)
    gpu.bitblt(mainBuffer, 1, 1, W, H, secondaryBuffer, 1, 1)
end

-- ---------- Действия ----------
local function handleAction(action)
    if action == "exit" then
        cleanupAndExit()
    elseif action == "format" then
        config.useCompactFormat = not config.useCompactFormat
    elseif action == "sound" then
        config.soundEnabled = not config.soundEnabled
        if config.soundEnabled then tryBeep(660, 0.05) end
    elseif action == "resetmax" then
        if state.energyInfo and state.energyInfo.totalEnergy then
            config.maxTotalEnergy = math.max(state.energyInfo.totalEnergy, 1)
        end
    end
    saveConfig()
end

-- ---------- Запуск ----------
Renderer.init(config.scale)
setupBuffers()

local intervals = {
    data   = 1.0,    -- опрос API
    redraw = 0.25,   -- перерисовка экрана (плавная анимация)
}
local lastDataPoll, lastRedraw = 0, 0
local running = true

pollData()  -- первый опрос сразу

while running do
    local now = computer.uptime()

    if now - lastDataPoll >= intervals.data then
        pollData()
        lastDataPoll = now
    end
    if now - lastRedraw >= intervals.redraw then
        local ok, err = pcall(drawScreen)
        if not ok then
            state.apiOk    = false
            state.apiError = "render: " .. tostring(err)
        end
        lastRedraw = now
    end

    -- Короткий таймаут — позволяет реагировать на ввод и анимировать спиннер
    local ev = { event.pull(0.05) }
    local eType = ev[1]

    if eType == "touch" then
        local tx, ty = ev[3], ev[4]
        local handled = false
        for _, b in ipairs(buttons.tabs) do
            if Renderer.hitTest(b, tx, ty) then
                config.activeTab = b.tab; saveConfig(); handled = true; break
            end
        end
        if not handled then
            for _, b in ipairs(buttons.footer) do
                if Renderer.hitTest(b, tx, ty) then
                    handleAction(b.action); break
                end
            end
        end

    elseif eType == "interrupted" then
        -- Системный сигнал прерывания (Ctrl+Alt+C из консоли) — failsafe выход
        cleanupAndExit()
    end
end