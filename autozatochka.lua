--[[
    Автозаточка Arizona через CEF. Окно как было (/mt).
    RPC только копирует строки/числа, клики и звук — в main (как ABarz).
]]
script_name('autozatochka.lua')
script_version('v1.02')
script_author('Auto')
script_description('Автоматическая заточка через CEF интерфейс')

local ok_ev, sampev = pcall(require, 'lib.samp.events')
if not ok_ev then ok_ev, sampev = pcall(require, 'samp.events') end
if not ok_ev then sampev = nil end
local ok_imgui, imgui = pcall(require, 'mimgui')
if not ok_imgui then
    function main()
        while not isSampAvailable() do wait(100) end
        sampAddChatMessage('[AutoZatochka] Нужен mimgui', -1)
    end
    return
end
local ok_cef, cefDlg = pcall(require, 'arizona-cef-dialogs')
if not ok_cef then cefDlg = nil end
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local new = imgui.new

-- Arizona CEF: подключается в main() после проверки файлов (см. bootstrap библиотек)
local arizona = nil

-- == Settings == --
local WinState, playSound, SetWin = new.bool(), new.bool(), new.bool()
local status = false
local max_toch = 0
local button_id = 0

-- Звук при успешной заточке (скачивается с GitHub / CDN)
local GITHUB_RAW_BASE = 'https://github.com/andergr0ynd/zvyk/raw/refs/heads/main/'
local GITHUB_CDN_BASE = 'https://cdn.jsdelivr.net/gh/andergr0ynd/zvyk@main/'
local RAW_GH_BASE = 'https://raw.githubusercontent.com/andergr0ynd/zvyk/refs/heads/main/'
local SOUND_URL = GITHUB_RAW_BASE .. 'applepay.mp3'
local SOUND_FILENAME = 'applepay.mp3'
local SOUND_SUBDIR = 'autozatochka'
local PENDING_CHANGELOG_FILE = 'pending_changelog.txt'
local success_sound_stream = nil

-- Текст для окна после обновления: сначала качается changelog.txt с GitHub, иначе запасной текст
local VERSION_JSON_URL = GITHUB_RAW_BASE .. 'version.json'
local SCRIPT_UPDATE_URL = GITHUB_RAW_BASE .. 'autozatochka.lua'
local CHANGELOG_TXT_URL = GITHUB_RAW_BASE .. 'changelog.txt'
local changelog_after_update = ''

local function ensureDirForFile(path)
    local dir = path:match('^(.*\\)[^\\]+$')
    if dir and not doesDirectoryExist(dir) then
        createDirectory(dir)
    end
end

local function readFileHead(path, n)
    local f = io.open(path, 'rb')
    if not f then return '' end
    local s = f:read(n or 64) or ''
    f:close()
    return s
end

local function contentLooksLikeHtml(data)
    if not data or #data == 0 then return true end
    local head = data:sub(1, 64):lower()
    return head:find('^<!doctype') ~= nil or head:find('^<html') ~= nil
end

local function writeBinaryFile(path, data)
    if not data or #data == 0 then return false end
    ensureDirForFile(path)
    local f = io.open(path, 'wb')
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

-- MoonLoader downloadUrlToFile + fallback через lib/requests (luasocket)
local function downloadViaRequests(url, path, timeout_sec)
    local ok_req, requests = pcall(require, 'requests')
    if not ok_req or not requests or not requests.get then return false end
    local bust = url .. (url:find('?', 1, true) and '&' or '?') .. 't=' .. tostring(os.clock())
    local ok, resp = pcall(requests.get, bust, {
        timeout = timeout_sec or 30,
        allow_redirects = true,
        headers = { ['User-Agent'] = 'MoonLoader-AutoZatochka/6.20' },
    })
    if not ok or not resp or not resp.text or #resp.text == 0 then return false end
    if resp.status_code and resp.status_code >= 400 then return false end
    if contentLooksLikeHtml(resp.text) then return false end
    return writeBinaryFile(path, resp.text)
end

local function downloadViaMoonLoader(url, path, timeout_sec)
    if type(downloadUrlToFile) ~= 'function' then return false end
    local ml_ok, ml = pcall(require, 'moonloader')
    if not ml_ok or not ml or not ml.download_status then return false end
    local d = ml.download_status
    local bust = url .. (url:find('?', 1, true) and '&' or '?') .. 't=' .. tostring(os.clock())
    local done, success = false, false
    downloadUrlToFile(bust, path, function(_, status)
        if status == d.STATUSEX_ENDDOWNLOAD or status == d.STATUS_ENDDOWNLOADDATA then
            done = true
            success = true
        end
    end)
    local t0 = os.clock()
    while not done and os.clock() - t0 < (timeout_sec or 45) do wait(50) end
    if not success or not doesFileExist(path) then return false end
    wait(200)
    return not contentLooksLikeHtml(readFileHead(path, 128))
end

local function downloadToFile(url, path, timeout_sec)
    ensureDirForFile(path)
    if doesFileExist(path) then
        pcall(os.remove, path)
    end
    if downloadViaMoonLoader(url, path, timeout_sec) then return true end
    if doesFileExist(path) then
        pcall(os.remove, path)
    end
    if downloadViaRequests(url, path, timeout_sec) then return true end
    return false
end

-- Пробует несколько зеркал (jsDelivr часто доступен, когда github.com заблокирован)
local function downloadToFileMirrors(urls, path, timeout_sec)
    for _, url in ipairs(urls) do
        if downloadToFile(url, path, timeout_sec) then
            return true, url
        end
    end
    return false, nil
end

local function mirrorUrlsFor(relative_path)
    return {
        GITHUB_CDN_BASE .. relative_path,
        RAW_GH_BASE .. relative_path,
        GITHUB_RAW_BASE .. relative_path,
    }
end

local function scriptFileLooksLikeLua(path)
    local fh = io.open(path, 'rb')
    if not fh then return false end
    local s = fh:read('*a') or ''
    fh:close()
    if #s < 80 then return false end
    if contentLooksLikeHtml(s) then return false end
    return s:find('function') ~= nil or s:find('script_name') ~= nil or s:find('require') ~= nil
end

-- Если в version.json битый updateurl (как .../autozatochka.lua) — берём SCRIPT_UPDATE_URL
local function resolveScriptUpdateUrl(meta)
    local url = meta and meta.updateurl
    if type(url) == 'string' and #url > 12 and url:find('^https?://') and url:find('%.lua') then
        if not url:find('%.%.%.') then
            return url
        end
    end
    return SCRIPT_UPDATE_URL
end

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
    -- mimgui/ImGui ждёт UTF-8 (как imgui.Text в главном окне). u8:decode даёт CP1251 → «????».
    if #s >= 3 and s:byte(1) == 0xEF and s:byte(2) == 0xBB and s:byte(3) == 0xBF then
        s = s:sub(4)
    end
    changelog_after_update = s
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

local function downloadRemoteChangelogOrWriteFallback(fallback_text)
    local dir = getWorkingDirectory() .. '\\' .. SOUND_SUBDIR
    if not doesDirectoryExist(dir) then
        createDirectory(dir)
    end
    local path = pendingChangelogPath()
    if downloadToFileMirrors(mirrorUrlsFor('changelog.txt'), path, 22) and pendingChangelogDownloadUsable(path) then
        return
    end
    writePendingChangelog(fallback_text)
end

local as_action = require('moonloader').audiostream_state

-- Автообновление скрипта с GitHub (как в Cerberus.lua, с проверкой на nil)
-- version.json: latest, updateurl; опционально changelog — запас, если changelog.txt пустой/недоступен
if not decodeJson then
    local ok, j = pcall(require, 'json')
    if ok and j and j.decode then decodeJson = j.decode end
end

local function safeDecodeJson(raw)
    if type(raw) ~= 'string' then return false, nil end
    local s = raw:gsub('^%s+', ''):gsub('%s+$', '')
    if s == '' or s == 'null' then return false, nil end
    local first = s:sub(1, 1)
    if first ~= '{' and first ~= '[' then return false, nil end
    if first == '[' and s:match('^%[%s*%]') then return true, {} end
    local ok, data = pcall(decodeJson, s)
    if not ok or data == nil then return false, nil end
    return true, data
end

local incomingCef, incomingChat, incomingTd = {}, {}, {}
local function queueCef(str)
    if type(str) ~= 'string' or str == '' then return end
    incomingCef[#incomingCef + 1] = str .. ''
    if #incomingCef > 40 then table.remove(incomingCef, 1) end
end
local function queueChat(text)
    if type(text) ~= 'string' or text == '' then return end
    incomingChat[#incomingChat + 1] = text .. ''
    if #incomingChat > 40 then table.remove(incomingChat, 1) end
end
local function queueTd(item)
    if type(item) ~= 'table' then return end
    incomingTd[#incomingTd + 1] = item
    if #incomingTd > 80 then table.remove(incomingTd, 1) end
end
-- false: без авто-проверки при входе (нет зацикливания); кнопка «Проверить обновления» всегда вызывает Update.check
local enable_autoupdate = false
local autoupdate_loaded = false
local Update = nil

-- v6.9 и 6.9 считаем одной версией; обновление только если удалённая версия численно новее (а не просто строка ~=)
local function scriptVersionForCompare(ver)
    if ver == nil then return '' end
    local s = tostring(ver):lower():gsub('^%s+', ''):gsub('%s+$', '')
    if s:sub(1, 1) == 'v' then
        s = s:sub(2)
    end
    return s
end

local function versionNumericTuple(ver)
    local s = scriptVersionForCompare(ver)
    local t = {}
    for n in s:gmatch('%d+') do
        t[#t + 1] = tonumber(n) or 0
    end
    if #t == 0 then return nil end
    return t
end

--- @return -1 если a старше b, 0 если равны, 1 если a новее b; nil если не удалось разобрать
local function compareSemanticVersions(a, b)
    local ta, tb = versionNumericTuple(a), versionNumericTuple(b)
    if not ta or not tb then return nil end
    local n = math.max(#ta, #tb)
    for i = 1, n do
        local x, y = ta[i] or 0, tb[i] or 0
        if x < y then return -1 end
        if x > y then return 1 end
    end
    return 0
end

local function remoteIsNewerThanLocal(localVer, remoteVer)
    local cmp = compareSemanticVersions(localVer, remoteVer)
    if cmp ~= nil then
        return cmp < 0
    end
    return false
end

if decodeJson then
    Update = {
        json_url = VERSION_JSON_URL,
        prefix = "[AutoZatochka]: ",
        url = "https://github.com/andergr0ynd/zvyk",
        check = function(json_url_base, prefix, url)
            prefix = prefix or ""
            json_url_base = json_url_base or Update.json_url
            local tmp = os.tmpname()
            if doesFileExist(tmp) then pcall(os.remove, tmp) end
            if not downloadToFileMirrors(mirrorUrlsFor('version.json'), tmp, 25) then
                print(u8:decode('v' .. thisScript().version .. ': Не удалось скачать version.json. ' .. tostring(json_url_base)))
                return
            end
            local f = io.open(tmp, 'rb')
            if not f then
                print(u8:decode('v' .. thisScript().version .. ': Не могу прочитать version.json.'))
                return
            end
            local raw = f:read('*a')
            f:close()
            pcall(os.remove, tmp)
            local okj, l = safeDecodeJson(raw or '')
            if not okj or type(l) ~= 'table' or not l.latest then
                print(u8:decode('v' .. thisScript().version .. ': Неверный version.json или он отсутствует в репозитории.'))
                return
            end
            local cur = thisScript().version
            if scriptVersionForCompare(l.latest) == '' or not remoteIsNewerThanLocal(cur, l.latest) then
                print(u8:decode('v' .. thisScript().version .. ': Обновление не требуется.'))
                return
            end
            local updateUrl = resolveScriptUpdateUrl(l)
            lua_thread.create(function()
                local m = -1
                sampAddChatMessage(prefix .. u8:decode("Обнаружено обновление. Пытаюсь обновиться c " .. tostring(cur) .. " на " .. tostring(l.latest)), m)
                wait(250)
                local scriptPath = thisScript().path
                local scriptUrls = mirrorUrlsFor('autozatochka.lua')
                if updateUrl and updateUrl ~= scriptUrls[1] and updateUrl ~= scriptUrls[2] and updateUrl ~= scriptUrls[3] then
                    table.insert(scriptUrls, 1, updateUrl)
                end
                local ok = downloadToFileMirrors(scriptUrls, scriptPath, 60)
                if ok and scriptFileLooksLikeLua(scriptPath) then
                    print('Загрузка обновления завершена.')
                    sampAddChatMessage(prefix .. u8:decode("Обновление завершено!"), m)
                    local ch = l.changelog or l.changes or l.notes
                    local fallback
                    if type(ch) == 'string' and #ch > 0 then
                        fallback = ch
                    else
                        fallback = 'Скрипт обновлён до версии ' .. tostring(l.latest)
                            .. '.\n\nСписок изменений: changelog.txt в репозитории zvyk.'
                    end
                    wait(350)
                    downloadRemoteChangelogOrWriteFallback(fallback)
                    wait(150)
                    thisScript():reload()
                else
                    sampAddChatMessage(prefix .. u8:decode("Обновление прошло неудачно. Запускаю устаревшую версию.."), m)
                    print('[AutoZatochka] updateurl: ' .. tostring(updateUrl))
                end
            end)
        end
    }
    autoupdate_loaded = true
end

-- Синхронизация lib/arizona-events с GitHub → moonloader\lib\arizona-events
-- Источник на GitHub: zvyk/arizona-events/*.lua (raw). На диск: moonloader\lib\arizona-events\
-- Если файлов нет или они битые — скрипт качает, перезагружается, затем продолжает работу.
local LIB_ARIZONA_EVENTS_DIR = 'lib\\arizona-events'
local LIB_ARIZONA_EVENTS_FILES = { 'init.lua', 'core.lua', 'bitstream.lua', 'subprocess.lua' }

local function libFileLooksBad(path)
    local f = io.open(path, 'rb')
    if not f then return true end
    local s = f:read('*a') or ''
    f:close()
    if #s < 32 then return true end
    return contentLooksLikeHtml(s)
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
    local _, dir = arizonaEventsLibPaths()
    local all_ok = true
    for _, name in ipairs(LIB_ARIZONA_EVENTS_FILES) do
        local path = dir .. '\\' .. name
        local need = force_all or not doesFileExist(path) or libFileLooksBad(path)
        if need then
            local rel = 'arizona-events/' .. name
            local ok, usedUrl = downloadToFileMirrors(mirrorUrlsFor(rel), path, 45)
            if ok and not libFileLooksBad(path) then
                print('[AutoZatochka] ' .. u8:decode('Библиотека сохранена: ') .. LIB_ARIZONA_EVENTS_DIR .. '\\' .. name)
            else
                all_ok = false
                if doesFileExist(path) then pcall(os.remove, path) end
                print('[AutoZatochka] ' .. u8:decode('Не удалось скачать: ') .. name .. ' (' .. tostring(usedUrl or rel) .. ')')
            end
        end
    end
    return all_ok and arizonaEventsLibPresent()
end

-- Stone
local tochi, workshop_check, stone_check = false, false, false
local lost_stone_onLVL, all_lost = 0, 0
local stone = {}
local lost_stone = {}
local enchantSlotsData = { index = -1, left = -1, right = -1, color = -1 }
local ws = {
    chance = -1,
    cost = -1,
    available = 0,
    busy = false,
    busyAt = 0,
    pendingResult = nil,
    stoneSlot = -1,
    stoneAmount = 0,
    stoneSlots = {},
    itemSlot = -1,
    itemId = -1,
    itemEnchant = -1,
    leftNeed = 0,
    rightNeed = 1,
    lastPlaceAt = 0,
    lastPlaceJson = '',
    tab = 0,
    gunCtx = false,
    resSlot = -1,
    resAmount = 0,
    leftOn = false,
    rightOn = false,
    gAll = 0,
    gLvl = 0,
    gRows = {},
    slots1187 = {},
    slots10253 = {},
    slots511 = {},
}

-- Лог верстака: moonloader\config\autozatochka\workshop.log  (команда /mtlog)
local wz = {
    enabled = true,
    path = nil,
    n = 0,
    lastState = '',
    needDump = false,
    lastDump = 0,
    miss = {},
    outQ = {},
    needleZ = u8:decode('заточ'),
    needleW = u8:decode('верстак'),
    needleS = u8:decode('точил'),
    jsDump = [[
        try {
            var out = [];
            out.push('href=' + String(location.href || ''));
            out.push('title=' + String(document.title || ''));
            var body = (document.body && (document.body.innerText || document.body.textContent) || '');
            out.push('body=' + String(body).replace(/\s+/g, ' ').slice(0, 500));
            var nodes = document.querySelectorAll('[class*="enchant"],[class*="Enchant"],[class*="workshop"],[class*="Workshop"],[class*="slot"],button,[role="button"],[class*="inventory"]');
            out.push('nodes=' + nodes.length);
            var i, n, shown = 0;
            for (i = 0; i < nodes.length && shown < 45; i++) {
                n = nodes[i];
                var r = n.getBoundingClientRect();
                if (r.width < 2 && r.height < 2) continue;
                shown++;
                out.push('N' + shown + ' tag=' + n.tagName
                    + ' cls=' + String(n.className || '').toString().slice(0, 90)
                    + ' id=' + String(n.id || '')
                    + ' txt=' + String(n.innerText || '').replace(/\s+/g, ' ').slice(0, 70)
                    + ' wh=' + Math.round(r.width) + 'x' + Math.round(r.height)
                    + ' slot=' + String(n.getAttribute('data-slot') || n.getAttribute('data-index') || ''));
            }
            var imgs = document.querySelectorAll('img');
            var c1187 = 0;
            for (i = 0; i < imgs.length; i++) {
                var a = (imgs[i].getAttribute('alt') || '') + ' ' + (imgs[i].getAttribute('src') || '');
                if (a.indexOf('1187') === -1) continue;
                c1187++;
                var it = imgs[i].closest('[data-slot], .inventory-item-hoc, [class*="item"]');
                out.push('img1187 alt=' + String(imgs[i].getAttribute('alt') || '')
                    + ' slot=' + String((it && (it.getAttribute('data-slot') || it.getAttribute('data-index'))) || '?'));
            }
            out.push('count1187=' + c1187);
            out.push('stoneSlot=' + String(window.stoneSlotNumber));
            out.push('enchantSlot=' + String(window.enchantSlotNumber));
            out.push('workshopOpen=' + String(window.workshopOpen));
            out.push('workshopDetected=' + String(window.workshopDetected));
            window.__azDump = out.join('\n');
        } catch (e) {
            window.__azDump = 'err ' + e;
        }
    ]],
}
function wz.clip(s, n)
    s = tostring(s or ''):gsub('[\r\n]+', ' | '):gsub('%z', '')
    n = n or 1000
    if #s > n then return s:sub(1, n) .. '...[' .. #s .. 'b]' end
    return s
end
function wz.ensure()
    if wz.path then return end
    local root = ''
    pcall(function() root = getWorkingDirectory() or '' end)
    if root == '' then
        pcall(function()
            local p = thisScript().path or ''
            root = p:match('^(.*\\)') or ''
        end)
    end
    local dir = (root .. '\\config\\autozatochka'):gsub('\\\\+', '\\')
    if not doesDirectoryExist(dir) then createDirectory(dir) end
    wz.path = dir .. '\\workshop.log'
end
function wz.write(tag, msg)
    if not wz.enabled then return end
    pcall(function()
        wz.ensure()
        wz.n = (wz.n or 0) + 1
        if wz.n % 40 == 1 then
            local fh = io.open(wz.path, 'rb')
            if fh then
                local sz = fh:seek('end')
                fh:close()
                if sz and sz > 1800000 then
                    pcall(os.remove, wz.path .. '.old')
                    pcall(os.rename, wz.path, wz.path .. '.old')
                end
            end
        end
        local line = os.date('%H:%M:%S') .. ' #' .. wz.n .. ' [' .. tostring(tag) .. '] ' .. wz.clip(msg, 2500) .. '\n'
        local f = io.open(wz.path, 'a+')
        if not f then return end
        f:write(line)
        f:close()
        print('[AZ] ' .. line:gsub('\n', ''))
    end)
end
function wz.hot(s)
    if type(s) ~= 'string' or s == '' then return false end
    local l = s:lower()
    if l:find('enchant', 1, true) or l:find('workshop', 1, true) or l:find('1187', 1, true) then return true end
    if l:find('moveitem', 1, true) or l:find('clickon', 1, true) or l:find('startenchant', 1, true) then return true end
    if l:find('rightclick', 1, true) or l:find('leftclick', 1, true) then return true end
    if l:find('startcraft', 1, true) or l:find('resourceNeed', 1, true) then return true end
    if l:find('updatecategory', 1, true) or l:find('10253', 1, true) or l:find('guncontext', 1, true) then return true end
    if s:find(wz.needleZ, 1, true) or s:find(wz.needleW, 1, true) or s:find(wz.needleS, 1, true) then return true end
    return false
end
function wz.state()
    return 'status=' .. tostring(status)
        .. ' tochi=' .. tostring(tochi)
        .. ' ws=' .. tostring(workshop_check)
        .. ' max=' .. tostring(max_toch)
        .. ' av=' .. tostring(ws.available)
        .. ' chance=' .. tostring(ws.chance)
        .. ' busy=' .. tostring(ws.busy)
        .. ' ench=' .. tostring(ws.itemEnchant)
        .. ' item=' .. tostring(ws.itemId)
        .. ' idx=' .. tostring(enchantSlotsData.index)
        .. ' left=' .. tostring(enchantSlotsData.left)
        .. ' right=' .. tostring(enchantSlotsData.right)
        .. ' color=' .. tostring(enchantSlotsData.color)
        .. ' stoneSlot=' .. tostring(ws.stoneSlot)
        .. ' stoneN=' .. tostring(ws.stoneAmount)
        .. ' tab=' .. tostring(ws.tab)
        .. ' res=' .. tostring(ws.resSlot)
        .. ' resN=' .. tostring(ws.resAmount)
        .. ' needL=' .. tostring(ws.leftNeed)
        .. ' needR=' .. tostring(ws.rightNeed)
end
function wz.eventOf(str)
    local ev, payload = str:match("window%.executeEvent%(%s*'([^']+)'%s*,%s*`([^`]*)`")
    if ev then return ev, payload end
    return str:match("window%.executeEvent%(%s*'([^']+)'%s*,%s*'([^']*)'")
end
function wz.queueSend(s)
    if type(s) ~= 'string' or s == '' then return end
    wz.outQ = wz.outQ or {}
    wz.outQ[#wz.outQ + 1] = s .. ''
    if #wz.outQ > 80 then table.remove(wz.outQ, 1) end
end
function wz.pumpOut()
    local q = wz.outQ
    if not q or #q == 0 then return end
    wz.outQ = {}
    for i = 1, #q do
        local s = q[i]
        pcall(ws.handleSend, s)
        if s == wz.lastSendLine then
            wz.lastSendN = (wz.lastSendN or 1) + 1
        else
            if (wz.lastSendN or 0) > 1 then
                wz.write('SEND', 'repeat x' .. tostring(wz.lastSendN))
            end
            wz.write('SEND', s)
            wz.lastSendLine = s
            wz.lastSendN = 1
        end
    end
end
function wz.flushState()
    local s = wz.state()
    if s ~= wz.lastState then
        wz.lastState = s
        wz.write('STATE', s)
    end
end
function wz.cef(str)
    if type(str) ~= 'string' or str == '' then return end
    local cmd = str:match('^([^|]+)') or 'cef'
    local hot = wz.hot(str)
    if not hot and not workshop_check and not status then
        wz.miss[cmd] = (wz.miss[cmd] or 0) + 1
        return
    end
    wz.write('CEF', str)
end
function wz.askDump()
    local now = os.clock()
    if wz.lastDump and (now - wz.lastDump) < 8 then return end
    wz.needDump = true
end

-- ID точильного камня: [1187] = "Точильный камень"
local Whetstone_ITEM_ID = 1187
local GUN_STONE_ID = 10253
local GUN_RES_ID = 511

local function soundFileLooksBad(path)
    if not doesFileExist(path) then return true end
    local f = io.open(path, 'rb')
    if not f then return true end
    local s = f:read('*a') or ''
    f:close()
    if #s < 512 then return true end
    return contentLooksLikeHtml(s)
end

local function initSuccessSound()
    local dir = getWorkingDirectory() .. '\\' .. SOUND_SUBDIR
    if not doesDirectoryExist(dir) then
        createDirectory(dir)
    end
    local path = dir .. '\\' .. SOUND_FILENAME
    local function tryLoadStream()
        if doesFileExist(path) and not success_sound_stream and not soundFileLooksBad(path) then
            success_sound_stream = loadAudioStream(path)
        end
    end
    if doesFileExist(path) and not soundFileLooksBad(path) then
        tryLoadStream()
        return
    end
    if doesFileExist(path) then pcall(os.remove, path) end
    if downloadToFileMirrors(mirrorUrlsFor('applepay.mp3'), path, 45) and not soundFileLooksBad(path) then
        tryLoadStream()
    else
        if doesFileExist(path) then pcall(os.remove, path) end
        print('[AutoZatochka] ' .. u8:decode('Не удалось скачать звук (пробовали CDN и GitHub).'))
    end
end

-- Воспроизведение звука успешной заточки
local function playSuccessSound()
    if not playSound[0] then return end
    local path = getWorkingDirectory() .. '\\' .. SOUND_SUBDIR .. '\\' .. SOUND_FILENAME
    if not success_sound_stream then
        if doesFileExist(path) and not soundFileLooksBad(path) then
            success_sound_stream = loadAudioStream(path)
        else
            lua_thread.create(initSuccessSound)
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
    code = tostring(code or '')
    if arizona and arizona.eval then
        pcall(arizona.eval, code, 0)
        return
    end
    evalcef('(() => {' .. code .. '})()')
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

-- Чтение значения из CEF (работает, если arizona.eval возвращает результат)
local function evalcefReturn(code)
    if arizona and arizona.eval then
        local ok, result = pcall(arizona.eval, code, 0)
        if ok then return result end
    end
    evalcef(code, 0)
    return nil
end

-- == Функции отправки CEF команд == --
function sendCEF(str)
    wz.write('OUT', str)
    if arizona and arizona.send then
        local ok = pcall(arizona.send, 'onArizonaSend', { text = str, server_id = 0 })
        if ok then return end
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
    local slotNum = evalcefReturn('return (typeof window.stoneSlotNumber !== "undefined" && window.stoneSlotNumber >= 0) ? window.stoneSlotNumber : -1;')
    local n = (type(slotNum) == 'number' and slotNum >= 0) and slotNum or (tonumber(slotNum) or -1)
    wz.write('SLOT', 'stone=' .. tostring(n) .. ' raw=' .. tostring(slotNum))
    return n
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
    local slotNum = evalcefReturn('return window.enchantSlotNumber !== undefined ? window.enchantSlotNumber : -1;')
    local n = (type(slotNum) == 'number' and slotNum >= 0) and slotNum or (tonumber(slotNum) or -1)
    wz.write('SLOT', 'enchant=' .. tostring(n) .. ' raw=' .. tostring(slotNum))
    return n
end

function findAndClickStone()
    wz.write('CLICK', 'findAndClickStone ' .. wz.state())
    local stoneSlotNum = findStoneSlotNumber()
    wz.write('CLICK', 'findAndClickStone stoneSlot=' .. tostring(stoneSlotNum) .. ' left=' .. tostring(enchantSlotsData.left) .. ' idx=' .. tostring(enchantSlotsData.index))
    
    if stoneSlotNum >= 0 then
        if enchantSlotsData.left == -1 then
            local enchantSlot = enchantSlotsData.index >= 0 and enchantSlotsData.index or findEnchantSlotNumber()
            
            -- 1) Как в ArzMarket: moveItem из слота камня в слот заточки (type 1 = инвентарь)
            if enchantSlot >= 0 then
                wz.write('CLICK', 'moveItem stone=' .. tostring(stoneSlotNum) .. ' -> enchant=' .. tostring(enchantSlot))
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
            
            -- Метод 3: специальные номера слотов для слота заточки
            for _, specialSlot in ipairs({-1, -2, -3, 0, 1, 2, 100, 200, 1000, 2000}) do
                for _, toType in ipairs({1, 2, 3}) do
                    moveItem(stoneSlotNum, 1, specialSlot, toType, 1)
                    wait(200)
                end
            end
            
            -- Fallback: rightClickOnBlock — «взять» камень в руку
            rightClickOnBlock(stoneSlotNum, 1)
            wait(800)
            
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
            
            -- Метод 3.5: moveItem без rightClickOnBlock
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
            const buttonTexts = ['ENCHANT', 'ЗАТОЧКА', 'Заточить', 'Улучшить', 'ENHANCE', 'Заточка', 'заточка', 'ЗАТОЧИТЬ', 'START', 'НАЧАТЬ', 'ПРОДОЛЖИТЬ', 'УЛУЧШИТЬ'];
            const selectors = [
                '.enchant-main__button',
                '.enchant-main__start',
                '[class*="enchant"][class*="button"]',
                '[class*="enchant"][class*="start"]',
                '[class*="workshop"] button',
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
function ws.clickEnchantBtn()
    local code = [[
        var needles = ['\u0417\u0430\u0442\u043e\u0447\u0438\u0442\u044c', 'ENCHANT'];
        var nodes = document.querySelectorAll('button, [role="button"], [class*="button"], [class*="btn"], div, span');
        var i, j;
        for (i = 0; i < nodes.length; i++) {
            var n = nodes[i];
            var r = n.getBoundingClientRect();
            if (r.width < 8 || r.height < 8) continue;
            var t = String(n.innerText || n.textContent || '').replace(/\s+/g, ' ');
            if (t.length > 80) continue;
            var hit = false;
            for (j = 0; j < needles.length; j++) {
                if (t.indexOf(needles[j]) !== -1) { hit = true; break; }
            }
            if (!hit) continue;
            if (typeof n.click === 'function') n.click();
            return t;
        }
        return 0;
    ]]
    local val = ws.jsQuery(code, 800)
    wz.write('CLICK', 'enchant-btn ret=' .. tostring(val))
    return val
end

function startEnchant()
    wz.write('CLICK', 'start av=' .. tostring(ws.available) .. ' chance=' .. tostring(ws.chance)
        .. ' right=' .. tostring(enchantSlotsData.right) .. ' left=' .. tostring(enchantSlotsData.left))
    if ws.isGun() then
        if not ws.loopReady() then
            wz.write('CLICK', 'startEnchant blocked, gun not ready')
            return
        end
        sendCEF('startEnchant')
        return
    end
    local clicked = ws.clickEnchantBtn()
    sendCEF('startEnchant')
    if clicked == 0 or clicked == nil or clicked == false then
        wz.write('CLICK', 'enchant-btn miss, packet sent')
    end
end

local function triggerEnchantClick()
    wz.write('CLICK', 'triggerEnchantClick ' .. wz.state())
    startEnchant()
end

function click_onStone()
    ws.placeStone()
end

-- Разбор updateEnchantSlots: JSON через decodeJson, иначе regex
local function parseEnchantSlotsPayload(jsonData)
    if not jsonData or #jsonData == 0 then return end
    local prev = (tostring(enchantSlotsData.index) .. '/' .. tostring(enchantSlotsData.left)
        .. '/' .. tostring(enchantSlotsData.right) .. '/' .. tostring(enchantSlotsData.color))
    local ok, parsed = safeDecodeJson(jsonData)
    if ok and type(parsed) == 'table' then
        if parsed.index ~= nil then enchantSlotsData.index = tonumber(parsed.index) end
        if parsed.left ~= nil then enchantSlotsData.left = tonumber(parsed.left) end
        if parsed.right ~= nil then enchantSlotsData.right = tonumber(parsed.right) end
        if parsed.color ~= nil then enchantSlotsData.color = tonumber(parsed.color) end
    else
        local index = jsonData:match('"index":(%-?%d+)')
        local left = jsonData:match('"left":(%-?%d+)')
        local right = jsonData:match('"right":(%-?%d+)')
        local color = jsonData:match('"color":(%-?%d+)')
        if index then enchantSlotsData.index = tonumber(index) end
        if left then enchantSlotsData.left = tonumber(left) end
        if right then enchantSlotsData.right = tonumber(right) end
        if color then enchantSlotsData.color = tonumber(color) end
    end
    local now = (tostring(enchantSlotsData.index) .. '/' .. tostring(enchantSlotsData.left)
        .. '/' .. tostring(enchantSlotsData.right) .. '/' .. tostring(enchantSlotsData.color))
    if now ~= prev then
        wz.write('SLOTS', 'idx=' .. tostring(enchantSlotsData.index)
            .. ' left=' .. tostring(enchantSlotsData.left)
            .. ' right=' .. tostring(enchantSlotsData.right)
            .. ' color=' .. tostring(enchantSlotsData.color))
    end
end

local function onEnchantSlotsUpdate(jsonData)
    if jsonData then
        parseEnchantSlotsPayload(jsonData)
    end
end

-- Паттерны чата: заточка только по «с +X на +Y»
local PATTERN_FAIL       = u8:decode("Увы, вам не удалось улучшить предмет .- c %+([0-9]+) на %+([0-9]+)")
local PATTERN_FAIL_U8    = "Увы, вам не удалось улучшить предмет .- c %+([0-9]+) на %+([0-9]+)"
local PATTERN_SUCCESS    = u8:decode("Успех! Вам удалось улучшить предмет .- c %+([0-9]+) на %+([0-9]+)")
local PATTERN_SUCCESS_U8 = "Успех! Вам удалось улучшить предмет .- c %+([0-9]+) на %+([0-9]+)"
local PATTERN_GUN_FAIL   = u8:decode("не удалось улучшить .- до %+([0-9]+)")
local PATTERN_GUN_FAIL_U8 = "не удалось улучшить .- до %+([0-9]+)"
local PATTERN_GUN_OK     = u8:decode("успешно улучшили .- до %+([0-9]+)")
local PATTERN_GUN_OK_U8  = "успешно улучшили .- до %+([0-9]+)"

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
    toLvl = text:match(PATTERN_GUN_OK) or text:match(PATTERN_GUN_OK_U8)
    if toLvl then
        toLvl = tonumber(toLvl)
        return true, toLvl - 1, toLvl
    end
    toLvl = text:match(PATTERN_GUN_FAIL) or text:match(PATTERN_GUN_FAIL_U8)
    if toLvl then
        toLvl = tonumber(toLvl)
        return false, toLvl - 1, toLvl
    end
    return nil, nil, nil
end

function ws.isGun()
    return tonumber(ws.tab) == 1
end

function ws.stoneId()
    if ws.isGun() then return GUN_STONE_ID end
    return Whetstone_ITEM_ID
end

function ws.releaseGunMats()
    if not ws.isGun() then return end
    ws.leftOn = false
    ws.rightOn = false
end

function ws.applyFail()
    tochi = true
    ws.pendingResult = nil
    ws.busy = false
    ws.releaseGunMats()
    ws.statFail()
    wz.write('WS', 'fail ' .. wz.state())
end

function ws.statFail()
    local now = os.clock()
    if (now - (tonumber(ws.statAt) or 0)) < 1.2 then return end
    ws.statAt = now
    if ws.isGun() then
        ws.gAll = (tonumber(ws.gAll) or 0) + 1
        ws.gLvl = (tonumber(ws.gLvl) or 0) + 1
    else
        all_lost = all_lost + 1
        lost_stone_onLVL = lost_stone_onLVL + 1
    end
end

function ws.statOk(toLvl)
    local now = os.clock()
    if (now - (tonumber(ws.statAt) or 0)) < 1.2 then return end
    ws.statAt = now
    if ws.isGun() then
        ws.gLvl = (tonumber(ws.gLvl) or 0) + 1
        ws.gAll = (tonumber(ws.gAll) or 0) + 1
        ws.gRows = ws.gRows or {}
        table.insert(ws.gRows, { ws.gLvl, toLvl })
        ws.gLvl = 0
    else
        lost_stone_onLVL = lost_stone_onLVL + 1
        all_lost = all_lost + 1
        table.insert(lost_stone, { lost_stone_onLVL, toLvl })
        lost_stone_onLVL = 0
    end
end

function ws.finishSuccess(fromLvl, toLvl)
    pcall(playSuccessSound)
    ws.statOk(toLvl)
    ws.pendingResult = nil
    ws.busy = false
    ws.releaseGunMats()
    local target = tonumber(max_toch) or 0
    wz.write('WS', 'ok +' .. tostring(fromLvl) .. ' -> +' .. tostring(toLvl) .. ' target=' .. tostring(target))
    if status and target > 0 and toLvl >= target then
        tochi = false
        max_toch = 0
        stone_check = false
        status = false
        sampAddChatMessage(u8:decode("У вас заточился предмет до указанной вами заточки, выбери другой предмет или другой уровень"), -1)
    elseif status then
        tochi = true
    end
end

function ws.autoOn()
    return status and (tonumber(max_toch) or 0) > 0
end

function ws.clearStats()
    if ws.isGun() then
        ws.gRows = {}
        ws.gAll = 0
        ws.gLvl = 0
    else
        lost_stone = {}
        all_lost = 0
        lost_stone_onLVL = 0
    end
end

function ws.sendCategory()
    local cat = ws.isGun() and 6 or 0
    if ws.isGun() and ws.gunCtx then
        ws.lastCat = cat
        return
    end
    local now = os.clock()
    if ws.lastCat == cat then
        return
    end
    ws.lastCat = cat
    ws.lastCatAt = now
    sendCEF('updateCategory|{"category": ' .. tostring(cat) .. '}')
    wz.write('CLICK', 'category=' .. tostring(cat))
end

function ws.setTab(t)
    t = tonumber(t) or 0
    if tonumber(ws.tab) == t then return false end
    ws.tab = t
    status = false
    max_toch = 0
    tochi = false
    stone_check = false
    ws.lastCat = nil
    ws.leftOn = false
    ws.rightOn = false
    enchantSlotsData.left = -1
    enchantSlotsData.right = -1
    ws.bestStone()
    ws.bestRes()
    wz.write('UI', t == 1 and 'tab=weapon' or 'tab=cloth')
    ws.sendCategory()
    return true
end

function ws.slotsJson(idx, left, right, color)
    return '{"index":' .. tostring(idx) .. ',"left":' .. tostring(left)
        .. ',"right":' .. tostring(right) .. ',"color":' .. tostring(color) .. '}'
end

function ws.enoughMats()
    local needR = tonumber(ws.rightNeed) or 1
    if needR < 1 then needR = 1 end
    if (tonumber(ws.stoneAmount) or 0) < needR then return false end
    if ws.isGun() then
        local needL = tonumber(ws.leftNeed) or 0
        if (tonumber(ws.resAmount) or 0) < needL then return false end
    end
    return true
end

function ws.resourcesReady()
    local stone = tonumber(ws.stoneSlot) or -1
    local right = tonumber(enchantSlotsData.right) or -1
    local idx = tonumber(enchantSlotsData.index) or -1
    if idx < 0 or stone < 0 or right ~= stone then return false end
    if ws.isGun() then
        local res = tonumber(ws.resSlot) or -1
        local left = tonumber(enchantSlotsData.left) or -1
        if res < 0 or left ~= res then return false end
    end
    return ws.enoughMats()
end

function ws.bestStone()
    local map = ws.isGun() and (ws.slots10253 or {}) or (ws.slots1187 or {})
    local bestSlot, bestAmt = -1, -1
    for slot, amt in pairs(map) do
        slot = tonumber(slot) or -1
        amt = tonumber(amt) or 0
        if slot >= 0 and amt > bestAmt then
            bestAmt = amt
            bestSlot = slot
        end
    end
    if bestSlot >= 0 then
        ws.stoneSlot = bestSlot
        ws.stoneAmount = bestAmt
    else
        ws.stoneSlot = -1
        ws.stoneAmount = 0
    end
    return bestSlot, bestAmt
end

function ws.bestRes()
    local bestSlot, bestAmt = -1, -1
    for slot, amt in pairs(ws.slots511 or {}) do
        slot = tonumber(slot) or -1
        amt = tonumber(amt) or 0
        if slot >= 0 and amt > bestAmt then
            bestAmt = amt
            bestSlot = slot
        end
    end
    if bestSlot >= 0 then
        ws.resSlot = bestSlot
        ws.resAmount = bestAmt
    else
        ws.resSlot = -1
        ws.resAmount = 0
    end
    return bestSlot, bestAmt
end

function ws.jsQuery(code, timeout)
    if cefDlg and cefDlg.cefQuery then
        return cefDlg.cefQuery(code, timeout or 800)
    end
    evalanon(code)
    return nil
end

function ws.clickInvSlot(slot, needle, tag)
    slot = tonumber(slot) or -1
    if slot < 0 then return nil end
    needle = tostring(needle or '')
    local code = 'var want=' .. tostring(slot) .. '; var needle="' .. needle .. '";' ..
        [[
        function fire(el) {
            if (!el) return 0;
            var t = el;
            if (el.tagName === 'IMG') t = el.closest('[data-slot], .inventory-item-hoc, button, [role="button"]') || el;
            var opts = { bubbles: true, cancelable: true, view: window };
            t.dispatchEvent(new MouseEvent('pointerdown', opts));
            t.dispatchEvent(new MouseEvent('mousedown', opts));
            t.dispatchEvent(new MouseEvent('pointerup', opts));
            t.dispatchEvent(new MouseEvent('mouseup', opts));
            t.dispatchEvent(new MouseEvent('click', opts));
            if (typeof t.click === 'function') t.click();
            return 1;
        }
        var el = null;
        var all = document.querySelectorAll('.inventory-item-hoc, [data-slot], [data-index]');
        var i;
        for (i = 0; i < all.length; i++) {
            var n = all[i];
            var s = n.getAttribute('data-slot') || n.getAttribute('data-index') || '';
            if (String(s) === String(want)) { el = n; break; }
        }
        if (!el && needle) {
            var imgs = document.querySelectorAll('img');
            for (i = 0; i < imgs.length; i++) {
                var a = (imgs[i].getAttribute('alt') || '') + ' ' + (imgs[i].getAttribute('src') || '');
                if (a.indexOf(needle) !== -1) {
                    el = imgs[i].closest('.inventory-item-hoc, [data-slot]') || imgs[i];
                    break;
                }
            }
        }
        return fire(el);
        ]]
    local val = ws.jsQuery(code, 700)
    wz.write('CLICK', 'cefQuery ' .. tostring(tag or 'slot') .. '=' .. tostring(slot) .. ' ret=' .. tostring(val))
    return val
end

function ws.clickStoneJs()
    return ws.clickInvSlot(ws.stoneSlot, '1187', 'stone')
end

function ws.loopReady()
    if ws.isGun() then
        if not ws.resourcesReady() then return false end
        if (tonumber(ws.available) or 0) ~= 1 then return false end
        if (os.clock() - (tonumber(ws.lastPlaceAt) or 0)) < 0.4 then return false end
        return true
    end
    return (tonumber(ws.available) or 0) == 1 or ws.resourcesReady()
end

function ws.placeStone()
    ws.bestStone()
    ws.bestRes()
    local idx = tonumber(enchantSlotsData.index) or -1
    local stone = tonumber(ws.stoneSlot) or -1
    local gun = ws.isGun()
    if idx < 0 then
        if ws.loopTag ~= 'wait-item' then
            wz.write('CLICK', gun and 'wait weapon on bench' or 'wait item on bench (click the item first)')
        end
        return false
    end
    if stone < 0 or (tonumber(ws.stoneAmount) or 0) <= 0 then
        if ws.loopTag ~= 'no-stone' then
            wz.write('CLICK', gun and 'no gun stone 10253' or 'no whetstone 1187 in inventory')
        end
        return false
    end
    if gun then
        local res = tonumber(ws.resSlot) or -1
        if res < 0 or (tonumber(ws.resAmount) or 0) <= 0 then
            if ws.loopTag ~= 'no-res' then
                wz.write('CLICK', 'no gun resource 511')
            end
            return false
        end
        if not ws.enoughMats() then
            if not ws.lowMatSaid then
                ws.lowMatSaid = true
                wz.write('CLICK', 'not enough mats stoneN=' .. tostring(ws.stoneAmount)
                    .. ' needR=' .. tostring(ws.rightNeed)
                    .. ' resN=' .. tostring(ws.resAmount)
                    .. ' needL=' .. tostring(ws.leftNeed))
                sampAddChatMessage(u8:decode('Не хватает заточки на оружие или ресурса'), 0xFF3333)
            end
            return false
        end
        ws.lowMatSaid = false
    end
    if ws.resourcesReady() then
        return true
    end
    local now = os.clock()
    local gap = gun and 1.0 or 2.5
    if (now - (tonumber(ws.lastPlaceAt) or 0)) < gap then
        return false
    end
    ws.lastPlaceAt = now
    local left = tonumber(enchantSlotsData.left) or -1
    local right = tonumber(enchantSlotsData.right) or -1
    if gun then
        local res = tonumber(ws.resSlot) or -1
        if left ~= res then
            ws.clickInvSlot(res, '511', 'gun-res')
            wz.write('CLICK', 'gun click res slot=' .. tostring(res))
            return false
        end
        if right ~= stone then
            ws.clickInvSlot(stone, '10253', 'gun-stone')
            wz.write('CLICK', 'gun click stone slot=' .. tostring(stone) .. ' keepLeft=' .. tostring(res))
            return false
        end
        return ws.resourcesReady()
    end
    if right ~= stone then
        ws.clickStoneJs()
    end
    local json = ws.slotsJson(idx, left, stone, -1)
    sendCEF('updateEnchantSlots|' .. json)
    wz.write('CLICK', 'place updateEnchantSlots|' .. json
        .. ' stoneN=' .. tostring(ws.stoneAmount))
    return idx >= 0
end

function ws.handleSend(text)
    if type(text) ~= 'string' or text == '' then return end
    if text:sub(1, 8) == 'REWRITE ' then return end
    local json = text:match('^updateEnchantSlots|(.+)')
    if not json then return end
    parseEnchantSlotsPayload(json)
    if not ws.autoOn() then return end
    if ws.isGun() then return end
    local stone = tonumber(ws.stoneSlot) or -1
    if stone >= 0 and (tonumber(enchantSlotsData.right) or -1) == -1 then
        enchantSlotsData.right = stone
    end
end

function ws.ingestItems(items, invType)
    if type(items) ~= 'table' then return end
    invType = tonumber(invType) or 1
    if invType ~= 1 then return end
    ws.slots1187 = ws.slots1187 or {}
    ws.slots10253 = ws.slots10253 or {}
    ws.slots511 = ws.slots511 or {}
    local targetSlot = tonumber(enchantSlotsData.index) or -1
    for _, item in ipairs(items) do
        if type(item) == 'table' then
            local id = tonumber(item.item)
            local slot = tonumber(item.slot)
            if slot then
                if id == Whetstone_ITEM_ID then
                    ws.slots1187[slot] = tonumber(item.amount) or ws.slots1187[slot] or 1
                    ws.slots10253[slot] = nil
                    ws.slots511[slot] = nil
                elseif id == GUN_STONE_ID then
                    ws.slots10253[slot] = tonumber(item.amount) or ws.slots10253[slot] or 1
                    ws.slots1187[slot] = nil
                    ws.slots511[slot] = nil
                elseif id == GUN_RES_ID then
                    ws.slots511[slot] = tonumber(item.amount) or ws.slots511[slot] or 1
                    ws.slots1187[slot] = nil
                    ws.slots10253[slot] = nil
                else
                    ws.slots1187[slot] = nil
                    ws.slots10253[slot] = nil
                    ws.slots511[slot] = nil
                end
            end
            local ench = item.enchant
            local txtLvl = tostring(item.text or ''):match('%+(%d+)')
            local isTarget = (targetSlot >= 0 and slot == targetSlot)
            if isTarget then
                local newLvl = tonumber(txtLvl) or tonumber(ench)
                if id and id ~= Whetstone_ITEM_ID and id ~= GUN_STONE_ID and id ~= GUN_RES_ID then
                    ws.itemSlot = slot or ws.itemSlot
                    ws.itemId = id
                    local prev = tonumber(ws.itemEnchant) or -1
                    if newLvl ~= nil then
                        ws.itemEnchant = newLvl
                        if ws.pendingResult == 1 and newLvl ~= prev then
                            ws.finishSuccess(prev >= 0 and prev or (newLvl - 1), newLvl)
                        elseif status and (tonumber(max_toch) or 0) > 0 and newLvl >= (tonumber(max_toch) or 0) then
                            ws.finishSuccess(prev >= 0 and prev or (newLvl - 1), newLvl)
                        end
                    end
                end
            end
        end
    end
    ws.bestStone()
    ws.bestRes()
end

function ws.handle(ev, payload)
    if not ev then return end
    payload = payload or ''
    if ev == 'event.inventory.setWorkshopVisible' then
        local on = payload:find('true', 1, true) ~= nil
        workshop_check = on
        if on then
            wz.write('WS', 'visible')
        else
            wz.write('WS', 'hidden')
            ws.busy = false
            enchantSlotsData.index = -1
            enchantSlotsData.left = -1
            enchantSlotsData.right = -1
            enchantSlotsData.color = -1
            ws.available = 0
            ws.lastPlaceJson = ''
            ws.lastCat = nil
            ws.leftOn = false
            ws.rightOn = false
        end
        return
    end
    if ev == 'event.inventory.setWorkshopGunContext' then
        local on = payload:find('true', 1, true) ~= nil
        ws.gunCtx = on and true or false
        wz.write('WS', 'gunCtx=' .. tostring(ws.gunCtx))
        if on then
            ws.lastCat = 6
            if not ws.autoOn() then ws.tab = 1 end
        else
            if not ws.autoOn() then ws.tab = 0 end
        end
        return
    end
    if ev == 'event.workshop.setResourceNeedItems' then
        workshop_check = true
        local ok, arr = safeDecodeJson(payload)
        if ok and type(arr) == 'table' then
            local row = arr[1] or arr
            if type(row) == 'table' then
                if row.leftResourceAmount ~= nil then ws.leftNeed = tonumber(row.leftResourceAmount) or 0 end
                if row.rightResourceAmount ~= nil then ws.rightNeed = tonumber(row.rightResourceAmount) or 1 end
            end
        end
        wz.write('WS', 'need left=' .. tostring(ws.leftNeed) .. ' right=' .. tostring(ws.rightNeed))
        return
    end
    if ev == 'event.notify.initialize' then
        local msg = tostring(payload or '')
        wz.write('NOTIFY', wz.clip(msg, 180))
        if ws.isGun() then
            if msg:find('Заточка на оружие', 1, true) or msg:find(u8:decode('Заточка на оружие'), 1, true) then
                ws.busy = false
                wz.write('WS', 'gun: not enough 10253')
            end
        end
        return
    end
    if ev == 'event.inventory.workShop' then
        workshop_check = true
        local ok, arr = safeDecodeJson(payload)
        if not ok or type(arr) ~= 'table' then
            wz.write('WS', 'workshop-json-fail ' .. wz.clip(payload, 200))
            return
        end
        local row = arr[1]
        if type(row) ~= 'table' then row = arr end
        if type(row) ~= 'table' then return end
        local action = tonumber(row.action)
        local data = row.data or {}
        if action == 2 then
            if data.chance ~= nil then ws.chance = tonumber(data.chance) or ws.chance end
            if data.cost ~= nil then ws.cost = tonumber(data.cost) or ws.cost end
            if data.available ~= nil then ws.available = tonumber(data.available) or ws.available end
            if data.amount ~= nil then ws.amount = tonumber(data.amount) or ws.amount end
            wz.write('WS', 'ready chance=' .. tostring(ws.chance) .. ' cost=' .. tostring(ws.cost) .. ' av=' .. tostring(ws.available))
        elseif action == 0 then
            ws.busy = true
            ws.busyAt = os.clock()
            wz.write('WS', 'started ' .. tostring(data.time))
        elseif action == 1 then
            ws.busy = false
            local suc = tonumber(data.success)
            wz.write('WS', 'result success=' .. tostring(suc) .. ' ench=' .. tostring(ws.itemEnchant))
            if suc == 1 then
                ws.pendingResult = 1
            else
                ws.applyFail()
            end
        end
        return
    end
    if ev == 'event.inventory.playerInventory' then
        local ok, arr = safeDecodeJson(payload)
        if not ok or type(arr) ~= 'table' then return end
        local row = arr[1]
        if type(row) ~= 'table' then return end
        local data = row.data or {}
        if type(data.items) == 'table' then
            ws.ingestItems(data.items, data.type)
        end
    end
end

local function processCefText(str)
    if type(str) ~= 'string' or str == '' then return end
    wz.cef(str)
    local ev, payload
    if arizona and arizona.decode then
        local pkt = { id = 17, text = str }
        local okd, decoded = pcall(arizona.decode, pkt)
        if okd and decoded and pkt.event then
            ev = pkt.event
            if type(pkt.json) == 'string' then
                payload = pkt.json
            elseif encodeJson then
                local oke, js = pcall(encodeJson, pkt.json)
                if oke then payload = js end
            end
        end
    end
    if not ev then
        ev, payload = wz.eventOf(str)
    end
    if ev then
        pcall(ws.handle, ev, payload or '')
    end
    if str:find('updateEnchantSlots', 1, true) then
        workshop_check = true
        onEnchantSlotsUpdate(str:match('updateEnchantSlots|(.+)'))
    end
end

local function processChatLine(text)
    if type(text) ~= 'string' or text == '' then return end
    if (tonumber(max_toch) or 0) <= 0 then return end
    local t = text:gsub("%{%x%x%x%x%x%x%}", "")
    local isSuccess, fromLvl, toLvl = parseEnchantLevelsFromChat(t)
    if isSuccess == nil then
        if wz.hot(t) then wz.write('CHAT', t) end
        return
    end
    wz.write('CHAT', (isSuccess and 'OK' or 'FAIL') .. ' +' .. tostring(fromLvl) .. ' -> +' .. tostring(toLvl) .. ' | ' .. t)
    if not isSuccess then
        tochi = true
        ws.busy = false
        ws.pendingResult = nil
        ws.releaseGunMats()
        ws.statFail()
        return
    end
    if isSuccess and toLvl then
        pcall(playSuccessSound)
        ws.statOk(toLvl)
        ws.busy = false
        ws.pendingResult = nil
        ws.releaseGunMats()
        local target = tonumber(max_toch) or 0
        if toLvl == target and fromLvl == (target - 1) then
            tochi = false
            max_toch = 0
            stone_check = false
            status = false
            sampAddChatMessage(u8:decode("У вас заточился предмет до указанной вами заточки, выбери другой предмет или другой уровень"), -1)
        else
            tochi = true
        end
    end
end

local function processTd(d)
    if type(d) ~= 'table' then return end
    local text = d.text or ''
    local interesting = wz.hot(text) or d.modelId == Whetstone_ITEM_ID
        or (d.letterColor == -10398017 and d.lineWidth == 44)
        or text:find('WORKSHOP', 1, true) or text:find('ENCHANT', 1, true)
        or text:find('МАСТЕРСКАЯ', 1, true) or text:find('Мастерская', 1, true)
        or text:find('ВЕРСТАК', 1, true) or text:find('Верстак', 1, true) or text:find('верстак', 1, true)
        or text:find('ЗАТОЧКА', 1, true) or text:find('Заточка', 1, true)
    if interesting then
        wz.write('TD', 'id=' .. tostring(d.id)
            .. ' text=' .. wz.clip(text, 180)
            .. ' color=' .. tostring(d.letterColor)
            .. ' w=' .. tostring(d.lineWidth)
            .. ' h=' .. tostring(d.lineHeight)
            .. ' model=' .. tostring(d.modelId)
            .. ' sel=' .. tostring(d.selectable))
    end
    if text:find('WORKSHOP', 1, true) or text:find('МАСТЕРСКАЯ', 1, true) or text:find('Мастерская', 1, true)
        or text:find('ВЕРСТАК', 1, true) or text:find('Верстак', 1, true) or text:find('верстак', 1, true) then
        stone = {}
        workshop_check = true
        wz.askDump()
    end
    if text:find('ENCHANT', 1, true) or text:find('ЗАТОЧКА', 1, true) or text:find('Заточка', 1, true) then
        local id = tonumber(d.id) or 0
        button_id = id - 1
    end
    if d.letterColor == -10398017 and d.lineWidth == 44 and d.lineHeight == 16 then
        button_id = tonumber(d.id) or button_id
    end
    if workshop_check then
        if stone_check and (tonumber(d.lineWidth) or 0) >= 1 then
            stone_check = false
        end
        if d.modelId == Whetstone_ITEM_ID and d.selectable == 1 then
            table.insert(stone, { tonumber(d.id) })
        end
    end
end

local function pumpIncoming()
    wz.pumpOut()
    if #incomingCef > 0 then
        local batch = incomingCef
        incomingCef = {}
        for i = 1, #batch do pcall(processCefText, batch[i]) end
    end
    if #incomingChat > 0 then
        local batch = incomingChat
        incomingChat = {}
        for i = 1, #batch do pcall(processChatLine, batch[i]) end
    end
    if #incomingTd > 0 then
        local batch = incomingTd
        incomingTd = {}
        for i = 1, #batch do pcall(processTd, batch[i]) end
    end
end

local function chainArz(name, fn)
    if not arizona then return end
    local prev = arizona[name]
    arizona[name] = function(packet)
        local ok1, r1 = pcall(fn, packet)
        local r2
        if prev then
            local ok2, x = pcall(prev, packet)
            if ok2 then r2 = x end
        end
        if ok1 and r1 == false then return false end
        if ok1 and type(r1) == 'table' then return r1 end
        return r2
    end
end

local function snapCefPacket(packet)
    if not packet then return end
    pcall(function()
        local t = packet.text
        if type(t) == 'string' and t ~= '' then queueCef(t) end
    end)
end

local function snapSendPacket(packet)
    if not packet or type(packet.text) ~= 'string' or packet.text == '' then return end
    local t = packet.text
    wz.queueSend(t)
    if not ws.autoOn() then return end
    if ws.isGun() then return end
    local json = t:match('^updateEnchantSlots|(.+)')
    if not json then return end
    pcall(ws.bestStone)
    pcall(ws.bestRes)
    local stone = tonumber(ws.stoneSlot) or -1
    local res = tonumber(ws.resSlot) or -1
    local idx = tonumber(json:match('"index":(%-?%d+)')) or tonumber(enchantSlotsData.index) or -1
    local left = tonumber(json:match('"left":(%-?%d+)')) or tonumber(enchantSlotsData.left) or -1
    local right = tonumber(json:match('"right":(%-?%d+)')) or -1
    local color = tonumber(json:match('"color":(%-?%d+)')) or -1
    if idx < 0 then return end
    local need = false
    if ws.isGun() then
        if not (ws.leftOn and ws.rightOn and res >= 0 and stone >= 0) then return end
        if left ~= res then
            left = res
            need = true
        end
        if right ~= stone then
            right = stone
            need = true
        end
    else
        if stone >= 0 and right ~= stone then
            right = stone
            need = true
        end
    end
    if color ~= -1 then
        color = -1
        need = true
    end
    if not need then return end
    packet.text = 'updateEnchantSlots|' .. ws.slotsJson(idx, left, right, color)
    local now = os.clock()
    if not ws.lastRewriteLog or (now - ws.lastRewriteLog) > 1 then
        ws.lastRewriteLog = now
        wz.queueSend('REWRITE ' .. packet.text)
    end
    return { packet }
end

function main()
    while not isSampAvailable() do wait(100) end
    sampRegisterChatCommand('mt', function() WinState[0] = not WinState[0] end)
    sampRegisterChatCommand('mtlog', function()
        lua_thread.create(function()
            wz.ensure()
            wz.write('CMD', '/mtlog ' .. wz.state())
            wz.lastDump = 0
            wz.needDump = true
            local miss = {}
            for k, v in pairs(wz.miss) do miss[#miss + 1] = k .. '=' .. tostring(v) end
            table.sort(miss)
            if #miss > 0 then
                wz.write('CEF-OTHER', table.concat(miss, ', '))
            end
            sampAddChatMessage('[AutoZatochka] log: ' .. tostring(wz.path), -1)
            sampAddChatMessage('[AutoZatochka] ' .. u8:decode('Открой верстак и скинь workshop.log'), -1)
        end)
    end)

    -- У кого нет lib/arizona-events: синхронная докачка → перезагрузка скрипта → уже с require
    if not arizonaEventsLibPresent() then
        sampAddChatMessage('[AutoZatochka] ' .. u8:decode('Не найдены библиотеки arizona-events. Скачиваю с GitHub...'), -1)
        local ok = syncArizonaEventsLib(true)
        if ok then
            sampAddChatMessage('[AutoZatochka] ' .. u8:decode('Загрузка завершена. Перезапуск скрипта...'), -1)
            wait(400)
            thisScript():reload()
        else
            sampAddChatMessage('[AutoZatochka] ' .. u8:decode('Скачивание не удалось. Проверьте интернет. Файлы: zvyk/arizona-events на GitHub.'), -1)
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
        chainArz('onArizonaDisplay', snapCefPacket)
        chainArz('onArizonaIncomingCef18', snapCefPacket)
        chainArz('onArizonaSend', snapSendPacket)
    end

    loadPendingChangelogIfAny()
    wz.ensure()
    wz.write('BOOT', tostring(thisScript().version) .. ' arizona=' .. tostring(arizona ~= nil) .. ' cefDlg=' .. tostring(cefDlg ~= nil) .. ' file=' .. tostring(wz.path))
    sampAddChatMessage('[AutoZatochka] log: moonloader\\config\\autozatochka\\workshop.log  (/mtlog)', -1)

    -- Загрузка звука успешной заточки с GitHub в фоне
    lua_thread.create(function()
        wait(500)
        initSuccessSound()
    end)

    -- Авто-проверка version.json только если enable_autoupdate = true (кнопка в меню — в любой момент)
    if enable_autoupdate then
        lua_thread.create(function()
            wait(2000)
            if autoupdate_loaded and Update then
                pcall(Update.check, Update.json_url, Update.prefix, Update.url)
            end
        end)
    end
    
    -- Пакет 220 разбирает lib arizona-events (onArizonaDisplay / onArizonaIncomingCef18). Если библиотека не загрузилась — вручную.
    if not arizona then
        pcall(function()
            addEventHandler('onReceivePacket', function(id, bs)
                if id ~= 220 then return end
                local act
                pcall(function()
                    local off
                    if raknetBitStreamGetReadOffset then off = raknetBitStreamGetReadOffset(bs) end
                    if raknetBitStreamSetReadOffset then raknetBitStreamSetReadOffset(bs, 0) end
                    raknetBitStreamIgnoreBits(bs, 8)
                    local packetType = raknetBitStreamReadInt8(bs)
                    if packetType == 17 then
                        raknetBitStreamIgnoreBits(bs, 32)
                        local length = raknetBitStreamReadInt16(bs)
                        local encoded = raknetBitStreamReadInt8(bs)
                        if length and length > 0 then
                            local str = (encoded ~= 0) and raknetBitStreamDecodeString(bs, length + encoded) or raknetBitStreamReadString(bs, length)
                            if type(str) == 'string' then act = str end
                        end
                    elseif packetType == 18 then
                        local dataLength = raknetBitStreamReadInt16(bs)
                        local encoded = raknetBitStreamReadInt8(bs)
                        if dataLength and dataLength > 0 then
                            local data = (encoded ~= 0) and raknetBitStreamDecodeString(bs, dataLength + encoded) or raknetBitStreamReadString(bs, dataLength)
                            if type(data) == 'string' then act = data end
                        end
                    end
                    if off and raknetBitStreamSetReadOffset then raknetBitStreamSetReadOffset(bs, off) end
                end)
                if type(act) == 'string' then queueCef(act) end
            end)
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
        pcall(pumpIncoming)
        wz.flushState()
        if wz.needDump then
            wz.needDump = false
            wz.lastDump = os.clock()
            wz.write('DOM', 'dump start')
            pcall(evalanon, wz.jsDump)
            wait(250)
            local dump
            pcall(function()
                dump = evalcefReturn('return window.__azDump || "";')
            end)
            wz.write('DOM', (dump ~= nil and tostring(dump) ~= '' and tostring(dump)) or 'empty (eval did not return DOM)')
        end
        wait(0)
        if ws.autoOn() then
            local target = tonumber(max_toch) or 0
            local lvl = tonumber(ws.itemEnchant) or -1
            if target > 0 and lvl >= target then
                wz.write('LOOP', 'done ench=' .. tostring(lvl))
                status = false
                max_toch = 0
                tochi = false
                sampAddChatMessage(u8:decode("У вас заточился предмет до указанной вами заточки, выбери другой предмет или другой уровень"), -1)
            elseif not workshop_check then
                if ws.loopTag ~= 'wait' then
                    ws.loopTag = 'wait'
                    wz.write('LOOP', 'wait-workshop ' .. wz.state())
                end
                wait(500)
            elseif ws.busy then
                if os.clock() - (tonumber(ws.busyAt) or 0) > 20 then
                    wz.write('LOOP', 'busy-timeout')
                    ws.busy = false
                    ws.loopTag = ''
                else
                    wait(120)
                end
            else
                local ready = ws.loopReady()
                if ready then
                    ws.loopTag = 'go'
                    wz.write('LOOP', 'go ' .. wz.state())
                    ws.busy = true
                    ws.busyAt = os.clock()
                    triggerEnchantClick()
                    wait(800)
                else
                    if ws.loopTag ~= 'not-ready' then
                        ws.loopTag = 'not-ready'
                        wz.write('LOOP', 'not-ready ' .. wz.state())
                    end
                    click_onStone()
                    if ws.isGun() then
                        wait(600)
                    else
                        wait(800)
                    end
                end
            end
        end
    end
end

function ws.uiAccent()
    return imgui.ImVec4(0.36, 0.58, 1.00, 1)
end

function ws.uiNav(label, selected, w)
    if selected then
        imgui.PushStyleColor(imgui.Col.Button, ws.uiAccent())
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.46, 0.66, 1, 1))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.30, 0.50, 0.95, 1))
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.07, 0.08, 0.10, 1))
    else
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(1, 1, 1, 0.05))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.36, 0.58, 1, 0.22))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.36, 0.58, 1, 0.35))
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.78, 0.80, 0.86, 1))
    end
    local clicked = imgui.Button(label, imgui.ImVec2(w, 32))
    imgui.PopStyleColor(4)
    return clicked
end

function ws.uiIcon(label, w)
    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(1, 1, 1, 0.06))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.36, 0.58, 1, 0.35))
    imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.36, 0.58, 1, 0.55))
    local clicked = imgui.Button(label, imgui.ImVec2(w or 28, 28))
    imgui.PopStyleColor(3)
    return clicked
end

function ws.uiLvl(i, w, h)
    local on = (i == max_toch)
    if on then
        imgui.PushStyleColor(imgui.Col.Button, ws.uiAccent())
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.46, 0.66, 1, 1))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.30, 0.50, 0.95, 1))
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.07, 0.08, 0.10, 1))
    else
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(1, 1, 1, 0.06))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.36, 0.58, 1, 0.28))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.36, 0.58, 1, 0.45))
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.82, 0.84, 0.90, 1))
    end
    local clicked = imgui.Button('+' .. tostring(i), imgui.ImVec2(w, h))
    imgui.PopStyleColor(4)
    return clicked
end

function ws.pickLevel(i)
    if max_toch ~= i then
        status = true
        max_toch = i
        ws.lowMatSaid = false
        wz.write('UI', 'toch +' .. tostring(i) .. ' ' .. wz.state())
        lua_thread.create(function()
            wait(120)
            click_onStone()
            wait(400)
            if status and ws.loopReady() and not ws.busy then
                ws.busy = true
                ws.busyAt = os.clock()
                triggerEnchantClick()
            end
        end)
    else
        status = false
        max_toch = 0
        tochi = false
        stone_check = false
        wz.write('UI', 'stop +' .. tostring(i))
    end
end

function ws.drawSettingsBody()
    imgui.TextDisabled('Версия ' .. tostring(thisScript().version or '1.0'))
    imgui.Dummy(imgui.ImVec2(0, 8))
    if imgui.Checkbox('Звук при успехе', playSound) then
        addOneOffSound(0.0, 0.0, 0.0, 1139)
    end
    imgui.Dummy(imgui.ImVec2(0, 10))
    if imgui.Button('Очистить статистику', imgui.ImVec2(476, 32)) then
        ws.clearStats()
    end
    imgui.Dummy(imgui.ImVec2(0, 4))
    if imgui.Button('Перезагрузить скрипт', imgui.ImVec2(476, 32)) then
        lua_thread.create(function()
            sampAddChatMessage(u8:decode('[AutoZatochka] Перезагрузка скрипта...'), -1)
            wait(1000)
            thisScript():reload()
        end)
    end
    imgui.Dummy(imgui.ImVec2(0, 4))
    if imgui.Button('Проверить обновления', imgui.ImVec2(476, 32)) then
        lua_thread.create(function()
            if autoupdate_loaded and Update then
                sampAddChatMessage('[AutoZatochka] ' .. u8:decode('Проверка обновлений...'), -1)
                wait(100)
                pcall(Update.check, Update.json_url, Update.prefix, Update.url)
                wait(500)
                sampAddChatMessage('[AutoZatochka] ' .. u8:decode('Если есть новая версия - скрипт обновится и перезагрузится.'), -1)
            else
                sampAddChatMessage('[AutoZatochka] ' .. u8:decode('Автообновление недоступно (нет decodeJson).'), -1)
            end
        end)
    end
    imgui.Dummy(imgui.ImVec2(0, 14))
    imgui.TextDisabled('/mt  закрыть окно')
    imgui.TextDisabled('Шестерёнка ещё раз — назад')
end

imgui.OnFrame(function() return WinState[0] end,
    function()
        local W, H = 508, 418
        imgui.SetNextWindowPos(imgui.ImVec2(500, 500), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(W, H), imgui.Cond.Always)
        imgui.Begin('##Window', WinState, imgui.WindowFlags.NoDecoration)
        local dl = imgui.GetWindowDrawList()
        local p = imgui.GetWindowPos()
        local sz = imgui.GetWindowSize()
        dl:AddRectFilled(p, imgui.ImVec2(p.x + 4, p.y + sz.y), imgui.ColorConvertFloat4ToU32(ws.uiAccent()), 2)
        imgui.SetCursorPos(imgui.ImVec2(16, 12))
        imgui.PushStyleColor(imgui.Col.Text, ws.uiAccent())
        imgui.Text('AutoZatochka')
        imgui.PopStyleColor()
        imgui.SameLine()
        imgui.TextDisabled('  Arizona  ·  ' .. tostring(thisScript().version or ''))
        imgui.SetCursorPos(imgui.ImVec2(W - 76, 8))
        if ws.uiIcon('##gear', 28) then
            SetWin[0] = not SetWin[0]
        end
        do
            local a = imgui.GetItemRectMin()
            local b = imgui.GetItemRectMax()
            local cx = (a.x + b.x) * 0.5
            local cy = (a.y + b.y) * 0.5
            local col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.91, 0.92, 0.94, 1))
            pcall(function()
                dl:AddCircleFilled(imgui.ImVec2(cx - 6, cy), 2.1, col, 8)
                dl:AddCircleFilled(imgui.ImVec2(cx, cy), 2.1, col, 8)
                dl:AddCircleFilled(imgui.ImVec2(cx + 6, cy), 2.1, col, 8)
            end)
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip(SetWin[0] and 'Назад' or 'Настройки')
        end
        imgui.SameLine()
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.22, 0.32, 0.35))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.9, 0.25, 0.35, 0.7))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.9, 0.25, 0.35, 0.9))
        if imgui.Button('X', imgui.ImVec2(28, 28)) then
            WinState[0] = false
            SetWin[0] = false
        end
        imgui.PopStyleColor(3)

        if SetWin[0] then
            imgui.SetCursorPos(imgui.ImVec2(16, 52))
            imgui.PushStyleColor(imgui.Col.Text, ws.uiAccent())
            imgui.Text('Настройки')
            imgui.PopStyleColor()
            imgui.Separator()
            imgui.Dummy(imgui.ImVec2(0, 8))
            ws.drawSettingsBody()
        else
            imgui.SetCursorPos(imgui.ImVec2(16, 48))
            if ws.uiNav('Заточка аксов/скинов', tonumber(ws.tab) == 0, 234) then
                ws.setTab(0)
            end
            imgui.SameLine()
            if ws.uiNav('Скины на оружие', tonumber(ws.tab) == 1, 234) then
                ws.setTab(1)
            end

            imgui.SetCursorPos(imgui.ImVec2(16, 90))
            if imgui.BeginChild('##status', imgui.ImVec2(476, 52), false) then
                local ench = tonumber(ws.itemEnchant) or -1
                local run = status and (tonumber(max_toch) or 0) > 0
                if run then
                    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.45, 0.85, 0.55, 1))
                    imgui.Text('Точит до +' .. tostring(max_toch))
                    imgui.PopStyleColor()
                else
                    imgui.TextDisabled('Выбери уровень')
                end
                if ench >= 0 then
                    imgui.SameLine()
                    imgui.TextDisabled('  ·  сейчас +' .. tostring(ench))
                end
                if ws.isGun() then
                    imgui.TextDisabled('Камни  ' .. tostring(ws.stoneAmount or 0) .. ' / ' .. tostring(ws.rightNeed or 2)
                        .. '      Ресурс  ' .. tostring(ws.resAmount or 0) .. ' / ' .. tostring(ws.leftNeed or 0))
                else
                    imgui.TextDisabled('Точильные камни  ' .. tostring(ws.stoneAmount or 0))
                end
                imgui.EndChild()
            end

            imgui.SetCursorPos(imgui.ImVec2(16, 146))
            imgui.TextDisabled('Точить до')
            do
                local i
                for i = 1, 12 do
                    local col = (i - 1) % 4
                    local row = math.floor((i - 1) / 4)
                    imgui.SetCursorPos(imgui.ImVec2(16 + col * 118, 168 + row * 36))
                    if ws.uiLvl(i, 110, 30) then
                        ws.pickLevel(i)
                    end
                end
            end

            imgui.SetCursorPos(imgui.ImVec2(16, 284))
            if imgui.BeginChild('##stats', imgui.ImVec2(476, 118), false) then
                imgui.PushStyleColor(imgui.Col.Text, ws.uiAccent())
                imgui.Text(ws.isGun() and 'Статистика  ·  скины на оружие' or 'Статистика  ·  аксы/скины')
                imgui.PopStyleColor()
                imgui.Separator()
                local rows = ws.isGun() and (ws.gRows or {}) or lost_stone
                local total = ws.isGun() and (tonumber(ws.gAll) or 0) or all_lost
                local cur = ws.isGun() and (tonumber(ws.gLvl) or 0) or lost_stone_onLVL
                local n
                for n = 1, #rows do
                    local v = rows[n]
                    if type(v) == 'table' then
                        imgui.Text('С +' .. tostring((v[2] or 1) - 1) .. ' до +' .. tostring(v[2]) .. '  —  ' .. attemptsWord(v[1]))
                    end
                end
                if cur > 0 then
                    imgui.TextDisabled('Сейчас  ' .. attemptsWord(cur))
                end
                imgui.TextDisabled('Всего попыток  ' .. tostring(total))
                imgui.EndChild()
            end
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
    if imgui.Begin('ВАЖНО - обновление AutoZatochka', nil, wf) then
        imgui.TextColored(imgui.ImVec4(1, 0.35, 0.12, 1), 'Список изменений')
        imgui.Separator()
        imgui.BeginChild('##changelog_scroll', imgui.ImVec2(460, 240), true)
        imgui.TextWrapped(changelog_after_update)
        imgui.EndChild()
        imgui.Spacing()
        if imgui.Button('Понятно', imgui.ImVec2(220, 34)) then
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
    evalanon([[
        try {
            const bodyText = (document.body.innerText || document.body.textContent || '').toUpperCase();
            const hasKeywords = bodyText.includes('WORKSHOP') || bodyText.includes('ВЕРСТАК') || 
                               bodyText.includes('МАСТЕРСКАЯ') || bodyText.includes('ENCHANT') || 
                               bodyText.includes('ЗАТОЧКА');
            
            const hasEnchantElements = document.querySelectorAll('[class*="enchant"], [class*="Enchant"], [id*="enchant"]').length > 0;
            const hasWorkshopElements = document.querySelectorAll('[class*="workshop"], [class*="Workshop"], [id*="workshop"]').length > 0;
            let hasStoneElements = document.querySelectorAll('[data-item-id="1187"], [data-model="1187"], [data-id="1187"]').length > 0;
            
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
    wait(50)
    -- arizona.eval не возвращает значение из CEF — при активной автозаточке верстак уже открыт
    if status and max_toch > 0 then
        workshop_check = true
        return
    end
    local detected = evalcefReturn('return window.workshopDetected === true || window.workshopOpen === true;')
    if detected == true or detected == 1 or detected == 'true' then
        workshop_check = true
    end
    wz.write('WS', 'check detected=' .. tostring(detected) .. ' ' .. wz.state())
end

-- == Обработка событий: копии в очередь, прошлые хуки не затираем == --
if sampev then
    local prevTd = sampev.onShowTextDraw
    function sampev.onShowTextDraw(id, data)
        pcall(function()
            if type(data) ~= 'table' then return end
            local text = data.text
            queueTd({
                id = tonumber(id) or 0,
                text = type(text) == 'string' and (text .. '') or '',
                letterColor = tonumber(data.letterColor),
                lineWidth = tonumber(data.lineWidth),
                lineHeight = tonumber(data.lineHeight),
                modelId = tonumber(data.modelId),
                selectable = tonumber(data.selectable),
            })
        end)
        if prevTd then
            local ok, a, b = pcall(prevTd, id, data)
            if ok then return a, b end
        end
    end

    local prevMsg = sampev.onServerMessage
    function sampev.onServerMessage(color, text)
        pcall(function()
            if type(text) == 'string' and text ~= '' then queueChat(text) end
        end)
        if prevMsg then
            local ok, a = pcall(prevMsg, color, text)
            if ok then return a end
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
    imgui.GetStyle().WindowPadding = imgui.ImVec2(10, 10)
    imgui.GetStyle().FramePadding = imgui.ImVec2(10, 6)
    imgui.GetStyle().ItemSpacing = imgui.ImVec2(8, 8)
    imgui.GetStyle().ItemInnerSpacing = imgui.ImVec2(4, 2)
    imgui.GetStyle().TouchExtraPadding = imgui.ImVec2(0, 0)
    imgui.GetStyle().IndentSpacing = 12
    imgui.GetStyle().ScrollbarSize = 8
    imgui.GetStyle().GrabMinSize = 10
    imgui.GetStyle().WindowBorderSize = 0
    imgui.GetStyle().ChildBorderSize = 0
    imgui.GetStyle().PopupBorderSize = 0
    imgui.GetStyle().FrameBorderSize = 0
    imgui.GetStyle().TabBorderSize = 0
    imgui.GetStyle().WindowRounding = 10
    imgui.GetStyle().ChildRounding = 8
    imgui.GetStyle().FrameRounding = 6
    imgui.GetStyle().PopupRounding = 8
    imgui.GetStyle().ScrollbarRounding = 8
    imgui.GetStyle().GrabRounding = 4
    imgui.GetStyle().TabRounding = 6

    imgui.GetStyle().Colors[imgui.Col.Text]                   = ImVec4(0.91, 0.92, 0.94, 1.00)
    imgui.GetStyle().Colors[imgui.Col.TextDisabled]           = ImVec4(0.55, 0.57, 0.63, 1.00)
    imgui.GetStyle().Colors[imgui.Col.WindowBg]               = ImVec4(0.055, 0.06, 0.08, 0.96)
    imgui.GetStyle().Colors[imgui.Col.ChildBg]                = ImVec4(0.07, 0.08, 0.11, 0.55)
    imgui.GetStyle().Colors[imgui.Col.PopupBg]                = ImVec4(0.09, 0.10, 0.13, 0.98)
    imgui.GetStyle().Colors[imgui.Col.Border]                 = ImVec4(1.00, 1.00, 1.00, 0.06)
    imgui.GetStyle().Colors[imgui.Col.BorderShadow]           = ImVec4(0.00, 0.00, 0.00, 0.00)
    imgui.GetStyle().Colors[imgui.Col.FrameBg]                = ImVec4(1.00, 1.00, 1.00, 0.05)
    imgui.GetStyle().Colors[imgui.Col.FrameBgHovered]         = ImVec4(0.36, 0.58, 1.00, 0.22)
    imgui.GetStyle().Colors[imgui.Col.FrameBgActive]          = ImVec4(0.36, 0.58, 1.00, 0.35)
    imgui.GetStyle().Colors[imgui.Col.TitleBg]                = ImVec4(0.07, 0.08, 0.10, 1.00)
    imgui.GetStyle().Colors[imgui.Col.TitleBgActive]          = ImVec4(0.07, 0.08, 0.10, 1.00)
    imgui.GetStyle().Colors[imgui.Col.TitleBgCollapsed]       = ImVec4(0.07, 0.08, 0.10, 0.75)
    imgui.GetStyle().Colors[imgui.Col.MenuBarBg]             = ImVec4(0.07, 0.08, 0.11, 1.00)
    imgui.GetStyle().Colors[imgui.Col.ScrollbarBg]            = ImVec4(0.00, 0.00, 0.00, 0.00)
    imgui.GetStyle().Colors[imgui.Col.ScrollbarGrab]          = ImVec4(1.00, 1.00, 1.00, 0.12)
    imgui.GetStyle().Colors[imgui.Col.ScrollbarGrabHovered]   = ImVec4(0.36, 0.58, 1.00, 0.45)
    imgui.GetStyle().Colors[imgui.Col.ScrollbarGrabActive]    = ImVec4(0.36, 0.58, 1.00, 1.00)
    imgui.GetStyle().Colors[imgui.Col.CheckMark]              = ImVec4(0.36, 0.58, 1.00, 1.00)
    imgui.GetStyle().Colors[imgui.Col.SliderGrab]             = ImVec4(0.36, 0.58, 1.00, 1.00)
    imgui.GetStyle().Colors[imgui.Col.SliderGrabActive]       = ImVec4(1.00, 1.00, 1.00, 0.90)
    imgui.GetStyle().Colors[imgui.Col.Button]                 = ImVec4(0.36, 0.58, 1.00, 0.28)
    imgui.GetStyle().Colors[imgui.Col.ButtonHovered]          = ImVec4(0.36, 0.58, 1.00, 0.55)
    imgui.GetStyle().Colors[imgui.Col.ButtonActive]           = ImVec4(0.36, 0.58, 1.00, 1.00)
    imgui.GetStyle().Colors[imgui.Col.Header]                 = ImVec4(0.36, 0.58, 1.00, 0.25)
    imgui.GetStyle().Colors[imgui.Col.HeaderHovered]          = ImVec4(0.36, 0.58, 1.00, 0.40)
    imgui.GetStyle().Colors[imgui.Col.HeaderActive]           = ImVec4(0.36, 0.58, 1.00, 1.00)
    imgui.GetStyle().Colors[imgui.Col.Separator]              = ImVec4(1.00, 1.00, 1.00, 0.07)
    imgui.GetStyle().Colors[imgui.Col.SeparatorHovered]       = ImVec4(0.36, 0.58, 1.00, 0.45)
    imgui.GetStyle().Colors[imgui.Col.SeparatorActive]        = ImVec4(0.36, 0.58, 1.00, 0.70)
    imgui.GetStyle().Colors[imgui.Col.ResizeGrip]             = ImVec4(0.36, 0.58, 1.00, 0.25)
    imgui.GetStyle().Colors[imgui.Col.ResizeGripHovered]      = ImVec4(0.36, 0.58, 1.00, 0.55)
    imgui.GetStyle().Colors[imgui.Col.ResizeGripActive]       = ImVec4(0.36, 0.58, 1.00, 0.80)
    imgui.GetStyle().Colors[imgui.Col.Tab]                    = ImVec4(0.16, 0.16, 0.18, 1.00)
    imgui.GetStyle().Colors[imgui.Col.TabHovered]             = ImVec4(0.36, 0.58, 1.00, 0.40)
    imgui.GetStyle().Colors[imgui.Col.TabActive]              = ImVec4(0.36, 0.58, 1.00, 0.55)
    imgui.GetStyle().Colors[imgui.Col.TabUnfocused]          = ImVec4(0.12, 0.12, 0.14, 1.00)
    imgui.GetStyle().Colors[imgui.Col.TabUnfocusedActive]     = ImVec4(0.18, 0.18, 0.20, 1.00)
    imgui.GetStyle().Colors[imgui.Col.PlotLines]              = ImVec4(0.50, 0.50, 0.54, 1.00)
    imgui.GetStyle().Colors[imgui.Col.PlotLinesHovered]       = ImVec4(0.65, 0.65, 0.70, 1.00)
    imgui.GetStyle().Colors[imgui.Col.PlotHistogram]          = ImVec4(0.36, 0.58, 1.00, 0.70)
    imgui.GetStyle().Colors[imgui.Col.PlotHistogramHovered]   = ImVec4(0.36, 0.58, 1.00, 1.00)
    imgui.GetStyle().Colors[imgui.Col.TextSelectedBg]         = ImVec4(0.36, 0.58, 1.00, 0.35)
end
