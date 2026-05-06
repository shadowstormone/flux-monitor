-- ============================================================================
-- component_probe.lua — универсальный сканер всех OC-компонентов
-- ----------------------------------------------------------------------------
-- Что делает: то же что flux_probe для одного контроллера, но по ВСЕЙ
-- компонентной сети компьютера. Полезно когда:
--   • На сервере стоят моды с непонятными именами компонентов (Modular
--     Machinery, прокаченные AE2, кастомные мультиблоки) и нужно понять
--     что вообще доступно.
--   • Хочется получить готовый список адресов и методов для последующего
--     написания специализированных скриптов.
--   • Нужно проверить, какой компонент за что отвечает — без чтения
--     исходников мода.
--
-- Алгоритм:
--   1) Перечисляет все компоненты через component.list().
--   2) Для каждого: получает все методы через component.methods(), читает
--      документацию через component.doc(), безопасно вызывает все getter/
--      list/is методы без аргументов через pcall.
--   3) Эвристически классифицирует компонент по имени и сигнатуре методов
--      (энергия, хранилище, крафт, мультиблок, IO и т.д.).
--   4) Сохраняет полный отчёт в /home/component_probe.log с подсветкой
--      под viewer.lua (===, ✓, ✗, >>>).
--
-- Запуск:
--   component_probe              # сканировать всё
--   component_probe <фильтр>     # только компоненты, содержащие <фильтр>
--                                # в имени (например "machinery", "ae2")
-- ============================================================================

local component = require("component")
local fs        = require("filesystem")
local shell     = require("shell")

-- ---------- Параметры запуска ----------
local args     = shell.parse(...)
local nameFilter = args[1]     -- nil = без фильтра
local LOG_PATH = "/home/component_probe.log"

local logFile = io.open(LOG_PATH, "w")
local function log(s)
    s = s or ""
    print(s)
    if logFile then logFile:write(s .. "\n"); logFile:flush() end
end

-- ============================================================================
-- ЭВРИСТИКА: классификация компонента по имени и набору методов
-- ============================================================================
-- Назначение: дать пользователю человекочитаемое описание ЧТО это, без
-- необходимости читать вики мода. Эвристика двухуровневая:
--   1) Точные совпадения имён хорошо известных компонентов (flux, me_*,
--      tank_controller и т.п.) — выдают точное описание.
--   2) Общие правила по словам в имени и по наличию характерных методов
--      (например getEnergyStored → накопитель энергии).

-- Уровень 1: точные имена и их назначение
local KNOWN_COMPONENTS = {
    -- OC core
    ["computer"]          = "Управление самим ПК (выкл, ребут, статус)",
    ["gpu"]               = "Графический процессор: вывод на экран",
    ["screen"]            = "Экран. Источник событий touch/scroll",
    ["filesystem"]        = "Файловая система (ЖД, дискета, tmpfs)",
    ["eeprom"]            = "BIOS компьютера",
    ["modem"]             = "Сетевая карта (беспроводная связь между ПК)",
    ["tunnel"]            = "Linked-card: точечная связь между двумя ПК",
    ["redstone"]          = "I/O редстоуна",
    ["internet"]          = "Internet Card: HTTP/HTTPS и raw TCP",
    ["data"]              = "Карта данных: хеширование, шифрование, base64",
    ["transposer"]        = "Транспозер: перемещение предметов и жидкостей",
    ["robot"]             = "API робота",
    ["drone"]             = "API дрона",
    ["geolyzer"]           = "Геоанализатор: сканирование блоков вокруг",
    ["motion_sensor"]      = "Датчик движения мобов/игроков рядом",
    ["debug"]              = "Debug Card (только в креативе): мощные методы",

    -- Flux Networks
    ["flux_controller"]   = "Контроллер Flux Network: статистика и сеть",
    ["flux_plug"]         = "Точка ввода энергии в Flux-сеть",
    ["flux_point"]        = "Точка вывода энергии из Flux-сети",
    ["flux_storage"]      = "Накопитель энергии Flux Network",

    -- AE2 + аддоны (на HiTech: Applied Energistics 2, AE2 Stuff, Lazy AE2)
    ["me_controller"]     = "AE2 Контроллер ME: процессоры крафта, предметы",
    ["me_interface"]      = "AE2 ME интерфейс: автоматизация I/O сети",
    ["me_exportbus"]      = "AE2 экспортная шина",
    ["me_importbus"]      = "AE2 импортная шина",
    ["me_drive"]          = "AE2 привод накопителей",
    ["me_iobus"]          = "AE2 универсальная шина I/O",
    ["me_inscriber"]      = "AE2 пресс/инскрайбер (AE2 Stuff)",

    -- Computronics (точно на HiTech)
    ["chat_box"]              = "Computronics: чат-бокс для приёма/отправки сообщений",
    ["tape_drive"]            = "Computronics: ленточный накопитель (звук/данные)",
    ["colorful_lamp"]         = "Computronics: программируемая RGB-лампа",
    ["industrial_chunkloader"]= "Computronics: чанклоадер с управлением",
    ["radar"]                 = "Computronics: радар обнаружения сущностей",
    ["self_destruct"]         = "Computronics: блок самоуничтожения",
    ["digital_railroad"]      = "Computronics: контроллер железной дороги",
    ["cipher"]                = "Computronics: шифрование данных",

    -- Energy Control (точно на HiTech)
    ["energy_sensor"]         = "Energy Control: датчик уровня энергии в IC2/RF/EU",
    ["howler_alarm"]          = "Energy Control: сирена-оповещатель",
    ["info_panel"]            = "Energy Control: информационная панель (вывод текста в мире)",
    ["info_panel_advanced"]   = "Energy Control: расширенная инфо-панель",
    ["thermometer"]           = "Energy Control: термометр для реакторов",
    ["range_trigger"]         = "Energy Control: триггер по диапазону значений",
    ["counter"]               = "Energy Control: счётчик (предметов/энергии)",

    -- OpenSecurity (точно на HiTech)
    ["os_alarm"]              = "OpenSecurity: сирена тревоги",
    ["os_cardwriter"]         = "OpenSecurity: программатор карт доступа",
    ["os_doorcontroller"]     = "OpenSecurity: контроллер дверей",
    ["os_energyturret"]       = "OpenSecurity: энергетическая турель",
    ["os_keypad"]             = "OpenSecurity: цифровая клавиатура",
    ["os_magreader"]          = "OpenSecurity: считыватель магнитных карт",
    ["os_securitydoor"]       = "OpenSecurity: защищённая дверь",
    ["os_rfidreader"]         = "OpenSecurity: RFID-сканер",
    ["entity_detector"]       = "OpenSecurity: детектор сущностей в радиусе",
    ["biometric_reader"]      = "OpenSecurity: биометрический сканер",

    -- OpenGlasses2 / OpenScreens (точно на HiTech)
    ["glasses"]               = "OpenGlasses: связь с очками-HUD игрока",
    ["glasses_terminal"]      = "OpenGlasses: терминал-передатчик HUD",
    ["openscreens_screen"]    = "OpenScreens: расширенный экран",
    ["openglasses_host"]      = "OpenGlasses: хост-блок для трансляции в очки",

    -- OpenExtensions (кастомный мост OC ↔ другие моды на HiTech)
    ["oc_eio"]                = "OpenExtensions: интеграция с Ender IO",
    ["oc_botania"]            = "OpenExtensions: интеграция с Botania",
    ["oc_forestry"]           = "OpenExtensions: интеграция с Forestry (пчёлы и пр.)",

    -- Modular Machinery / Modular Assembly (точно на HiTech)
    ["modular_machinery"]     = "Modular Machinery: контроллер кастомного мультиблока",
    ["modular_assembly"]      = "Modular Assembly: кастомная сборочная машина",
    ["mm_controller"]         = "Modular Machinery контроллер",
    ["machine_controller"]    = "Контроллер машины (общий тип)",

    -- Ender IO (точно на HiTech)
    ["enderio:capacitor_bank"]= "Ender IO: банк конденсаторов (хранилище RF)",
    ["capacitor_bank"]        = "Ender IO: банк конденсаторов",

    -- Draconic Evolution (точно на HiTech)
    ["draconic_rfstorage"]    = "Draconic Evolution: энергоядро (огромное RF-хранилище)",
    ["draconic_reactor"]      = "Draconic Evolution: реактор (требует точного управления!)",

    -- IndustrialCraft 2 (точно на HiTech)
    ["energy_machine"]        = "IC2/GT: машина с энергобуфером",
    ["transformer"]           = "Трансформатор напряжения",
    ["batbox"]                = "Накопитель энергии IC2",
    ["nuclear_reactor"]       = "Ядерный реактор IC2",
    ["mfsu"]                  = "MFSU: накопитель IC2 высокого напряжения",
    ["mfe"]                   = "MFE: средний накопитель IC2",
    ["industrial_centrifuge"] = "IC2: промышленная центрифуга",

    -- Thermal Expansion (точно на HiTech)
    ["energy_cell"]           = "Thermal Expansion: ячейка энергии (RF)",
    ["thermal_machine"]       = "Thermal Expansion машина",

    -- Forestry / Gendustry / Binnie (точно на HiTech)
    ["bee_housing"]           = "Forestry: пчелиный домик/улей/альвеарий",
    ["apiary"]                = "Forestry: апиарий (улей)",
    ["analyzer"]              = "Forestry/Binnie: анализатор пчёл/деревьев",
    ["industrial_apiary"]     = "Gendustry: индустриальный апиарий",
    ["mutatron"]              = "Gendustry: мутатрон для скрещивания пчёл",
    ["genetic_imprinter"]     = "Gendustry: генетический импринтер",

    -- Tank/жидкости (общее, может быть от Forestry/TE/IC2)
    ["tank_controller"]       = "Контроллер бака с жидкостью",

    -- McSkill кастомные моды (точные имена выяснишь probe-ом)
    ["mcskill_apex"]          = "McSkill Apex: квантовая кирка/голограмма/базука",
    ["mcskill_genesis"]       = "McSkill Genesis: паспорт/PvP-статус/табло",
    ["holo_projector"]        = "McSkill Apex: голографический проектор",
    ["chunk_loader_apex"]     = "McSkill Apex: продвинутый якорь чанков",
}

-- Уровень 2: правила по подстрокам в имени
local NAME_HINTS = {
    -- Общая энергетика
    { "energy",     "Работает с энергией"                },
    { "battery",    "Накопитель энергии"                 },
    { "rf_",        "Источник/потребитель RF"            },
    { "_rf",        "Источник/потребитель RF"            },
    { "_fe",        "Forge Energy устройство"            },
    { "capacitor",  "Накопитель/конденсатор энергии"     },
    -- Жидкости
    { "fluid",      "Работа с жидкостями"                },
    { "tank",       "Резервуар жидкости"                 },
    { "boiler",     "Парогенератор"                      },
    -- Транспорт
    { "fluxduct",   "Канал передачи энергии"             },
    { "pipe",       "Труба для предметов/жидкостей"      },
    { "duct",       "Канал/проводник (Thermal/прочие)"   },
    -- Инвентари
    { "inventory",  "Имеет инвентарь предметов"          },
    { "chest",      "Сундук/инвентарь"                   },
    { "barrel",     "Бочка/хранилище предметов"          },
    { "transposer", "Перемещение предметов/жидкостей"    },
    -- Машины
    { "crafter",    "Автоматический крафт"               },
    { "furnace",    "Печь/нагреватель"                   },
    { "smelter",    "Плавильня"                          },
    { "reactor",    "Реактор"                            },
    { "turbine",    "Турбина"                            },
    { "generator",  "Генератор энергии"                  },
    { "machine",    "Машина (устройство с автоматикой)"  },
    { "controller", "Контроллер мультиблока/системы"     },
    { "modular",    "Modular Machinery / модульная сборка"},
    -- Конкретные моды HiTech
    { "ae2",        "Applied Energistics 2 устройство"   },
    { "_me_",       "AE2 ME-устройство"                  },
    { "matrix",     "Накопитель энергоматрицы"           },
    { "draconic",   "Draconic Evolution устройство"      },
    { "thermal",    "Thermal Series устройство"          },
    { "mekanism",   "Mekanism устройство"                },
    { "ic2",        "IndustrialCraft 2 устройство"       },
    { "gregtech",   "GregTech устройство"                },
    { "extreme",    "Extreme/Extended Reactors устройство"},
    { "enderio",    "Ender IO устройство"                },
    { "ender_io",   "Ender IO устройство"                },
    -- Computronics
    { "computronic", "Computronics устройство"           },
    { "tape",       "Computronics ленточный носитель"    },
    -- Energy Control
    { "info_panel", "Energy Control инфо-панель"         },
    { "sensor",     "Датчик/сенсор"                      },
    { "alarm",      "Сирена/тревога"                     },
    -- OpenSecurity
    { "card",       "Карта доступа / считыватель"        },
    { "rfid",       "RFID устройство"                    },
    { "biometric",  "Биометрический сканер"              },
    { "keypad",     "Клавиатура для ввода пинкода"       },
    { "turret",     "Турель/стрелковая установка"        },
    -- OpenGlasses
    { "glasses",    "OpenGlasses связь с HUD-очками"     },
    -- Forestry
    { "bee",        "Forestry пчёлы"                     },
    { "apiary",     "Forestry/Gendustry апиарий (улей)"  },
    { "tree",       "Дерево/древесина (Forestry)"        },
    { "genetic",    "Gendustry генетика"                 },
    -- McSkill кастомные
    { "apex",       "McSkill Apex"                       },
    { "genesis",    "McSkill Genesis"                    },
    { "mcskill",    "Кастомный мод McSkill"              },
    { "holo",       "Голографический блок"               },
    -- Generic
    { "miner",      "Шахтёр/майнер (рудокоп)"            },
    { "drilling",   "Бур/буровая установка"              },
    { "spawner",    "Спавнер мобов"                      },
    { "auto",       "Автоматизированное устройство"      },
}

-- Уровень 3: правила по сигнатуре методов (если есть характерный метод)
local METHOD_HINTS = {
    { "getEnergyStored",      "Хранит энергию (RF/FE/EU)"           },
    { "getMaxEnergyStored",   "Имеет ёмкость энергобуфера"          },
    { "getEnergyInfo",        "Отдаёт расширенную статистику энергии"},
    { "getCpus",              "Управляет crafting-процессорами"     },
    { "getItemsInNetwork",    "Хранит предметы в сети"              },
    { "getCraftables",        "Может крафтить предметы по запросу"  },
    { "getFluidInTank",       "Содержит жидкости"                   },
    { "getTankInfo",          "Имеет резервуар"                     },
    { "getStackInSlot",       "Имеет инвентарь предметов"           },
    { "isMachineActive",      "Машина с состоянием активности"      },
    { "getRecipeProgress",    "Машина с прогрессом крафта"          },
    { "getMachineStatus",     "Машина с диагностикой"               },
    { "isWorking",            "Машина с режимом работы"             },
    { "getWork",              "Отдаёт информацию о текущей работе"  },
    { "getOutput", "Имеет выход продукции (предмет/жидкость/энергия)"},
    { "transferItem",         "Может перемещать предметы"           },
    { "getStorages",          "Имеет список подключённых хранилищ"  },
}

local function classify(name, methods)
    local descriptions = {}

    -- Уровень 1: точное имя
    if KNOWN_COMPONENTS[name] then
        table.insert(descriptions, KNOWN_COMPONENTS[name])
    end

    -- Уровень 2: подстроки в имени (нижний регистр)
    local lname = name:lower()
    for _, hint in ipairs(NAME_HINTS) do
        if lname:find(hint[1], 1, true) then
            -- Не дублируем если такая же подсказка уже была
            local dup = false
            for _, existing in ipairs(descriptions) do
                if existing == hint[2] then dup = true; break end
            end
            if not dup then table.insert(descriptions, hint[2]) end
        end
    end

    -- Уровень 3: характерные методы
    if methods then
        for _, hint in ipairs(METHOD_HINTS) do
            if methods[hint[1]] then
                table.insert(descriptions, hint[2])
            end
        end
    end

    if #descriptions == 0 then
        return "Неизвестный/кастомный компонент — см. список методов ниже"
    end
    return table.concat(descriptions, "; ")
end

-- ============================================================================
-- БЕЗОПАСНЫЙ ДАМП ЗНАЧЕНИЙ
-- ============================================================================
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

    if next(v) == nil then return "{}" end

    local keys = {}
    for k in pairs(v) do table.insert(keys, k) end
    pcall(table.sort, keys, function(a, b) return tostring(a) < tostring(b) end)

    local lines = {"{"}
    local maxItems = 30
    for i, k in ipairs(keys) do
        if i > maxItems then
            table.insert(lines, indent .. "  ... ещё " .. (#keys - maxItems) .. " элементов")
            break
        end
        local kStr = type(k) == "string" and k or ("[" .. tostring(k) .. "]")
        local val  = dump(v[k], indent .. "  ", depth + 1, seen)
        table.insert(lines, indent .. "  " .. kStr .. " = " .. val .. ",")
    end
    table.insert(lines, indent .. "}")
    return table.concat(lines, "\n")
end

-- ============================================================================
-- СБОР ИНФОРМАЦИИ ПО ОДНОМУ КОМПОНЕНТУ
-- ============================================================================
local function probeComponent(addr, name)
    log("================================================================")
    log(" КОМПОНЕНТ: " .. name)
    log("================================================================")
    log("Адрес:     " .. addr)

    -- Получаем все методы и их флаги direct/async
    local okMethods, methods = pcall(component.methods, addr)
    if not okMethods or type(methods) ~= "table" then
        log("✗ Не удалось получить список методов: " .. tostring(methods))
        log("")
        return
    end

    -- Классификация
    log("Назначение: " .. classify(name, methods))
    log("")

    -- Получаем proxy для вызова методов
    local okProxy, proxy = pcall(component.proxy, addr)
    if not okProxy or not proxy then
        log("✗ Не удалось получить proxy: " .. tostring(proxy))
        log("")
        return
    end

    -- Список методов
    local methodList = {}
    for mn, direct in pairs(methods) do
        table.insert(methodList, { name = mn, direct = direct })
    end
    table.sort(methodList, function(a, b) return a.name < b.name end)

    log("--- Методы (" .. #methodList .. ") ---")
    for _, m in ipairs(methodList) do
        local doc = ""
        pcall(function() doc = component.doc(addr, m.name) or "" end)
        -- Сокращаем слишком длинные документации
        if #doc > 150 then doc = doc:sub(1, 147) .. "..." end
        log(string.format("  • %-32s %s%s",
            m.name,
            m.direct and "[sync] " or "[async]",
            doc ~= "" and ("→ " .. doc) or ""))
    end
    log("")

    -- Прогон get/list/is методов
    local probedAny = false
    for _, m in ipairs(methodList) do
        if m.name:match("^get") or m.name:match("^list") or m.name:match("^is") then
            probedAny = true
            log(">>> " .. m.name .. "()")
            local ok, result = pcall(proxy[m.name])
            if ok then
                log(dump(result, "  "))
            else
                local errStr = tostring(result)
                if errStr:match("argument") or errStr:match("аргумент")
                   or errStr:match("expected") or errStr:match("missing") then
                    log("  ARG_REQUIRED: " .. errStr)
                else
                    log("  ✗ ERROR: " .. errStr)
                end
            end
            log("")
        end
    end

    if not probedAny then
        log("(Нет get/list/is методов для автоматического прогона.)")
        log("")
    end
end

-- ============================================================================
-- ГЛАВНЫЙ ЦИКЛ
-- ============================================================================
log("################################################################")
log("# UNIVERSAL COMPONENT PROBE")
log("# Дата: " .. os.date())
if nameFilter then
    log("# Фильтр: '" .. nameFilter .. "'")
end
log("################################################################")
log("")

-- Собираем список с фильтром
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
    log("")
    log("Ни один компонент не подошёл под фильтр '" .. nameFilter .. "'.")
    log("Запусти без аргументов чтобы увидеть полный список.")
    if logFile then logFile:close() end
    return
end

-- Сначала краткая сводка — какие имена и сколько
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
    log(string.format("  %-30s × %d   %s",
        n, nameCounts[n], desc and ("— " .. desc) or ""))
end
log("")

-- Теперь подробный probe каждого
log("=== ПОДРОБНО ===")
log("")

for _, c in ipairs(components) do
    local ok, err = pcall(probeComponent, c.addr, c.name)
    if not ok then
        log("✗ probeComponent упал на " .. c.name .. ": " .. tostring(err))
        log("")
    end
end

-- Финал
log("################################################################")
log("# ГОТОВО")
log("################################################################")
log("Полный отчёт сохранён: " .. LOG_PATH)
log("")
log("Что дальше:")
log("  • viewer " .. LOG_PATH .. "  — открыть в просмотрщике с прокруткой")
log("  • Найти интересный компонент в подробной части и его метод")
log("  • Дёрнуть конкретный метод вручную из шелла:")
log("      lua")
log("      > c = require('component')")
log("      > p = c.proxy('адрес_из_лога')")
log("      > =p.методКоторыйНужен()")

if logFile then logFile:close() end

print()
print("Совет: открой лог в просмотрщике для удобной навигации:")
print("  viewer " .. LOG_PATH)
