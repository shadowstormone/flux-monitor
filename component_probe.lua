-- ============================================================================
-- component_probe.lua — универсальный сканер OC-компонентов
-- ----------------------------------------------------------------------------
-- ЗАЩИТА ОТ ЭНЕРГОЖОРА (актуально для больших сетей вроде HiTech):
--   • Чёрный список заведомо тяжёлых методов (getItemsInNetwork, getCraftables
--     и т.п.) — пропускаются по умолчанию, можно включить через --full.
--   • Лимит размера ответа: если метод вернул таблицу >50 элементов — только
--     количество, без полного дампа.
--   • Паузы между вызовами методов и между компонентами — даёт конденсаторам
--     перезарядиться от подключённой Power Supply / Capacitor.
--   • Контроль энергии: если перед компонентом осталось <25% — ждём
--     перезарядки до 80% или (если не подключено питание) останавливаемся
--     с сохранением частичного результата.
--   • Инкрементальный flush в лог после каждого компонента — даже если
--     компьютер всё-таки упадёт, в /home/component_probe.log останется всё
--     до точки падения.
--
-- Запуск:
--   component_probe                  — безопасный режим (пропуск тяжёлых)
--   component_probe <фильтр>         — только компоненты с подстрокой в имени
--   component_probe --quick          — ТОЛЬКО сводка, без вызовов методов
--   component_probe --no-methods     — методы перечислить, но не вызывать
--   component_probe --full           — ВКЛЮЧАЯ тяжёлые методы (рискованно!)
--   component_probe --no-doc         — не запрашивать документацию (ускорение)
--   component_probe --max-size N     — лимит размера дампа таблиц (по умолч. 50)
-- ============================================================================

local component = require("component")
local computer  = require("computer")
local fs        = require("filesystem")
local shell     = require("shell")

-- ---------- Параметры запуска ----------
local args, opts = shell.parse(...)
local nameFilter = args[1]      -- nil = без фильтра
local QUICK      = opts.quick      or false
local NO_METHODS = opts["no-methods"] or false
local FULL       = opts.full       or false
local NO_DOC     = opts["no-doc"]  or false
local MAX_DUMP   = tonumber(opts["max-size"]) or 50
local LOG_PATH   = "/home/component_probe.log"

-- ---------- Чёрный список тяжёлых методов ----------
-- Эти методы возвращают огромные списки и стабильно укладывают компьютер
-- даже на HiTech-сборках с приличным запасом энергии. Включается через --full.
local HEAVY_METHODS = {
    -- AE2 — могут вернуть тысячи предметов / рецептов
    getItemsInNetwork  = true,
    getCraftables      = true,
    getCpus            = true,
    getFluidsInNetwork = true,
    -- Flux — список всех устройств сети
    getDevices         = true,
    getStorages        = true,
    getNetworkDevices  = true,
    getNetworkStorages = true,
    getPlugs           = true,
    getPoints          = true,
    getControllers     = true,
    -- Modular Machinery
    getRecipes         = true,
    getActiveRecipe    = true,
    getInputBuses      = true,
    getOutputBuses     = true,
    -- Forestry / пчёлы — длинные генетические таблицы
    getIndividualOnDisplay = true,
    getQueen           = true,
    -- Большие инвентари
    getAllStacks       = true,
    getStackInSlot     = true,
}

-- ---------- Логгер с инкрементальным flush ----------
local logFile = io.open(LOG_PATH, "w")
local function log(s)
    s = s or ""
    print(s)
    if logFile then
        logFile:write(s .. "\n")
        logFile:flush()  -- критично: при kernel panic данные останутся на диске
    end
end

-- ---------- Энергетика ----------
local function energyPct()
    local maxE = computer.maxEnergy()
    if maxE == 0 then return 100 end
    return (computer.energy() / maxE) * 100
end

-- Ждём пока энергия не вырастет до targetPct (или maxWait секунд)
local function waitForEnergy(targetPct, maxWait)
    targetPct = targetPct or 80
    maxWait = maxWait or 30
    local startE = energyPct()
    if startE >= targetPct then return true end

    log(string.format("[ЭНЕРГИЯ] %.0f%% — жду перезарядки до %d%%...",
        startE, targetPct))

    local deadline = computer.uptime() + maxWait
    local lastE = startE
    local stagnantSince = computer.uptime()
    while computer.uptime() < deadline do
        os.sleep(1)
        local cur = energyPct()
        if cur >= targetPct then
            log(string.format("[ЭНЕРГИЯ] OK %.0f%%, продолжаю", cur))
            return true
        end
        -- Если энергия не растёт более 5 секунд — нет питания
        if cur > lastE + 0.5 then
            stagnantSince = computer.uptime()
            lastE = cur
        elseif computer.uptime() - stagnantSince > 5 then
            log(string.format("[ЭНЕРГИЯ] не растёт (%.0f%%), питание не подключено?",
                cur))
            return false
        end
    end
    return false
end

-- ---------- Безопасный дамп с лимитами ----------
local function dump(v, indent, depth, seen)
    indent = indent or ""
    depth  = depth  or 0
    seen   = seen   or {}

    if depth > 4 then return "<...max-depth...>" end

    local t = type(v)
    if t == "nil"      then return "nil"
    elseif t == "boolean" then return tostring(v)
    elseif t == "number"  then
        if v == math.floor(v) and math.abs(v) >= 10000 then
            return string.format("%d (≈%.2e)", math.floor(v), v)
        end
        return tostring(v)
    elseif t == "string"   then
        if #v > 200 then return string.format("%q...(+%d)", v:sub(1, 200), #v - 200) end
        return string.format("%q", v)
    elseif t == "function" then return "<function>"
    end
    if t ~= "table" then return "<" .. t .. ">" end

    if seen[v] then return "<circular>" end
    seen[v] = true

    -- Считаем размер таблицы (с ранним выходом)
    local count = 0
    for _ in pairs(v) do
        count = count + 1
        if count > MAX_DUMP then break end
    end

    if count == 0 then return "{}" end

    -- Большая таблица — только размер, без рекурсивного дампа
    if count > MAX_DUMP then
        local realCount = 0
        for _ in pairs(v) do realCount = realCount + 1 end
        return string.format("<table: %d элементов, дамп пропущен (--max-size N)>",
                             realCount)
    end

    local keys = {}
    for k in pairs(v) do table.insert(keys, k) end
    pcall(table.sort, keys, function(a, b) return tostring(a) < tostring(b) end)

    local lines = {"{"}
    for _, k in ipairs(keys) do
        local kStr = type(k) == "string" and k or ("[" .. tostring(k) .. "]")
        local val  = dump(v[k], indent .. "  ", depth + 1, seen)
        table.insert(lines, indent .. "  " .. kStr .. " = " .. val .. ",")
    end
    table.insert(lines, indent .. "}")
    return table.concat(lines, "\n")
end

-- ---------- Эвристика классификации (расширенная под HiTech) ----------
local KNOWN_COMPONENTS = {
    -- OC core
    ["computer"]           = "Управление самим ПК",
    ["gpu"]                = "Графический процессор",
    ["screen"]             = "Экран — источник touch/scroll",
    ["filesystem"]         = "Файловая система (HDD/диск)",
    ["eeprom"]             = "BIOS компьютера",
    ["modem"]              = "Сетевая карта",
    ["tunnel"]             = "Linked-card",
    ["redstone"]           = "I/O редстоуна",
    ["internet"]           = "Internet Card",
    ["data"]               = "Карта данных (хеш, шифр)",
    ["transposer"]         = "Транспозер",
    ["geolyzer"]           = "Геоанализатор",
    ["motion_sensor"]      = "Датчик движения",
    -- Flux
    ["flux_controller"]    = "Flux Network контроллер",
    ["flux_plug"]          = "Flux ввод",
    ["flux_point"]         = "Flux вывод",
    ["flux_storage"]       = "Flux накопитель",
    -- AE2
    ["me_controller"]      = "AE2 ME контроллер",
    ["me_interface"]       = "AE2 ME интерфейс",
    ["me_exportbus"]       = "AE2 экспорт",
    ["me_importbus"]       = "AE2 импорт",
    ["me_drive"]           = "AE2 привод",
    ["me_inscriber"]       = "AE2 пресс",
    -- Computronics
    ["chat_box"]           = "Computronics чат-бокс",
    ["tape_drive"]         = "Computronics ленточный носитель",
    ["colorful_lamp"]      = "Computronics RGB-лампа",
    ["industrial_chunkloader"] = "Computronics чанклоадер",
    ["radar"]              = "Computronics радар",
    ["self_destruct"]      = "Computronics само-разрушитель",
    -- Energy Control
    ["energy_sensor"]      = "Energy Control датчик",
    ["howler_alarm"]       = "Energy Control сирена",
    ["info_panel"]         = "Energy Control инфо-панель",
    ["info_panel_advanced"]= "Energy Control расш. панель",
    -- OpenSecurity
    ["os_alarm"]           = "OpenSecurity сирена",
    ["os_cardwriter"]      = "OpenSecurity программатор карт",
    ["os_doorcontroller"]  = "OpenSecurity контроллер двери",
    ["os_keypad"]          = "OpenSecurity клавиатура",
    ["os_magreader"]       = "OpenSecurity считыватель",
    ["entity_detector"]    = "OpenSecurity детектор сущностей",
    -- Прочие моды HiTech
    ["modular_machinery"]  = "Modular Machinery контроллер",
    ["mm_controller"]      = "Modular Machinery контроллер",
    ["machine_controller"] = "Контроллер машины",
    ["draconic_rfstorage"] = "Draconic Evolution энергоядро",
    ["draconic_reactor"]   = "Draconic реактор (ОПАСНО без управления!)",
    ["mfsu"]               = "IC2 MFSU накопитель",
    ["mfe"]                = "IC2 MFE накопитель",
    ["energy_cell"]        = "Thermal Expansion energy cell",
    ["capacitor_bank"]     = "Ender IO банк конденсаторов",
    ["bee_housing"]        = "Forestry улей",
    ["industrial_apiary"]  = "Gendustry индустр. апиарий",
}

local NAME_HINTS = {
    {"energy",     "Энергия"},        {"battery",   "Накопитель энергии"},
    {"capacitor",  "Конденсатор"},    {"fluid",     "Жидкости"},
    {"tank",       "Бак"},            {"reactor",   "Реактор"},
    {"turbine",    "Турбина"},        {"generator", "Генератор"},
    {"machine",    "Машина"},         {"controller","Контроллер"},
    {"modular",    "Modular Machinery"}, {"ae2",     "AE2"},
    {"draconic",   "Draconic"},       {"thermal",   "Thermal"},
    {"ic2",        "IC2"},            {"enderio",   "Ender IO"},
    {"computronic","Computronics"},   {"sensor",    "Датчик"},
    {"alarm",      "Сирена"},         {"keypad",    "Клавиатура"},
    {"bee",        "Пчёлы"},          {"apiary",    "Апиарий"},
    {"miner",      "Шахтёр"},         {"holo",      "Голограмма"},
}

local function classify(name, methods)
    local descriptions = {}
    if KNOWN_COMPONENTS[name] then
        table.insert(descriptions, KNOWN_COMPONENTS[name])
    end
    local lname = name:lower()
    for _, hint in ipairs(NAME_HINTS) do
        if lname:find(hint[1], 1, true) then
            local dup = false
            for _, e in ipairs(descriptions) do
                if e == hint[2] then dup = true; break end
            end
            if not dup then table.insert(descriptions, hint[2]) end
        end
    end
    if #descriptions == 0 then
        return "Кастомный/неизвестный (см. список методов)"
    end
    return table.concat(descriptions, "; ")
end

-- ---------- Сбор информации по одному компоненту ----------
local function probeComponent(addr, name)
    log("================================================================")
    log(" КОМПОНЕНТ: " .. name)
    log("================================================================")
    log("Адрес:       " .. addr)
    log(string.format("Энергия ПК:  %.0f%%", energyPct()))

    local okMethods, methods = pcall(component.methods, addr)
    if not okMethods or type(methods) ~= "table" then
        log("✗ Не удалось получить список методов: " .. tostring(methods))
        log("")
        return
    end

    log("Назначение:  " .. classify(name, methods))
    log("")

    -- Список методов
    local methodList = {}
    for mn, direct in pairs(methods) do
        table.insert(methodList, { name = mn, direct = direct })
    end
    table.sort(methodList, function(a, b) return a.name < b.name end)

    log("--- Методы (" .. #methodList .. ") ---")
    for _, m in ipairs(methodList) do
        local doc = ""
        if not NO_DOC then
            pcall(function() doc = component.doc(addr, m.name) or "" end)
            if #doc > 120 then doc = doc:sub(1, 117) .. "..." end
        end
        local heavy = HEAVY_METHODS[m.name] and " ⚠HEAVY" or ""
        log(string.format("  • %-32s %s%s%s",
            m.name,
            m.direct and "[sync] " or "[async]",
            heavy,
            doc ~= "" and (" → " .. doc) or ""))
        os.sleep(0)  -- даём планировщику передышку
    end
    log("")

    if NO_METHODS or QUICK then
        log("(Прогон методов пропущен по флагу --no-methods/--quick)")
        log("")
        return
    end

    -- Получаем proxy
    local okProxy, proxy = pcall(component.proxy, addr)
    if not okProxy or not proxy then
        log("✗ Не удалось получить proxy: " .. tostring(proxy))
        log("")
        return
    end

    -- Прогон get/list/is методов
    log("--- Прогон getter-методов ---")
    local skipped = 0
    for _, m in ipairs(methodList) do
        if m.name:match("^get") or m.name:match("^list") or m.name:match("^is") then

            -- Защита от тяжёлых методов
            if HEAVY_METHODS[m.name] and not FULL then
                log(">>> " .. m.name .. "()  ⚠ ПРОПУЩЕН (--full чтобы включить)")
                skipped = skipped + 1
            else
                -- Проверка энергии перед каждым вызовом
                if energyPct() < 25 then
                    log(string.format(
                        "[ЭНЕРГИЯ %.0f%%] прерываюсь — недостаточно для безопасного продолжения.",
                        energyPct()))
                    log("Подключите Capacitor / Power Supply и запустите снова.")
                    log("Промежуточный лог сохранён в " .. LOG_PATH)
                    return "energy"
                end

                log(">>> " .. m.name .. "()")
                local ok, result = pcall(proxy[m.name])
                if ok then
                    log(dump(result, "  "))
                else
                    local errStr = tostring(result)
                    if errStr:match("argument") or errStr:match("expected")
                       or errStr:match("missing") then
                        log("  ARG_REQUIRED: " .. errStr)
                    else
                        log("  ✗ ERROR: " .. errStr)
                    end
                end
                log("")
                os.sleep(0.05)  -- пауза для перезарядки
            end
        end
    end
    if skipped > 0 then
        log(string.format("(Пропущено тяжёлых методов: %d. Запустить с --full на свой риск.)",
            skipped))
        log("")
    end
end

-- ============================================================================
-- ГЛАВНЫЙ ЦИКЛ
-- ============================================================================
log("################################################################")
log("# UNIVERSAL COMPONENT PROBE")
log("# Дата: " .. os.date())
log("# Энергия ПК на старте: " .. string.format("%.0f%%", energyPct()))
log("# Режим: " .. (QUICK and "QUICK (только сводка)"
                or NO_METHODS and "NO-METHODS (без прогона)"
                or FULL and "FULL (включая тяжёлые методы)"
                or "БЕЗОПАСНЫЙ (тяжёлые методы пропущены)"))
if nameFilter then log("# Фильтр: '" .. nameFilter .. "'") end
log("################################################################")
log("")

-- Собираем компоненты с фильтром
local components = {}
for addr, name in component.list() do
    if not nameFilter or name:lower():find(nameFilter:lower(), 1, true) then
        table.insert(components, { addr = addr, name = name })
    end
end
table.sort(components, function(a, b)
    if a.name == b.name then return a.addr < b.addr end
    return a.name < b.name
end)

log("Найдено компонентов: " .. #components)
if nameFilter and #components == 0 then
    log("Под фильтр '" .. nameFilter .. "' не подошёл ни один компонент.")
    if logFile then logFile:close() end
    return
end

-- Краткая сводка имён
log("")
log("=== СВОДКА ===")
local nameCounts = {}
for _, c in ipairs(components) do
    nameCounts[c.name] = (nameCounts[c.name] or 0) + 1
end
local sortedNames = {}
for n in pairs(nameCounts) do table.insert(sortedNames, n) end
table.sort(sortedNames)
for _, n in ipairs(sortedNames) do
    local desc = KNOWN_COMPONENTS[n]
    log(string.format("  %-32s × %d   %s",
        n, nameCounts[n], desc and ("— " .. desc) or ""))
end
log("")

if QUICK then
    log("(--quick: пропускаю подробное сканирование. Запустите без флага для полного отчёта.)")
    if logFile then logFile:close() end
    print()
    print("Сводка сохранена в " .. LOG_PATH)
    return
end

-- Подробный probe каждого компонента
log("=== ПОДРОБНО ===")
log("")

local stopped = false
for i, c in ipairs(components) do
    -- Перед каждым компонентом — проверка энергии
    if energyPct() < 25 and i > 1 then
        if not waitForEnergy(80, 30) then
            log("")
            log("[!] Сканирование прервано из-за нехватки энергии после " ..
                (i - 1) .. " из " .. #components .. " компонентов.")
            log("    Подключите более ёмкое питание или запустите снова с фильтром:")
            log("    component_probe " .. c.name)
            stopped = true
            break
        end
    end

    log(string.format("[%d/%d]", i, #components))
    local ok, result = pcall(probeComponent, c.addr, c.name)
    if not ok then
        log("✗ probeComponent упал на " .. c.name .. ": " .. tostring(result))
        log("")
    elseif result == "energy" then
        stopped = true
        break
    end

    -- Пауза между компонентами для подзарядки
    os.sleep(0.1)
end

log("################################################################")
log("# ГОТОВО" .. (stopped and " (частично — прервано по энергии)" or ""))
log("# Энергия ПК на финише: " .. string.format("%.0f%%", energyPct()))
log("################################################################")
log("Полный отчёт: " .. LOG_PATH)
log("")
log("Что дальше:")
log("  • viewer " .. LOG_PATH .. "  — открыть в просмотрщике")
log("  • component_probe <фильтр>  — изучить конкретную группу")
log("  • component_probe --full    — прогнать ВСЕ методы (на свой риск)")

if logFile then logFile:close() end

print()
print("Совет: открой лог в просмотрщике для удобной навигации:")
print("  viewer " .. LOG_PATH)
