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
-- НАСТРОЙКА АВТОЗАПУСКА ЧЕРЕЗ /home/.shrc
-- ============================================================================
-- Я начинал с rc.d, но это была ошибка для приложений с полноэкранным UI.
-- rc.d рассчитан на ФОНОВЫЕ сервисы — чанклоадеры, логгеры, сетевые мосты,
-- которые не претендуют на экран и клавиатуру. Когда полноэкранное
-- приложение вроде flux прописывается в rc.d:
--   1) start() запускает flux в отдельном thread и возвращается.
--   2) rc-демон завершает обработку сервисов.
--   3) init запускает интерактивный шелл на той же GPU+экран+клавиатуре.
--   4) Шелл рисует "OpenOS />" и мигающий курсор поверх flux.
--   5) flux перерисовывается каждые 0.25с, между перерисовками виден
--      курсор и работает ввод в шелл — "цвета борются" за один экран.
--
-- Правильный механизм для приложения-HUD — /home/.shrc:
--   • Шелл при логине автоматически выполняет .shrc.
--   • Команда `flux` в .shrc забирает терминал НАВСЕГДА (до выхода).
--   • Когда flux закроется кнопкой [ВЫХОД], управление вернётся в шелл.
--   • Никаких конфликтов: нет шелла поверх HUD, нет HUD поверх шелла.
--
-- Идемпотентность через маркеры комментариев — повторная установка
-- удалит старый блок и впишет свежий, дубликатов не будет.

local SHRC_PATH    = "/home/.shrc"
local AUTO_MARKER  = "# === AUTOSTART: " .. REPO .. " ==="
local AUTO_END     = "# === END AUTOSTART: " .. REPO .. " ==="
local AUTO_COMMAND = "flux"

-- Утилита: экранирование специальных символов для безопасного gsub-паттерна
local function escapePattern(s)
    return (s:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1"))
end

local function readShrc()
    if not fs.exists(SHRC_PATH) then return "" end
    local f = io.open(SHRC_PATH, "r")
    if not f then return "" end
    local content = f:read("*a") or ""; f:close()
    return content
end

local function writeShrc(content)
    local f, err = io.open(SHRC_PATH, "w")
    if not f then return false, err end
    f:write(content); f:close()
    return true
end

-- Удаляет наш блок автозапуска по маркерам (для идемпотентной перезаписи)
local function stripAutoBlock(content)
    local pat = "\n?" .. escapePattern(AUTO_MARKER)
              .. ".-" .. escapePattern(AUTO_END) .. "\n?"
    return (content:gsub(pat, "\n"))
end

local function isAutostartEnabled()
    return readShrc():find(AUTO_MARKER, 1, true) ~= nil
end

local function enableAutostart()
    local content = stripAutoBlock(readShrc())
    -- Убираем висящие пустые строки в конце чтобы блок встал чисто
    content = content:gsub("\n+$", "")
    local block = table.concat({
        "",
        AUTO_MARKER,
        "# Автозапуск flux-monitor. Удалить можно вручную (этот блок),",
        "# либо командой: install.lua --no-autostart",
        AUTO_COMMAND,
        AUTO_END,
        "",
    }, "\n")
    return writeShrc(content .. block)
end

local function disableAutostart()
    if not fs.exists(SHRC_PATH) then return true end
    return writeShrc(stripAutoBlock(readShrc()))
end

-- ---------- Миграция: удаление артефактов от старой rc.d-версии ----------
-- У пользователей предыдущих версий установщика остались /etc/rc.d/flux_monitor.lua
-- и запись в /etc/rc.cfg. Их надо вычистить, иначе flux будет запускаться
-- ДВАЖДЫ (rc-демон + шелл через .shrc), что сломает всё.
local function migrateFromRcd()
    local OLD_RC_NAME = REPO:gsub("-", "_")        -- "flux_monitor"
    local OLD_RC_PATH = "/etc/rc.d/" .. OLD_RC_NAME .. ".lua"
    local RC_CFG      = "/etc/rc.cfg"
    local migrated    = false

    -- Удаляем имя из enabled в rc.cfg
    if fs.exists(RC_CFG) then
        local f = io.open(RC_CFG, "r")
        if f then
            local content = f:read("*a") or ""; f:close()
            local cfg = {}
            local fn = load(content, "rc.cfg", "t", cfg)
            if fn then pcall(fn) end
            if type(cfg.enabled) == "table" then
                local newEnabled, removed = {}, false
                for _, name in ipairs(cfg.enabled) do
                    if name == OLD_RC_NAME then removed = true
                    else table.insert(newEnabled, name) end
                end
                if removed then
                    cfg.enabled = newEnabled
                    local serialization = require("serialization")
                    local lines = { "enabled = " .. serialization.serialize(cfg.enabled) }
                    for k, v in pairs(cfg) do
                        if k ~= "enabled" then
                            local ok, ser = pcall(serialization.serialize, v)
                            if ok then table.insert(lines, k .. " = " .. ser) end
                        end
                    end
                    local wf = io.open(RC_CFG, "w")
                    if wf then wf:write(table.concat(lines, "\n") .. "\n"); wf:close() end
                    migrated = true
                end
            end
        end
    end

    -- Удаляем сам файл rc-сервиса
    if fs.exists(OLD_RC_PATH) then
        pcall(fs.remove, OLD_RC_PATH)
        migrated = true
    end

    return migrated
end

-- ---------- Решение: ставить автозапуск или нет ----------
print()
print("--- АВТОЗАПУСК ---")

-- Сразу чистим старый rc.d (если он был от прошлой версии установщика)
local migrated = migrateFromRcd()
if migrated then
    print("✓ Удалены остатки старого rc.d-автозапуска (он не работал корректно).")
end

local alreadyEnabled = isAutostartEnabled()
local wantAutostart

if autostartArg ~= nil then
    wantAutostart = autostartArg
    print("Режим: " .. (wantAutostart and "включить" or "выключить") .. " (из аргумента)")
else
    if alreadyEnabled then
        io.write("Автозапуск уже настроен. Оставить? [Y/n]: ")
    else
        io.write("Запускать `flux` автоматически при включении ПК? [Y/n]: ")
    end
    local answer = io.read() or ""
    answer = answer:lower():gsub("%s+", "")
    wantAutostart = (answer == "" or answer == "y" or answer == "yes" or answer == "д")
end

if wantAutostart then
    local aok, aerr = enableAutostart()
    if aok then
        print("✓ Автозапуск настроен через " .. SHRC_PATH)
        print("  При следующем включении ПК команда `flux` запустится автоматически,")
        print("  как только инициализируется шелл.")
        print()
        print("Чтобы выйти из мониторинга — кнопка [ВЫХОД] в HUD.")
        print("Чтобы запустить вручную — просто `flux` в шелле.")
    else
        print("✗ Не удалось записать " .. SHRC_PATH .. ": " .. tostring(aerr))
    end
else
    if alreadyEnabled then
        local dok, derr = disableAutostart()
        if dok then
            print("✓ Автозапуск отключён, блок удалён из " .. SHRC_PATH)
        else
            print("✗ Не удалось отредактировать " .. SHRC_PATH .. ": " .. tostring(derr))
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