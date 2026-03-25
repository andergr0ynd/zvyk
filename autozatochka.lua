script_name('autozatochka.lua')
script_version('v2.0')
script_author('Auto')
script_description('Автоматическая заточка через CEF интерфейс')

local sampev = require 'lib.samp.events'
local imgui = require 'mimgui'
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local new = imgui.new

-- Arizona CEF: подключается в main() после проверки файлов (см. bootstrap библиотек)
local arizona = nil

-- == Settings == --
local WinState, playSound = new.bool(), new.bool()
local status = false
local max_toch = 0
local button_id = 0

-- Звук при успешной заточке (скачивается с GitHub)
local SOUND_URL = 'https://github.com/andergr0ynd/zvyk/raw/refs/heads/main/applepay.mp3'
local SOUND_FILENAME = 'applepay.mp3'
local SOUND_SUBDIR = 'autozatochka'
local PENDING_CHANGELOG_FILE = 'pending_changelog.txt'
local success_sound_stream = nil

-- Текст для окна после обновления: сначала качается changelog.txt с GitHub, иначе запасной текст
local CHANGELOG_TXT_URL = 'https://raw.githubusercontent.com/andergr0ynd/zvyk/refs/heads/main/changelog.txt'
local changelog_after_update = ''

local function pendingChangelogPath()
    return getWorkingDirectory() .. '\\' .. SOUND_SUBDIR .. '\\' .. PENDING_CHANGELOG_FILE
end

local function writePendingChangelog(text)
    local dir = getWorkingDirectory() .. '\\' .. SOUND_SUBDIR
    if not doesDirectoryExist(dir) then
        createDirectory(dir)
    end
    local f = io.open(pendingChangelogPath(), 'wb')
    if f then
        f:write(text or '')
        f:close()
    end
end

local function loadPendingChangelogIfAny()
    local p = pendingChangelogPath()
    if not doesFileExist(p) then return end
    local f = io.open(p, 'rb')
    if not f then return end
    local s = f:read('*a') or ''
    f:close()
    if #s == 0 then return end
    local ok, dec = pcall(function() return u8:decode(s) end)
    changelog_after_update = (ok and dec) and dec or s
end

local function pendingChangelogDownloadUsable(path)
    local fh = io.open(path, 'rb')
    if not fh then return false end
    local s = fh:read('*a') or ''
    fh:close()
    if #s == 0 then return false end
    local head = s:sub(1, 12):lower()
    if head:find('^<!doctype') or head:find('^<html') then return false end
    return true
end

-- Скачивает changelog.txt в pending-файл; если не вышло — пишет fallback (UTF-8)
local function downloadRemoteChangelogOrWriteFallback(fallback_text)
    local ml = require('moonloader')
    local d = ml.download_status
    local dir = getWorkingDirectory() .. '\\' .. SOUND_SUBDIR
    if not doesDirectoryExist(dir) then
        createDirectory(dir)
    end
    if not d or not downloadUrlToFile then
        writePendingChangelog(fallback_text)
        return
    end
    local path = pendingChangelogPath()
    local url = CHANGELOG_TXT_URL .. (CHANGELOG_TXT_URL:find('?', 1, true) and '&' or '?') .. 't=' .. tostring(os.clock())
    local done = false
    downloadUrlToFile(url, path, function(_, st)
        if st == d.STATUSEX_ENDDOWNLOAD or st == d.STATUS_ENDDOWNLOADDATA then
            done = true
        end
    end)
    local t0 = os.clock()
    while not done and os.clock() - t0 < 22 do wait(50) end
    if not pendingChangelogDownloadUsable(path) then
        writePendingChangelog(fallback_text)
    end
end

local as_action = require('moonloader').audiostream_state

-- Автообновление скрипта с GitHub (как в Cerberus.lua, с проверкой на nil)
-- version.json: latest, updateurl; опционально changelog — запас, если changelog.txt пустой/недоступен
if not decodeJson then
    local ok, j = pcall(require, 'json')
    if ok and j and j.decode then decodeJson = j.decode end
end
-- true: фоновая проверка version.json; после успешного обновления покажется окно «ВАЖНО» с changelog
local enable_autoupdate = true
local autoupdate_loaded = false
local Update = nil
if enable_autoupdate and decodeJson then
    local d = require('moonloader').download_status
    Update = {
        json_url = "https://raw.githubusercontent.com/andergr0ynd/zvyk/refs/heads/main/version.json",
        prefix = "[AutoZatochka]: ",
        url = "https://github.com/andergr0ynd/zvyk",
        check = function(json_url_base, prefix, url)
            prefix = prefix or ""
            json_url_base = json_url_base or Update.json_url
            local json_url = json_url_base .. (json_url_base:find("?") and "&" or "?") .. "t=" .. tostring(os.clock())
            local tmp = os.tmpname()
            if doesFileExist(tmp) then os.remove(tmp) end
            local start = os.clock()
            downloadUrlToFile(json_url, tmp, function(_, status, loaded, total)
                if status == d.STATUSEX_ENDDOWNLOAD then
                    if doesFileExist(tmp) then
                        local f = io.open(tmp, 'r')
                        if f then
                            local raw = f:read('*a')
                            f:close()
                            os.remove(tmp)
                            local l = raw and decodeJson(raw)
                            if l and l.updateurl and l.latest then
                                if l.latest ~= thisScript().version then
                                    lua_thread.create(function()
                                        local m = -1
                                        sampAddChatMessage(prefix .. u8:decode("Обнаружено обновление. Пытаюсь обновиться c " .. thisScript().version .. " на " .. l.latest), m)
                                        wait(250)
                                        local goupdatestatus
                                        downloadUrlToFile(l.updateurl, thisScript().path, function(_, st, p, q)
                                            if st == d.STATUS_DOWNLOADINGDATA then
                                                print(string.format('Загружено %d из %d.', p, q))
                                            elseif st == d.STATUS_ENDDOWNLOADDATA then
                                                print('Загрузка обновления завершена.')
                                                sampAddChatMessage(prefix .. u8:decode("Обновление завершено!"), m)
                                                goupdatestatus = true
                                                local ch = l.changelog or l.changes or l.notes
                                                local fallback
                                                if type(ch) == 'string' and #ch > 0 then
                                                    fallback = ch
                                                else
                                                    fallback = u8:decode('Скрипт обновлён до версии ') .. tostring(l.latest)
                                                        .. u8:decode('.\n\nСписок изменений: файл changelog.txt в репозитории zvyk (или поле changelog в version.json).')
                                                end
                                                lua_thread.create(function()
                                                    wait(350)
                                                    downloadRemoteChangelogOrWriteFallback(fallback)
                                                    wait(150)
                                                    thisScript():reload()
                                                end)
                                            end
                                            if st == d.STATUSEX_ENDDOWNLOAD then
                                                if not goupdatestatus then
                                                    sampAddChatMessage(prefix .. u8:decode("Обновление прошло неудачно. Запускаю устаревшую версию.."), m)
                                                end
                                            end
                                        end)
                                    end)
                                else
                                    print(u8:decode('v' .. thisScript().version .. ': Обновление не требуется.'))
                                end
                            else
                                print(u8:decode('v' .. thisScript().version .. ': Неверный version.json или он отсутствует в репозитории.'))
                            end
                        else
                            os.remove(tmp)
                            print(u8:decode('v' .. thisScript().version .. ': Не могу прочитать ответ. Проверьте ' .. tostring(url)))
                        end
                    end
                end
            end)
            while os.clock() - start < 10 do wait(100) end
            if os.clock() - start >= 10 then
                print(u8:decode('v' .. thisScript().version .. ': timeout проверки обновления. ' .. tostring(url)))
            end
        end
    }
    autoupdate_loaded = true
end

-- Синхронизация lib/arizona-events с GitHub → moonloader\lib\arizona-events
-- Источник на GitHub: zvyk/arizona-events/*.lua (raw). На диск: moonloader\lib\arizona-events\
-- Если файлов нет или они битые — скрипт качает, перезагружается, затем продолжает работу.
local LIB_ARIZONA_EVENTS_BASE = 'https://raw.githubusercontent.com/andergr0ynd/zvyk/refs/heads/main/arizona-events/'
local LIB_ARIZONA_EVENTS_DIR = 'lib\\arizona-events'
local LIB_ARIZONA_EVENTS_FILES = { 'init.lua', 'core.lua', 'bitstream.lua', 'subprocess.lua' }

local function libFileLooksBad(path)
    local f = io.open(path, 'rb')
    if not f then return true end
    local s = f:read('*a') or ''
    f:close()
    if #s < 32 then return true end
    local head = s:sub(1, 12):lower()
    if head:find('^<!doctype') or head:find('^<html') then return true end
    return false
end

local function arizonaEventsLibPaths()
    local root = getWorkingDirectory()
    local dir = root .. '\\' .. LIB_ARIZONA_EVENTS_DIR
    return root, dir
end

-- У части пользователей нет папки lib\arizona-events — создаём lib и вложенную arizona-events отдельно
local function ensureArizonaEventsLibDir()
    local root, dir = arizonaEventsLibPaths()
    local libDir = root .. '\\lib'
    if not doesDirectoryExist(libDir) then
        createDirectory(libDir)
    end
    if not doesDirectoryExist(dir) then
        createDirectory(dir)
    end
end

local function arizonaEventsLibPresent()
    local _, dir = arizonaEventsLibPaths()
    for _, name in ipairs(LIB_ARIZONA_EVENTS_FILES) do
        local path = dir .. '\\' .. name
        if not doesFileExist(path) or libFileLooksBad(path) then
            return false
        end
    end
    return true
end

-- force_all: скачать все файлы заново (первый запуск / восстановление)
-- возвращает true, если после операции все четыре файла на месте и валидны
local function syncArizonaEventsLib(force_all)
    ensureArizonaEventsLibDir()
    local ml = require('moonloader')
    local d = ml.download_status
    if not d or not downloadUrlToFile then
        return false
    end
    local _, dir = arizonaEventsLibPaths()
    for _, name in ipairs(LIB_ARIZONA_EVENTS_FILES) do
        local path = dir .. '\\' .. name
        local need = force_all or not doesFileExist(path) or libFileLooksBad(path)
        if need then
            local url = LIB_ARIZONA_EVENTS_BASE .. name
            url = url .. (url:find('?', 1, true) and '&' or '?') .. 't=' .. tostring(os.clock())
            local done, ok = false, false
            downloadUrlToFile(url, path, function(_, status)
                if status == d.STATUSEX_ENDDOWNLOAD or status == d.STATUS_ENDDOWNLOADDATA then
                    ok = doesFileExist(path) and not libFileLooksBad(path)
                    done = true
                end
            end)
            local start = os.clock()
            while not done and os.clock() - start < 45 do wait(50) end
            if ok then
                print('[AutoZatochka] ' .. u8:decode('Библиотека сохранена: ') .. LIB_ARIZONA_EVENTS_DIR .. '\\' .. name)
            else
                print('[AutoZatochka] ' .. u8:decode('Не удалось скачать: ') .. name)
            end
        end
    end
    return arizonaEventsLibPresent()
end

-- Stone
local tochi, workshop_check, stone_check = false, false, false
local lost_stone_onLVL, all_lost = 0, 0
local stone = {}
local lost_stone = {}
local enchantSlotsData = { index = -1, left = -1 }

-- ID точильного камня: [1187] = "Точильный камень"
local Whetstone_ITEM_ID = 1187

-- Инициализация звука успешной заточки: скачивание с GitHub и загрузка потока
local dl_status = pcall(require, 'moonloader') and require('moonloader').download_status
local function initSuccessSound()
    local dir = getWorkingDirectory() .. '\\' .. SOUND_SUBDIR
    if not doesDirectoryExist(dir) then
        createDirectory(dir)
    end
    local path = dir .. '\\' .. SOUND_FILENAME
    local function tryLoadStream()
        if doesFileExist(path) and not success_sound_stream then
            success_sound_stream = loadAudioStream(path)
        end
    end
    if doesFileExist(path) then
        tryLoadStream()
        return
    end
    if dl_status then
        downloadUrlToFile(SOUND_URL, path, function(_, status)
            if status == dl_status.STATUSEX_ENDDOWNLOAD or status == dl_status.STATUS_ENDDOWNLOADDATA then
                lua_thread.create(function()
                    wait(200)
                    tryLoadStream()
                end)
            end
        end)
    else
        downloadUrlToFile(SOUND_URL, path)
        wait(1500)
        tryLoadStream()
    end
end

-- Воспроизведение звука успешной заточки
local function playSuccessSound()
    if not playSound[0] then return end
    if not success_sound_stream then
        local path = getWorkingDirectory() .. '\\' .. SOUND_SUBDIR .. '\\' .. SOUND_FILENAME
        if doesFileExist(path) then
            success_sound_stream = loadAudioStream(path)
        end
    end
    if success_sound_stream then
        setAudioStreamState(success_sound_stream, as_action.STOP)
        setAudioStreamState(success_sound_stream, as_action.PLAY)
        setAudioStreamVolume(success_sound_stream, 1.0)
    else
        addOneOffSound(0.0, 0.0, 0.0, 1139)
    end
end

-- Склонение для статистики: "N попытка" / "N попытки" / "N попыток" (должна быть выше imgui.OnFrame)
local function attemptsWord(n)
    n = tonumber(n) or 0
    if n == 1 then return "1 попытка"
    elseif n >= 2 and n <= 4 then return n .. " попытки"
    else return n .. " попыток" end
end

-- == CEF функции == --
function evalanon(code)
    evalcef(("(() => {%s})()"):format(code))
end

function evalcef(code, encoded)
    encoded = encoded or 0
    if arizona and arizona.eval and encoded == 0 then
        arizona.eval(code, 0)
        return
    end
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 17)
    raknetBitStreamWriteInt32(bs, 0)
    raknetBitStreamWriteInt16(bs, #code)
    raknetBitStreamWriteInt8(bs, encoded)
    raknetBitStreamWriteString(bs, code)
    raknetEmulPacketReceiveBitStream(220, bs)
    raknetDeleteBitStream(bs)
end

-- == Функции отправки CEF команд == --
function sendCEF(str)
    if arizona and arizona.send then
        arizona.send('onArizonaSend', { text = str, server_id = 0 })
        return
    end
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 220)
    raknetBitStreamWriteInt8(bs, 18)
    raknetBitStreamWriteInt16(bs, #str)
    raknetBitStreamWriteString(bs, str)
    raknetBitStreamWriteInt32(bs, 0)
    raknetSendBitStream(bs)
    raknetDeleteBitStream(bs)
end

-- == Функции работы с CEF == --
function rightClickOnBlock(slot, type)
    -- Отправляем событие rightClickOnBlock (как в пакете: rightClickOnBlock|{"slot": 29, "type": 1})
    local json = string.format('{"slot": %d, "type": %d}', slot, type or 1)
    sendCEF('rightClickOnBlock|'..json)
end

function leftClickOnBlock(slot, type)
    local json = string.format('{"slot": %d, "type": %d}', slot, type or 1)
    sendCEF('leftClickOnBlock|'..json)
end

-- Как в ArzMarket: клик по слоту (выбор/перенос предмета)
function clickOnBlock(slot, type)
    local json = string.format('{"slot": %d, "type": %d}', slot, type or 1)
    sendCEF('clickOnBlock|'..json)
end

function clickOnButton(type, slot, action)
    -- Отправляем событие clickOnButton (как в пакете: clickOnButton|{"type": 1,"slot": 29, "action": 16})
    local json = string.format('{"type": %d, "slot": %d, "action": %d}', type or 1, slot, action or 16)
    sendCEF('clickOnButton|'..json)
end

function moveItem(fromSlot, fromType, toSlot, toType, amount)
    -- Отправляем событие inventory.moveItem (как в пакете: inventory.moveItem|{"from":{"slot":40,"type":1,"amount":15},"to":{"slot":29,"type":1}})
    amount = amount or 1
    fromType = fromType or 1
    toType = toType or 1
    local json = string.format('{"from":{"slot":%d,"type":%d,"amount":%d},"to":{"slot":%d,"type":%d}}', fromSlot, fromType, amount, toSlot, toType)
    sendCEF('inventory.moveItem|'..json)
end

local Whetstone_KEYWORDS = { "Точильный камень", "точильный камень", "Заточка", "заточка" }

function findStoneSlotNumber()
    local kwEsc = (Whetstone_KEYWORDS[1]):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\r", ""):gsub("\n", "\\n")
    evalanon(string.format([[
        try {
            var stoneSlotNumber = -1;
            var keywords = ["%s", "Заточка", "заточка"];
            var containerSelectors = ['.inventory-main__grid', '.inventory-grid__grid', '.warehouse .inventory-grid__grid', '[class*="inventory-grid"]', '[class*="inventory-main"]', '.inventory-container', '[class*="inventory"]'];
            for (var cs = 0; cs < containerSelectors.length; cs++) {
                var containers = document.querySelectorAll(containerSelectors[cs]);
                for (var c = 0; c < containers.length; c++) {
                    var items = containers[c].querySelectorAll('.inventory-item-hoc, .inventory-grid__item-bg, [class*="item"]');
                    for (var i = 0; i < items.length; i++) {
                        var item = items[i];
                        var img = item.querySelector('.inventory-item__image, img');
                        if (!img) continue;
                        var alt = img.getAttribute('alt') || '';
                        var src = img.getAttribute('src') || '';
                        var text = (item.innerText || item.textContent || '').toString();
                        var combined = alt + ' ' + text;
                        var m = alt.match(/\d+/); var m2 = src.match(/\d+/);
                        var id = parseInt(m ? m[0] : 0) || parseInt(m2 ? m2[0] : 0) || 0;
                        var byName = false;
                        for (var k = 0; k < keywords.length; k++) { if (combined.indexOf(keywords[k]) !== -1) { byName = true; break; } }
                        if (id !== 1187 && !byName) continue;
                        var slotNum = -1;
                        var slotAttr = item.getAttribute('data-slot');
                        if (slotAttr) slotNum = parseInt(slotAttr);
                        if (slotNum < 0) { var p = item.closest('[data-slot]'); if (p) slotNum = parseInt(p.getAttribute('data-slot')); }
                        if (slotNum < 0) { var ia = item.getAttribute('data-index'); if (ia) slotNum = parseInt(ia); }
                        if (slotNum < 0) { var s2 = item.getAttribute('slot'); if (s2) slotNum = parseInt(s2); }
                        if (slotNum < 0) slotNum = i;
                        if (slotNum >= 0) { window.stoneSlotNumber = slotNum; return slotNum; }
                    }
                }
            }
            return -1;
        } catch(e) { return -1; }
    ]], kwEsc))
    wait(150)
    local slotNum = evalanon([[ return (typeof window.stoneSlotNumber !== 'undefined' && window.stoneSlotNumber >= 0) ? window.stoneSlotNumber : -1; ]])
    return (type(slotNum) == 'number' and slotNum >= 0) and slotNum or (tonumber(slotNum) or -1)
end

function findEnchantSlotNumber()
    evalanon([[
        try {
            // Ищем левый слот заточки (пустой слот, куда нужно положить камень)
            const leftSlotSelectors = [
                '[class*="left-slot"]',
                '[class*="leftSlot"]',
                '[class*="left_slot"]',
                '[data-slot="left"]',
                '[data-slot-type="left"]',
                '[class*="enchant-slot"]:first-child',
                '[class*="enchantSlot"]:first-child',
                '.enchant-main__slot-item:first-child',
                '[class*="enchant-slot"]',
                '[class*="enchantSlot"]'
            ];
            let enchantSlotNumber = -1;
            
            for (let selector of leftSlotSelectors) {
                const slots = document.querySelectorAll(selector);
                for (let slot of slots) {
                    const rect = slot.getBoundingClientRect();
                    if (rect.width > 0 && rect.height > 0) {
                        // Проверяем, что слот пустой
                        const hasItem = slot.querySelector('.inventory-item-hoc, .inventory-item__image, img[alt*="1187"]');
                        if (!hasItem) {
                            // Пытаемся определить номер слота
                            let slotNum = -1;
                            
                            // Метод 1: data-slot атрибут
                            const slotAttr = slot.getAttribute('data-slot');
                            if (slotAttr && slotAttr !== 'left') {
                                slotNum = parseInt(slotAttr);
                            }
                            
                            // Метод 2: data-index
                            if (slotNum < 0) {
                                const indexAttr = slot.getAttribute('data-index');
                                if (indexAttr) {
                                    slotNum = parseInt(indexAttr);
                                }
                            }
                            
                            // Метод 3: Используем индекс из enchantSlotsData.index (если есть)
                            if (slotNum < 0 && window.enchantSlotIndex !== undefined) {
                                slotNum = window.enchantSlotIndex;
                            }
                            
                            if (slotNum >= 0) {
                                enchantSlotNumber = slotNum;
                                window.enchantSlotNumber = slotNum;
                                return slotNum;
                            }
                            
                            // Если не нашли номер, но нашли пустой слот - используем индекс
                            enchantSlotNumber = 0; // Fallback
                            window.enchantSlotNumber = 0;
                            return 0;
                        }
                    }
                }
                if (enchantSlotNumber >= 0) break;
            }
            
            return enchantSlotNumber;
        } catch(e) {
            return -1;
        }
    ]])
    wait(100)
    local slotNum = evalanon([[
        return window.enchantSlotNumber !== undefined ? window.enchantSlotNumber : -1;
    ]])
    return slotNum or -1
end

function findAndClickStone()
    local stoneSlotNum = findStoneSlotNumber()
    
    if stoneSlotNum >= 0 then
        if enchantSlotsData.left == -1 then
            local enchantSlot = enchantSlotsData.index >= 0 and enchantSlotsData.index or findEnchantSlotNumber()
            
            -- 1) Как в ArzMarket: moveItem из слота камня в слот заточки (type 1 = инвентарь)
            if enchantSlot >= 0 then
                moveItem(stoneSlotNum, 1, enchantSlot, 1, 1)
                wait(500)
            end
            
            -- 2) Стиль ArzMarket: clickOnBlock — клик по слоту с камнем (взять), потом по слоту заточки (положить)
            if enchantSlot >= 0 then
                clickOnBlock(stoneSlotNum, 1)
                wait(350)
                clickOnBlock(enchantSlot, 1)
                wait(400)
            end
            
            local enchantSlotNum = (enchantSlot >= 0) and enchantSlot or findEnchantSlotNumber()
            if enchantSlotNum >= 0 and enchantSlotNum ~= enchantSlotsData.index then
                for _, toType in ipairs({1, 2, 3, 4, 5}) do
                    moveItem(stoneSlotNum, 1, enchantSlotNum, toType, 1)
                    wait(400)
                end
            end
            
            -- Пробуем использовать специальные номера слотов
            for _, specialSlot in ipairs({-1, -2, -3, 0, 1, 2, 100, 200, 1000, 2000}) do
                for _, toType in ipairs({1, 2, 3}) do
                    moveItem(stoneSlotNum, 1, specialSlot, toType, 1)
                    wait(200)
                end
            end
            
            -- Fallback: Используем rightClickOnBlock для клика по слоту с камнем (type: 1)
            -- Это "берет" камень в руку
            rightClickOnBlock(stoneSlotNum, 1)
            wait(800) -- Даем больше времени на обработку события
            
            -- Теперь пробуем разместить камень после rightClickOnBlock
            if enchantSlotsData.index >= 0 then
                for _, toType in ipairs({1, 2, 3, 4, 5}) do
                    moveItem(stoneSlotNum, 1, enchantSlotsData.index, toType, 1)
                    wait(400)
                end
            end
            if enchantSlotNum >= 0 and enchantSlotNum ~= enchantSlotsData.index then
                for _, toType in ipairs({1, 2, 3, 4, 5}) do
                    moveItem(stoneSlotNum, 1, enchantSlotNum, toType, 1)
                    wait(400)
                end
            end
            
            -- Метод 3: Пробуем использовать специальные номера слотов для слота заточки
            -- Возможно, слот заточки имеет специальный номер (не из инвентаря)
            -- Пробуем отрицательные числа, так как left: -1 может означать специальный номер
            for _, specialSlot in ipairs({-1, -2, -3, 0, 1, 2, 100, 200, 1000, 2000}) do
                for _, toType in ipairs({1, 2, 3}) do
                    moveItem(stoneSlotNum, 1, specialSlot, toType, 1)
                    wait(200)
                end
            end
            
            -- Метод 3.5: Пробуем использовать moveItem БЕЗ rightClickOnBlock (может быть, не нужно брать камень в руку?)
            -- Пропускаем rightClickOnBlock и сразу используем moveItem
            if enchantSlotsData.index >= 0 then
                moveItem(stoneSlotNum, 1, enchantSlotsData.index, 1, 1)
                wait(600)
            end
            
            -- Метод 4: Fallback - используем leftClickOnBlock (на случай если moveItem не работает)
            if enchantSlotsData.index >= 0 then
                leftClickOnBlock(enchantSlotsData.index, 1)
                wait(400)
            end
            if enchantSlotNum >= 0 and enchantSlotNum ~= enchantSlotsData.index then
                leftClickOnBlock(enchantSlotNum, 1)
                wait(400)
            end
            
            -- Метод 5: Пробуем использовать clickOnButton с action: 16
            if enchantSlotsData.index >= 0 then
                clickOnButton(1, enchantSlotsData.index, 16)
                wait(400)
            end
            
            -- Метод 6: Кликаем через JavaScript (самый надежный метод)
            -- Это должно сработать, если камень "в руке" после rightClickOnBlock
            evalanon([[
                try {
                    // Ищем левый слот заточки (пустой слот) - более агрессивный поиск
                    const leftSlotSelectors = [
                        '[class*="left-slot"]',
                        '[class*="leftSlot"]',
                        '[class*="left_slot"]',
                        '[data-slot="left"]',
                        '[data-slot-type="left"]',
                        '[class*="enchant-slot"]:first-child',
                        '[class*="enchantSlot"]:first-child',
                        '.enchant-main__slot-item:first-child',
                        '[class*="enchant-slot"]',
                        '[class*="enchantSlot"]',
                        '[class*="slot"][class*="enchant"]',
                        '[data-slot-type="enchant"]'
                    ];
                    
                    let foundSlot = null;
                    
                    for (let selector of leftSlotSelectors) {
                        const slots = document.querySelectorAll(selector);
                        for (let slot of slots) {
                            const rect = slot.getBoundingClientRect();
                            if (rect.width > 0 && rect.height > 0) {
                                // Проверяем, что слот пустой
                                const hasItem = slot.querySelector('.inventory-item-hoc, .inventory-item__image, img[alt*="1187"]');
                                if (!hasItem) {
                                    // Дополнительная проверка: слот должен быть в области заточки
                                    const parent = slot.closest('[class*="enchant"], [class*="workshop"], [class*="верстак"]');
                                    if (parent || selector.includes('enchant') || selector.includes('slot')) {
                                        foundSlot = slot;
                                        break;
                                    }
                                }
                            }
                        }
                        if (foundSlot) break;
                    }
                    
                    if (foundSlot) {
                        const rect = foundSlot.getBoundingClientRect();
                        const centerX = rect.left + rect.width / 2;
                        const centerY = rect.top + rect.height / 2;
                        
                        // Метод 6.1: Прямой клик (самый простой) - ПРИОРИТЕТ
                        if (typeof foundSlot.click === 'function') {
                            foundSlot.click();
                        }
                        
                        // Метод 6.2: Полная последовательность событий мыши для левого клика
                        const mousedown = new MouseEvent('mousedown', {
                            bubbles: true,
                            cancelable: true,
                            button: 0,
                            clientX: centerX,
                            clientY: centerY,
                            view: window
                        });
                        foundSlot.dispatchEvent(mousedown);
                        
                        setTimeout(() => {
                            const mouseup = new MouseEvent('mouseup', {
                                bubbles: true,
                                cancelable: true,
                                button: 0,
                                clientX: centerX,
                                clientY: centerY,
                                view: window
                            });
                            foundSlot.dispatchEvent(mouseup);
                            
                            setTimeout(() => {
                                const clickEvent = new MouseEvent('click', {
                                    bubbles: true,
                                    cancelable: true,
                                    button: 0,
                                    clientX: centerX,
                                    clientY: centerY,
                                    view: window
                                });
                                foundSlot.dispatchEvent(clickEvent);
                                
                                // Повторный клик для надежности
                                if (typeof foundSlot.click === 'function') {
                                    foundSlot.click();
                                }
                            }, 50);
                        }, 50);
                        
                        // Метод 6.3: Drag & Drop события (если камень "в руке" после rightClickOnBlock)
                        setTimeout(() => {
                            const dragOver = new DragEvent('dragover', {
                                bubbles: true,
                                cancelable: true,
                                clientX: centerX,
                                clientY: centerY,
                                view: window,
                                dataTransfer: new DataTransfer()
                            });
                            foundSlot.dispatchEvent(dragOver);
                            
                            setTimeout(() => {
                                const drop = new DragEvent('drop', {
                                    bubbles: true,
                                    cancelable: true,
                                    clientX: centerX,
                                    clientY: centerY,
                                    view: window,
                                    dataTransfer: new DataTransfer()
                                });
                                foundSlot.dispatchEvent(drop);
                            }, 50);
                        }, 200);
                        
                        return true;
                    }
                } catch(e) {
                    console.error('Error clicking enchant slot:', e);
                }
                return false;
            ]])
            wait(1000)
        end
        return true
    else
        -- Fallback: ищем камень через обычный поиск и кликаем напрямую
        evalanon([[
            try {
                const containers = document.querySelectorAll('.inventory-main__grid, .inventory-grid__grid, .warehouse .inventory-grid__grid, [class*="inventory-grid"]');
                let stoneItem = null;
                
                containers.forEach((container) => {
                    const items = container.querySelectorAll('.inventory-item-hoc, .inventory-grid__item-bg');
                    items.forEach((item) => {
                        const img = item.querySelector('.inventory-item__image, img');
                        if (img) {
                            const alt = img.getAttribute('alt') || '';
                            const itemId = parseInt(alt.match(/\d+/)?.[0]) || 0;
                            if (itemId === 1187) {
                                stoneItem = item;
                                return;
                            }
                        }
                    });
                    if (stoneItem) return;
                });
                
                if (stoneItem) {
                    stoneItem.click();
                    return true;
                }
            } catch(e) {}
            return false;
        ]])
    end
    return false
end

function findAndClickEnchantButton()
    evalanon([[
        try {
            const buttonTexts = ['ENCHANT', 'ЗАТОЧКА', 'Заточить', 'Улучшить', 'ENHANCE', 'Заточка', 'заточка', 'ЗАТОЧИТЬ', 'START', 'НАЧАТЬ'];
            const selectors = [
                'button',
                '[role="button"]',
                '.btn',
                '[class*="button"]',
                '[class*="btn"]',
                '[class*="enchant"]',
                '[class*="ENCHANT"]',
                '[class*="start"]',
                '[class*="START"]',
                'div[onclick]',
                'a[onclick]',
                '*[onclick]'
            ];
            
            for (let selector of selectors) {
                try {
                    const buttons = document.querySelectorAll(selector);
                    for (let btn of buttons) {
                        try {
                            const rect = btn.getBoundingClientRect();
                            if (rect.width === 0 || rect.height === 0) continue;
                            const text = (btn.textContent || btn.innerText || '').toUpperCase();
                            const className = (btn.className || '').toUpperCase();
                            const id = (btn.id || '').toUpperCase();
                            const onclick = (btn.getAttribute('onclick') || '').toUpperCase();
                            
                            for (let searchText of buttonTexts) {
                                if (text.includes(searchText.toUpperCase()) || 
                                    className.includes(searchText.toUpperCase()) ||
                                    id.includes(searchText.toUpperCase()) ||
                                    onclick.includes(searchText.toUpperCase())) {
                                    // Двойной клик для надежности
                                    const clickEvent1 = new MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0 });
                                    btn.dispatchEvent(clickEvent1);
                                    const clickEvent2 = new MouseEvent('mouseup', { bubbles: true, cancelable: true, button: 0 });
                                    btn.dispatchEvent(clickEvent2);
                                    const clickEvent3 = new MouseEvent('click', { bubbles: true, cancelable: true, button: 0 });
                                    btn.dispatchEvent(clickEvent3);
                                    if (typeof btn.click === 'function') {
                                        btn.click();
                                    }
                                    return true;
                                }
                            }
                        } catch(e) {}
                    }
                } catch(e) {}
            }
        } catch(e) {}
        return false;
    ]])
end

-- == Отправка события startEnchant == --
function startEnchant()
    -- Отправляем событие startEnchant через CEF (как показано в пакете)
    sendCEF('startEnchant')
    -- Также пробуем через window.executeEvent
    evalanon([[
        try {
            if (typeof window.executeEvent === 'function') {
                window.executeEvent('startEnchant', '');
            }
        } catch(e) {}
    ]])
end

-- == Основная логика == --
function click_onStone()
    -- Сначала проверяем CEF интерфейс, если workshop_check еще не установлен
    if not workshop_check then
        checkWorkshopStatus()
    end

    if #stone == 0 then
        if workshop_check then
            -- Пытаемся найти камень через CEF
            findAndClickStone()
            tochi = workshop_check
        else
            checkWorkshopStatus()
            workshop_check = true
            findAndClickStone()
            tochi = true
        end
    else
        for _, v in pairs(stone) do
            sampSendClickTextdraw(v[1])
            tochi = (workshop_check and true or false)
            break
        end
    end
end

-- Разбор входящих CEF-строк (тип 17 / 18 пакета 220): общая логика для arizona-events и fallback
local function onCefIncomingText17(str)
    if not str or #str == 0 then return end
    if str:find('updateEnchantSlots') then
        workshop_check = true
        local jsonData = str:match('updateEnchantSlots|(.+)')
        if jsonData then
            local index = jsonData:match('"index":(%d+)') or jsonData:match('"index":(%-?%d+)')
            local left = jsonData:match('"left":(%d+)') or jsonData:match('"left":(%-?%d+)')
            if index then enchantSlotsData.index = tonumber(index) end
            if left then enchantSlotsData.left = tonumber(left) end
            if enchantSlotsData.left == -1 and status and max_toch > 0 and not tochi then
                lua_thread.create(function()
                    wait(300)
                    click_onStone()
                end)
            end
        end
    end
end

local function onCefIncomingText18(data)
    if not data then return end
    if data:find('updateEnchantSlots') then
        workshop_check = true
    end
end

function main()
    while not isSampAvailable() do wait(100) end
    sampRegisterChatCommand('mt', function() WinState[0] = not WinState[0] end)

    -- У кого нет lib/arizona-events: синхронная докачка → перезагрузка скрипта → уже с require
    if not arizonaEventsLibPresent() then
        sampAddChatMessage('[AutoZatochka] ' .. u8:decode('Не найдены библиотеки arizona-events. Скачиваю с GitHub…'), -1)
        local ok = syncArizonaEventsLib(true)
        if ok then
            sampAddChatMessage('[AutoZatochka] ' .. u8:decode('Загрузка завершена. Перезапуск скрипта…'), -1)
            wait(400)
            thisScript():reload()
        else
            sampAddChatMessage('[AutoZatochka] ' .. u8:decode('Скачивание не удалось. Проверьте сеть и папку zvyk/arizona-events на GitHub.'), -1)
        end
        return
    end

    do
        local ok_load, mod = pcall(require, 'arizona-events')
        if ok_load and mod then
            arizona = mod
        else
            arizona = nil
        end
    end

    if arizona then
        arizona.onArizonaDisplay = function(packet)
            if packet and packet.text then
                onCefIncomingText17(packet.text)
            end
        end
        arizona.onArizonaIncomingCef18 = function(packet)
            if packet and packet.text then
                onCefIncomingText18(packet.text)
            end
        end
    end

    loadPendingChangelogIfAny()

    -- Загрузка звука успешной заточки с GitHub в фоне
    lua_thread.create(function()
        wait(500)
        initSuccessSound()
    end)

    -- Проверка обновления скрипта с GitHub в фоне (как в Cerberus)
    lua_thread.create(function()
        wait(2000)
        if autoupdate_loaded and Update then
            pcall(Update.check, Update.json_url, Update.prefix, Update.url)
        end
    end)
    
    -- Пакет 220 разбирает lib arizona-events (onArizonaDisplay / onArizonaIncomingCef18). Если библиотека не загрузилась — вручную.
    if not arizona then
        addEventHandler('onReceivePacket', function(id, bs)
            if id ~= 220 then return end
            raknetBitStreamIgnoreBits(bs, 8)
            local packetType = raknetBitStreamReadInt8(bs)
            if packetType == 17 then
                raknetBitStreamIgnoreBits(bs, 32)
                local length = raknetBitStreamReadInt16(bs)
                local encoded = raknetBitStreamReadInt8(bs)
                if length > 0 then
                    local str = (encoded ~= 0) and raknetBitStreamDecodeString(bs, length + encoded) or raknetBitStreamReadString(bs, length)
                    if str then onCefIncomingText17(str) end
                end
            elseif packetType == 18 then
                local dataLength = raknetBitStreamReadInt16(bs)
                local encoded = raknetBitStreamReadInt8(bs)
                if dataLength > 0 then
                    local data = (encoded ~= 0) and raknetBitStreamDecodeString(bs, dataLength + encoded) or raknetBitStreamReadString(bs, dataLength)
                    if data then onCefIncomingText18(data) end
                end
            end
        end)
    end
    
    -- Устанавливаем обработчики CEF событий через JavaScript
    evalanon([[
        window.enchantInterfaceOpen = false;
        window.workshopOpen = false;
        
        // Периодическая проверка наличия верстака
        setInterval(function() {
            const bodyText = (document.body.innerText || document.body.textContent || '').toUpperCase();
            if (bodyText.includes('WORKSHOP') || bodyText.includes('ВЕРСТАК') || bodyText.includes('ENCHANT') || bodyText.includes('ЗАТОЧКА')) {
                window.workshopOpen = true;
            }
            if (document.querySelectorAll('[data-item-id="1187"], [data-model="1187"]').length > 0) {
                window.workshopOpen = true;
            }
        }, 1000);
    ]])
    
    while true do
        wait(0)
        if status then
            if (workshop_check and tochi) then
                wait(1500)
                stone_check = true
                -- Пытаемся кликнуть через CEF
                findAndClickEnchantButton()
                -- Отправляем событие startEnchant для начала заточки
                wait(200)
                startEnchant()
                -- Fallback на textdraw если есть button_id
                if button_id > 0 then
                    wait(200)
                    sampSendClickTextdraw(button_id)
                end
                tochi = false
                wait(1500)
                if stone_check then
                    if #stone > 0 then
                        table.remove(stone, 1)
                    end
                    stone_check = false
                    tochi = false
                    wait(500)
                    click_onStone()
                end
            elseif workshop_check and status and max_toch > 0 and not tochi then
                -- Периодически пытаемся найти и кликнуть камень если верстак открыт
                wait(1000)
                if #stone == 0 then
                    findAndClickStone()
                else
                    click_onStone()
                end
            elseif status and max_toch > 0 and not workshop_check then
                -- Периодически проверяем, не открылся ли верстак через CEF
                wait(2000)
                checkWorkshopStatus()
                workshop_check = true
                wait(500)
                click_onStone()
            end
        end
    end
end

imgui.OnFrame(function() return WinState[0] end,
    function(player)
        imgui.SetNextWindowPos(imgui.ImVec2(500,500), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(430, 390), imgui.Cond.Always)
        imgui.Begin('##Window', WinState, imgui.WindowFlags.NoDecoration)
        imgui.SetCursorPosX(70) imgui.Text('Автозаточка | CEF интерфейс by GPT :D')
        imgui.SameLine() imgui.SetCursorPosX(408) if imgui.Button('##CloseButton', imgui.ImVec2(15, 15)) then WinState[0] = false end imgui.Separator()
        
        if imgui.BeginChild('##tochLVL', imgui.ImVec2(85, 350), true) then
            imgui.Text('Точить до') imgui.Separator() imgui.SetCursorPosY(32)
            for i = 1, 12 do imgui.SetCursorPosX(20)
                if imgui.ColoredButton('+'..tostring(i), imgui.ImVec2(30, 20), (i==max_toch and '32CD32' or 'F94242'), 50) then
                    if max_toch ~= i then
                        status = true
                        max_toch = i
                        -- Вызываем асинхронно, чтобы избежать ошибки "yield across C-call boundary"
                        lua_thread.create(function()
                            wait(100)
                            click_onStone()
                        end)
                    else
                        status = false
                        max_toch = 0
                        tochi = false
                        stone_check = false
                        workshop_check = false
                    end
                end
            end
            imgui.EndChild()
        end imgui.SameLine()
        
        if imgui.BeginChild('##stats', imgui.ImVec2(160, 350), true) then
            imgui.SetCursorPosX(35) imgui.Text('Статистика') imgui.Separator()
            for k, v in pairs(lost_stone) do
                imgui.Text('С +' .. (v[2]-1) .. ' до +' .. v[2] .. ': ' .. attemptsWord(v[1]))
                imgui.Separator()
            end
            imgui.Text('Всего попыток: ' .. all_lost)
            imgui.EndChild()
        end imgui.SameLine()
        
        if imgui.BeginChild('##other', imgui.ImVec2(190, 350), true) then
            imgui.SetCursorPosX(55) imgui.Text('Настройки') imgui.Separator()
            imgui.Separator()
            if imgui.Button('Очистить статистику', imgui.ImVec2(140, 24)) then
                lost_stone = {}
                all_lost = 0
                lost_stone_onLVL = 0
                max_toch = 0
                stone_check = false
            end
            if imgui.Button('Перезагрузить скрипт', imgui.ImVec2(140, 24)) then
                lua_thread.create(function()
                    sampAddChatMessage('[AutoZatochka] Перезагрузка скрипта...', -1)
                    wait(1000)
                    thisScript():reload()
                end)
            end
            if imgui.Button('Проверить обновления', imgui.ImVec2(140, 24)) then
                lua_thread.create(function()
                    if autoupdate_loaded and Update then
                        print('[AutoZatochka] Проверка обновлений...', -1)
                        wait(100)
                        pcall(Update.check, Update.json_url, Update.prefix, Update.url)
                        wait(500)
                        print('[AutoZatochka] Если есть новая версия — скрипт обновится и перезагрузится.', -1)
                    else
                        print('[AutoZatochka] Автообновление недоступно.', -1)
                    end
                end)
            end
            if imgui.Checkbox('Включить звук', playSound) then
                addOneOffSound(0.0, 0.0, 0.0, 1139)
            end
            imgui.Text('Версия: ' .. tostring(thisScript().version or '1.0'))
            for i = 54, 10, -1 do
                imgui.ColSeparator('FF0000', i)
            end
            imgui.EndChild()
        end
        imgui.End()
    end
)

-- Окно списка изменений после обновления
imgui.OnFrame(function()
    return changelog_after_update ~= ''
end, function()
    local io = imgui.GetIO()
    local w = io.DisplaySize.x
    imgui.SetNextWindowPos(imgui.ImVec2(w * 0.5, io.DisplaySize.y * 0.5), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(500, 0), imgui.Cond.FirstUseEver)
    local wf = imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoCollapse
    if imgui.Begin(u8:decode('ВАЖНО — обновление AutoZatochka'), nil, wf) then
        imgui.TextColored(imgui.ImVec4(1, 0.35, 0.12, 1), u8:decode('Список изменений'))
        imgui.Separator()
        imgui.BeginChild('##changelog_scroll', imgui.ImVec2(460, 240), true)
        imgui.TextWrapped(changelog_after_update)
        imgui.EndChild()
        imgui.Spacing()
        if imgui.Button(u8:decode('Понятно'), imgui.ImVec2(220, 34)) then
            local pth = pendingChangelogPath()
            if doesFileExist(pth) then
                pcall(os.remove, pth)
            end
            changelog_after_update = ''
        end
        imgui.End()
    end
end)

-- == Проверка и установка флага верстака == --
function checkWorkshopStatus()
    -- Простая и надежная проверка через поиск элементов и текста (без wait для использования в imgui)
    evalanon([[
        try {
            const bodyText = (document.body.innerText || document.body.textContent || '').toUpperCase();
            const hasKeywords = bodyText.includes('WORKSHOP') || bodyText.includes('ВЕРСТАК') || 
                               bodyText.includes('МАСТЕРСКАЯ') || bodyText.includes('ENCHANT') || 
                               bodyText.includes('ЗАТОЧКА');
            
            const hasEnchantElements = document.querySelectorAll('[class*="enchant"], [class*="Enchant"], [id*="enchant"]').length > 0;
            const hasWorkshopElements = document.querySelectorAll('[class*="workshop"], [class*="Workshop"], [id*="workshop"]').length > 0;
            let hasStoneElements = document.querySelectorAll('[data-item-id="1187"], [data-model="1187"], [data-id="1187"]').length > 0;
            
            // Проверка через структуру инвентаря (как в sorting.lua)
            if (!hasStoneElements) {
                const inventoryItems = document.querySelectorAll('.inventory-item-hoc');
                for (let item of inventoryItems) {
                    const img = item.querySelector('.inventory-item__image');
                    if (img) {
                        const alt = img.getAttribute('alt') || '';
                        const itemId = parseInt(alt.match(/\d+/)?.[0]) || 0;
                        if (itemId === 1187) {
                            hasStoneElements = true;
                            break;
                        }
                    }
                }
            }
            
            if (hasKeywords || hasEnchantElements || hasWorkshopElements || hasStoneElements || 
                window.enchantInterfaceOpen === true || window.workshopOpen === true) {
                window.workshopDetected = true;
            } else {
                window.workshopDetected = false;
            }
        } catch(e) {
            window.workshopDetected = false;
        }
    ]])
end

-- == Обработка событий == --
function sampev.onShowTextDraw(id, data)
    if data.text and (data.text:find('WORKSHOP') or data.text:find('МАСТЕРСКАЯ') or data.text:find('Мастерская') or data.text:find('ВЕРСТАК') or data.text:find('Верстак') or data.text:find('верстак')) then
        stone = {}
        workshop_check = true
    end
    
    if data.text and (data.text:find('ENCHANT') or data.text:find('ЗАТОЧКА') or data.text:find('Заточка')) then
        button_id = id - 1
    end
    
    if data.letterColor == -10398017 and data.lineWidth == 44 and data.lineHeight == 16 and data.position.x < 200 then
        button_id = id
    end
    
    if workshop_check then
        if stone_check then
            if data.lineWidth >= 1 then
                stone_check = false
            end
        end
        if data.modelId == Whetstone_ITEM_ID and data.selectable == 1 then
            table.insert(stone, {id})
        end
    end
end

-- Паттерны чата: заточка отслеживается ТОЛЬКО по тексту "с +X на +Y"
local PATTERN_FAIL       = u8:decode("Увы, вам не удалось улучшить предмет .- c %+([0-9]+) на %+([0-9]+)")
local PATTERN_FAIL_U8    = "Увы, вам не удалось улучшить предмет .- c %+([0-9]+) на %+([0-9]+)"
local PATTERN_SUCCESS    = u8:decode("Успех! Вам удалось улучшить предмет .- c %+([0-9]+) на %+([0-9]+)")
local PATTERN_SUCCESS_U8 = "Успех! Вам удалось улучшить предмет .- c %+([0-9]+) на %+([0-9]+)"

local function parseEnchantLevelsFromChat(text)
    local fromLvl, toLvl = text:match(PATTERN_SUCCESS)
    if not fromLvl then fromLvl, toLvl = text:match(PATTERN_SUCCESS_U8) end
    if fromLvl and toLvl then
        return true, tonumber(fromLvl), tonumber(toLvl)
    end

    fromLvl, toLvl = text:match(PATTERN_FAIL)
    if not fromLvl then fromLvl, toLvl = text:match(PATTERN_FAIL_U8) end
    if fromLvl and toLvl then
        return false, tonumber(fromLvl), tonumber(toLvl)
    end

    return nil, nil, nil
end

function sampev.onServerMessage(color, text)
    if max_toch > 0 and text and #text > 0 then
        local t = text:gsub("%{%x%x%x%x%x%x%}", "")  -- убрать коды цветов {FFFFFF} и т.д.

        local isSuccess, fromLvl, toLvl = parseEnchantLevelsFromChat(t)
        if isSuccess == nil then
            return
        end

        if not isSuccess then
            tochi = true
            all_lost = all_lost + 1
            lost_stone_onLVL = lost_stone_onLVL + 1
            return
        end

        if isSuccess and toLvl then
            playSuccessSound()
            lost_stone_onLVL = lost_stone_onLVL + 1
            all_lost = all_lost + 1
            table.insert(lost_stone, {lost_stone_onLVL, toLvl})
            lost_stone_onLVL = 0

            local target = tonumber(max_toch) or 0
            -- Останавливаемся только на точном успешном переходе c +(target-1) на +target.
            -- Например для "точить до +12" — только после текста "c +11 на +12".
            if toLvl == target and fromLvl == (target - 1) then
                tochi = false
                max_toch = 0
                stone_check = false
                status = false
                sampAddChatMessage(u8:decode("У вас заточился предмет до указаной вами заточки, выбери другой предмет или другой уровень"), -1)
            else
                tochi = true
            end
        end
    end
end

function imgui.ColoredButton(text, size, hex, trans)
    local r,g,b = tonumber("0x"..hex:sub(1,2)), tonumber("0x"..hex:sub(3,4)), tonumber("0x"..hex:sub(5,6))
    local a
    if tonumber(trans) ~= nil and tonumber(trans) < 101 and tonumber(trans) > 0 then
        a = trans
    else a = 60 end
    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(r/255, g/255, b/255, a/100))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(r/255, g/255, b/255, a/100))
    imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(r/255, g/255, b/255, a/100))
    local button = imgui.Button(text, size)
    imgui.PopStyleColor(3)
    return button
end

function imgui.ColSeparator(hex, trans)
    local r,g,b = tonumber("0x"..hex:sub(1,2)), tonumber("0x"..hex:sub(3,4)), tonumber("0x"..hex:sub(5,6))
    local a
    if tonumber(trans) ~= nil and tonumber(trans) < 101 and tonumber(trans) > 0 then
        a = trans
    else a = 100 end
    imgui.PushStyleColor(imgui.Col.Separator, imgui.ImVec4(r/255, g/255, b/255, a/100))
    local colsep = imgui.Separator()
    imgui.PopStyleColor(1)
    return colsep
end

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    theme()
end)

function theme()
    imgui.SwitchContext()
    local ImVec4 = imgui.ImVec4
    -- Матовый чёрный
    imgui.GetStyle().WindowPadding = imgui.ImVec2(8, 8)
    imgui.GetStyle().FramePadding = imgui.ImVec2(6, 4)
    imgui.GetStyle().ItemSpacing = imgui.ImVec2(6, 6)
    imgui.GetStyle().ItemInnerSpacing = imgui.ImVec2(4, 2)
    imgui.GetStyle().TouchExtraPadding = imgui.ImVec2(0, 0)
    imgui.GetStyle().IndentSpacing = 12
    imgui.GetStyle().ScrollbarSize = 10
    imgui.GetStyle().GrabMinSize = 10
    imgui.GetStyle().WindowBorderSize = 1
    imgui.GetStyle().ChildBorderSize = 1
    imgui.GetStyle().PopupBorderSize = 1
    imgui.GetStyle().FrameBorderSize = 1
    imgui.GetStyle().TabBorderSize = 1
    imgui.GetStyle().WindowRounding = 8
    imgui.GetStyle().ChildRounding = 6
    imgui.GetStyle().FrameRounding = 6
    imgui.GetStyle().PopupRounding = 8
    imgui.GetStyle().ScrollbarRounding = 4
    imgui.GetStyle().GrabRounding = 4
    imgui.GetStyle().TabRounding = 6

    -- Матовый чёрный: тёмные фоны без блеска, светлый текст
    imgui.GetStyle().Colors[imgui.Col.Text]                   = ImVec4(0.92, 0.92, 0.94, 1.00)
    imgui.GetStyle().Colors[imgui.Col.TextDisabled]           = ImVec4(0.45, 0.45, 0.48, 1.00)
    imgui.GetStyle().Colors[imgui.Col.WindowBg]               = ImVec4(0.09, 0.09, 0.10, 0.98)
    imgui.GetStyle().Colors[imgui.Col.ChildBg]                = ImVec4(0.11, 0.11, 0.12, 0.98)
    imgui.GetStyle().Colors[imgui.Col.PopupBg]                = ImVec4(0.10, 0.10, 0.11, 0.98)
    imgui.GetStyle().Colors[imgui.Col.Border]                 = ImVec4(0.22, 0.22, 0.24, 1.00)
    imgui.GetStyle().Colors[imgui.Col.BorderShadow]           = ImVec4(0.00, 0.00, 0.00, 0.00)
    imgui.GetStyle().Colors[imgui.Col.FrameBg]                = ImVec4(0.14, 0.14, 0.16, 1.00)
    imgui.GetStyle().Colors[imgui.Col.FrameBgHovered]         = ImVec4(0.18, 0.18, 0.20, 1.00)
    imgui.GetStyle().Colors[imgui.Col.FrameBgActive]          = ImVec4(0.20, 0.20, 0.22, 1.00)
    imgui.GetStyle().Colors[imgui.Col.TitleBg]                = ImVec4(0.08, 0.08, 0.09, 1.00)
    imgui.GetStyle().Colors[imgui.Col.TitleBgActive]          = ImVec4(0.10, 0.10, 0.11, 1.00)
    imgui.GetStyle().Colors[imgui.Col.TitleBgCollapsed]       = ImVec4(0.08, 0.08, 0.09, 0.75)
    imgui.GetStyle().Colors[imgui.Col.MenuBarBg]             = ImVec4(0.11, 0.11, 0.12, 1.00)
    imgui.GetStyle().Colors[imgui.Col.ScrollbarBg]            = ImVec4(0.08, 0.08, 0.09, 0.90)
    imgui.GetStyle().Colors[imgui.Col.ScrollbarGrab]          = ImVec4(0.28, 0.28, 0.30, 1.00)
    imgui.GetStyle().Colors[imgui.Col.ScrollbarGrabHovered]   = ImVec4(0.35, 0.35, 0.38, 1.00)
    imgui.GetStyle().Colors[imgui.Col.ScrollbarGrabActive]    = ImVec4(0.42, 0.42, 0.45, 1.00)
    imgui.GetStyle().Colors[imgui.Col.CheckMark]              = ImVec4(0.75, 0.75, 0.78, 1.00)
    imgui.GetStyle().Colors[imgui.Col.SliderGrab]             = ImVec4(0.32, 0.32, 0.35, 1.00)
    imgui.GetStyle().Colors[imgui.Col.SliderGrabActive]       = ImVec4(0.40, 0.40, 0.44, 1.00)
    imgui.GetStyle().Colors[imgui.Col.Button]                 = ImVec4(0.18, 0.18, 0.20, 1.00)
    imgui.GetStyle().Colors[imgui.Col.ButtonHovered]          = ImVec4(0.24, 0.24, 0.26, 1.00)
    imgui.GetStyle().Colors[imgui.Col.ButtonActive]           = ImVec4(0.28, 0.28, 0.30, 1.00)
    imgui.GetStyle().Colors[imgui.Col.Header]                 = ImVec4(0.16, 0.16, 0.18, 1.00)
    imgui.GetStyle().Colors[imgui.Col.HeaderHovered]          = ImVec4(0.22, 0.22, 0.24, 1.00)
    imgui.GetStyle().Colors[imgui.Col.HeaderActive]           = ImVec4(0.26, 0.26, 0.28, 1.00)
    imgui.GetStyle().Colors[imgui.Col.Separator]              = ImVec4(0.24, 0.24, 0.26, 1.00)
    imgui.GetStyle().Colors[imgui.Col.SeparatorHovered]       = ImVec4(0.38, 0.38, 0.40, 1.00)
    imgui.GetStyle().Colors[imgui.Col.SeparatorActive]        = ImVec4(0.48, 0.48, 0.50, 1.00)
    imgui.GetStyle().Colors[imgui.Col.ResizeGrip]             = ImVec4(0.20, 0.20, 0.22, 0.80)
    imgui.GetStyle().Colors[imgui.Col.ResizeGripHovered]      = ImVec4(0.28, 0.28, 0.30, 1.00)
    imgui.GetStyle().Colors[imgui.Col.ResizeGripActive]       = ImVec4(0.34, 0.34, 0.36, 1.00)
    imgui.GetStyle().Colors[imgui.Col.Tab]                    = ImVec4(0.16, 0.16, 0.18, 1.00)
    imgui.GetStyle().Colors[imgui.Col.TabHovered]             = ImVec4(0.24, 0.24, 0.26, 1.00)
    imgui.GetStyle().Colors[imgui.Col.TabActive]              = ImVec4(0.20, 0.20, 0.22, 1.00)
    imgui.GetStyle().Colors[imgui.Col.TabUnfocused]          = ImVec4(0.12, 0.12, 0.14, 1.00)
    imgui.GetStyle().Colors[imgui.Col.TabUnfocusedActive]     = ImVec4(0.18, 0.18, 0.20, 1.00)
    imgui.GetStyle().Colors[imgui.Col.PlotLines]              = ImVec4(0.50, 0.50, 0.54, 1.00)
    imgui.GetStyle().Colors[imgui.Col.PlotLinesHovered]       = ImVec4(0.65, 0.65, 0.70, 1.00)
    imgui.GetStyle().Colors[imgui.Col.PlotHistogram]          = ImVec4(0.38, 0.38, 0.42, 1.00)
    imgui.GetStyle().Colors[imgui.Col.PlotHistogramHovered]   = ImVec4(0.48, 0.48, 0.52, 1.00)
    imgui.GetStyle().Colors[imgui.Col.TextSelectedBg]         = ImVec4(0.28, 0.28, 0.32, 0.85)
end
