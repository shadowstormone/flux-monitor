-- ============================================================================
-- install.lua — установщик пакета из GitHub для OpenComputers
-- ----------------------------------------------------------------------------
-- Качает файлы из публичного GitHub-репозитория одной командой.
-- Требования: Internet Card Tier 2 (HTTPS).
--
-- Запуск ОДНОЙ командой прямо из шелла OC:
--   wget -f https://raw.githubusercontent.com/USER/REPO/main/install.lua /tmp/i.lua && /tmp/i.lua
-- ============================================================================

local component = require("component")
local fs        = require("filesystem")
local shell     = require("shell")

if not component.isAvailable("internet") then
    io.stderr:write("Internet Card не найдена. Нужна Tier 2 для HTTPS.\n")
    return
end
local internet = component.internet

-- ---------- ИЗМЕНИ ЭТУ СТРОКУ НА СВОЙ НИК НА GITHUB ----------
local USER   = "shadowstormone"
local REPO   = "flux-monitor"
local BRANCH = "main"

-- Список файлов: { "путь_в_репо", "путь_в_OC" }
-- Файлы в /lib/ доступны через require без расширения .lua
local FILES = {
    { "renderer.lua",        "/lib/renderer.lua"        },
    { "flux.lua",            "/home/flux.lua"           },
    { "viewer.lua",          "/home/viewer.lua"         },
    { "component_probe.lua", "/home/component_probe.lua"},
}
-- -------------------------------------------------------------

local BASE = "https://raw.githubusercontent.com/" .. USER .. "/" .. REPO .. "/" .. BRANCH .. "/"

-- ---------- Скачивание одного файла ----------
local function download(url)
    local handle, err = internet.request(url)
    if not handle then return nil, err end

    local chunks = {}
    while true do
        local chunk, e = handle.read()
        if not chunk then
            if e then return nil, e end
            break
        end
        chunks[#chunks + 1] = chunk
    end
    pcall(handle.close)

    local data = table.concat(chunks)
    -- GitHub raw на 404 возвращает текст "404: Not Found" со статусом 404.
    -- Грубая защита: если короткий ответ начинается на "404" — это ошибка.
    if #data < 100 and data:match("^404") then
        return nil, "404: файл не найден в репозитории"
    end
    return data
end

local function ensureDir(path)
    local dir = path:match("(.+)/[^/]+$")
    if dir and not fs.exists(dir) then
        local ok, err = fs.makeDirectory(dir)
        if not ok then return nil, err end
    end
    return true
end

local function writeFile(path, data)
    local ok, err = ensureDir(path)
    if not ok then return nil, err end
    local f, ferr = io.open(path, "w")
    if not f then return nil, ferr end
    f:write(data)
    f:close()
    return true
end

-- ---------- Главный цикл установки ----------
print("======================================")
print(" Установка пакета " .. USER .. "/" .. REPO)
print("======================================")
print("Будет загружено файлов: " .. #FILES)
print()

local args = shell.parse(...)
local force         = false
local autostartArg  = nil    -- nil = спросить, true/false = из флага
for _, a in ipairs(args) do
    if     a == "-f" or a == "--force"        then force = true
    elseif a == "--autostart"                 then autostartArg = true
    elseif a == "--no-autostart"              then autostartArg = false
    end
end

local ok, fail = 0, 0
for i, file in ipairs(FILES) do
    local src, dst = file[1], file[2]
    io.write(string.format("[%d/%d] %s → %s ... ", i, #FILES, src, dst))

    if fs.exists(dst) and not force then
        io.write("ПРОПУСК (уже существует, -f для перезаписи)\n")
    else
        local data, err = download(BASE .. src)
        if not data then
            io.write("ОШИБКА: " .. tostring(err) .. "\n")
            fail = fail + 1
        else
            local wok, werr = writeFile(dst, data)
            if wok then
                io.write(string.format("OK (%d байт)\n", #data))
                ok = ok + 1
            else
                io.write("ОШИБКА ЗАПИСИ: " .. tostring(werr) .. "\n")
                fail = fail + 1
            end
        end
    end
end

-- ============================================================================
-- НАСТРОЙКА АВТОЗАПУСКА ЧЕРЕЗ /etc/rc.d/
-- ============================================================================
-- В OpenOS есть встроенный сервис-менеджер rc, который запускает скрипты
-- из /etc/rc.d/ при загрузке системы. Чтобы скрипт стартовал автоматически:
--
--   1) Создать файл /etc/rc.d/<имя>.lua с обязательной функцией start()
--      (опционально stop() и status()).
--   2) Включить его командой rc.enable("имя") — это пишет имя в
--      /etc/rc.cfg, и при следующей загрузке rc-демон вызовет start().
--
-- Преимущества перед .shrc:
--   • Запуск ДО шелла — логин-приглашение не появится, экран сразу занят.
--   • Управление через rc start/stop/restart/enable/disable работает.
--   • Чёткое отделение программы-сервиса от пользовательского окружения.
--
-- Особенности:
--   • Внутри rc.d скриптов нельзя напрямую работать с term: они стартуют
--     до инициализации терминала. Поэтому start() запускает flux.lua в
--     отдельном процессе через process.load → coroutine, чтобы основной
--     rc-демон мог продолжить загрузку остальных сервисов.

local RC_DIR        = "/etc/rc.d"
local RC_NAME       = REPO:gsub("-", "_")        -- "flux-monitor" → "flux_monitor"
local RC_PATH       = RC_DIR .. "/" .. RC_NAME .. ".lua"
local TARGET_SCRIPT = "/home/flux.lua"

-- Содержимое rc-скрипта. Запускает /home/flux.lua в фоне через process.load.
local RC_SCRIPT = [[
-- Auto-generated by flux-monitor installer.
-- rc-скрипт автозапуска: вызывается rc-демоном OpenOS при загрузке.
-- Управление вручную: rc flux_monitor [start|stop|restart|status]

local thread = require("thread")

local TARGET = "]] .. TARGET_SCRIPT .. [["
local runner = nil   -- активный thread с запущенным мониторингом

local function isAlive()
    return runner ~= nil and runner:status() ~= "dead"
end

function start()
    if isAlive() then
        return false, "уже запущен"
    end
    -- thread.create отделяет процесс от rc-демона: даже если flux.lua
    -- вылетит с ошибкой, основная система продолжит работать.
    runner = thread.create(function()
        local ok, err = pcall(dofile, TARGET)
        if not ok then
            io.stderr:write("flux-monitor: " .. tostring(err) .. "\n")
        end
    end)
    return true
end

function stop()
    if isAlive() then
        runner:kill()
        runner = nil
        return true
    end
    return false, "не запущен"
end

function status()
    return isAlive() and "running" or "stopped"
end

function restart()
    stop()
    return start()
end
]]

local function rcEnabled()
    -- Считываем /etc/rc.cfg — там в массиве enabled или в формате
    -- enabled = {"foo", "bar"} перечислены активные сервисы.
    local cfgPath = "/etc/rc.cfg"
    if not fs.exists(cfgPath) then return false end
    local f = io.open(cfgPath, "r"); if not f then return false end
    local content = f:read("*a"); f:close()
    -- Достаточно простой проверки наличия имени сервиса в файле
    return content:find('"' .. RC_NAME .. '"', 1, true) ~= nil
       or  content:find("'" .. RC_NAME .. "'", 1, true) ~= nil
end

local function isAutostartEnabled()
    return fs.exists(RC_PATH) and rcEnabled()
end

local function enableAutostart()
    -- Записываем сам rc-скрипт
    if not fs.exists(RC_DIR) then
        local mkOk, mkErr = fs.makeDirectory(RC_DIR)
        if not mkOk then return false, "не удалось создать " .. RC_DIR .. ": " .. tostring(mkErr) end
    end
    local f, ferr = io.open(RC_PATH, "w")
    if not f then return false, ferr end
    f:write(RC_SCRIPT); f:close()

    -- Включаем сервис через rc API. Используем pcall на случай если
    -- модуль rc недоступен (нестандартная сборка OpenOS).
    local rcOk, rc = pcall(require, "rc")
    if not rcOk then
        return false, "модуль rc не найден — но файл " .. RC_PATH ..
                      " создан, можно включить вручную: rc " .. RC_NAME .. " enable"
    end
    local enOk, enErr = pcall(rc.enable, RC_NAME)
    if not enOk then return false, tostring(enErr) end
    return true
end

local function disableAutostart()
    -- Сначала отключаем через rc.disable (стирает запись из rc.cfg)
    pcall(function()
        local rc = require("rc")
        rc.disable(RC_NAME)
    end)
    -- Потом удаляем сам файл скрипта
    if fs.exists(RC_PATH) then
        local rmOk, rmErr = fs.remove(RC_PATH)
        if not rmOk then return false, rmErr end
    end
    return true
end

-- ---------- Решение: ставить автозапуск или нет ----------
print()
print("--- АВТОЗАПУСК (rc.d) ---")

local alreadyEnabled = isAutostartEnabled()
local wantAutostart

if autostartArg ~= nil then
    wantAutostart = autostartArg
    print("Режим: " .. (wantAutostart and "включить" or "выключить") .. " (из аргумента)")
else
    if alreadyEnabled then
        io.write("Автозапуск через rc.d уже настроен. Оставить? [Y/n]: ")
    else
        io.write("Запускать `flux` автоматически при включении ПК (через rc.d)? [Y/n]: ")
    end
    local answer = io.read() or ""
    answer = answer:lower():gsub("%s+", "")
    wantAutostart = (answer == "" or answer == "y" or answer == "yes" or answer == "д")
end

if wantAutostart then
    local aok, aerr = enableAutostart()
    if aok then
        print("✓ rc-сервис создан: " .. RC_PATH)
        print("✓ Включён в /etc/rc.cfg — стартует при следующей загрузке.")
        print()
        print("Управление сервисом:")
        print("  rc " .. RC_NAME .. " start     — запустить сейчас")
        print("  rc " .. RC_NAME .. " stop      — остановить")
        print("  rc " .. RC_NAME .. " restart   — перезапустить")
        print("  rc " .. RC_NAME .. " status    — проверить состояние")
        print("  rc " .. RC_NAME .. " disable   — выключить автозапуск")
    else
        print("✗ Не удалось включить автозапуск: " .. tostring(aerr))
    end
else
    if alreadyEnabled then
        local dok, derr = disableAutostart()
        if dok then
            print("✓ Автозапуск отключён, файл " .. RC_PATH .. " удалён.")
        else
            print("✗ Не удалось отключить: " .. tostring(derr))
        end
    else
        print("• Автозапуск не активирован (запускай `flux` вручную).")
    end
end

print()
print(string.format("Готово: успешно %d, с ошибкой %d, всего %d", ok, fail, #FILES))
if fail > 0 then
    print("Подсказка: проверь что репозиторий публичный, имя ветки правильное,")
    print("и что все файлы из FILES действительно лежат в репо.")
end
