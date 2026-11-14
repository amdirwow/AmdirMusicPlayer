-- Amdir Music Player 1.5.2 — WoW 3.3.5a, Lua 5.1.
-- Songs come from the separate addon AmdirMusicLibrary (Playlist.lua), created by
-- UpdatePlaylist.bat / .sh, so addon updates never delete the user's music.
--
-- Plays via PlaySoundFile(path, "Master"): independent from the WoW music
-- setting and from voice-chat ducking (which only fades Music / Sound /
-- Ambience). Volume = WoW master volume. 3.3.5 cannot stop a single sound,
-- so Stop briefly toggles Sound_EnableAllSound, cutting every playing sound.

local ADDON_NAME = "AmdirMusicPlayer"
local VERSION = "1.5.2"
local tracks = AmdirMusicTracks or {}
local folders = AmdirMusicFolders or {}
local db
local window, minimapButton
local progressBar, progressTimeText, playbackStateText
local playButton, shuffleButton
local nowPlayingText, countText, listInfoText, folderPathText
local emptyText, upButton, downButton, folderUpButton
local rows = {}
local ROW_COUNT, ROW_STEP = 10, 22
local entries = {}
local currentFolder = ""
local offset, selected, current = 0, 1, nil
local playing, trackStartedAt = false, nil
local masterSoundActive = false -- a Master-channel track may still be audible
local history, historyPosition = {}, 0
local lastProgressUpdate = 0
local timers = {}
local playToken = 0

local function Chat(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cff6fd3ff[Amdir Music]|r " .. message)
end

local function After(delay, func)
    table.insert(timers, { at = GetTime() + delay, func = func })
end

local function ValidIndex(index)
    return type(index) == "number" and index >= 1 and index <= #tracks and tracks[index] ~= nil
end

local function FitIndex(index)
    if #tracks == 0 then return nil end
    if index < 1 then return #tracks end
    if index > #tracks then return 1 end
    return index
end

local function GetParentFolder(path)
    return (path or ""):match("^(.*)/[^/]+$") or ""
end

local function FolderExists(path)
    if path == "" then return true end
    for _, folder in ipairs(folders) do
        if folder.path == path then return true end
    end
    return false
end

-- Cuts every sound playing right now (the only way to stop PlaySoundFile in 3.3.5).
-- Toggling Sound_EnableAllSound does NOT stop Master-channel sounds, so the
-- sound system is restarted (same as "Okay" after changing audio hardware).
local cutting = false
local function CutAllSounds(callback)
    if cutting then
        -- A restart is already in progress; just run the callback after it.
        if callback then After(0.8, callback) end
        return
    end
    cutting = true
    if Sound_GameSystem_RestartSoundSystem then
        Sound_GameSystem_RestartSoundSystem()
    else
        SetCVar("Sound_EnableAllSound", "0")
        SetCVar("Sound_EnableAllSound", "1")
    end
    masterSoundActive = false
    db.soundUntil = nil
    -- Give the restarted sound system a moment before playing again.
    After(0.6, function()
        cutting = false
        if callback then callback() end
    end)
end

-- Player volume ---------------------------------------------------------------
-- A Master-channel sound only obeys Sound_MasterVolume. While playing we set the
-- master volume to the player volume and rescale SFX / Music / Ambience in the
-- opposite direction, so the rest of the game keeps its loudness. Restored on Stop.

local GAME_CHANNELS = { "Sound_SFXVolume", "Sound_MusicVolume", "Sound_AmbienceVolume" }
local volumeBase -- { original = {cvar = "string"}, applied = {cvar = number} }

local function ClampVolume(value)
    return math.max(0, math.min(1, tonumber(value) or 1))
end

local function ApplyPlayerVolume()
    if not volumeBase then
        volumeBase = { original = {}, applied = {} }
        volumeBase.original.Sound_MasterVolume = GetCVar("Sound_MasterVolume")
        for _, name in ipairs(GAME_CHANNELS) do volumeBase.original[name] = GetCVar(name) end
        -- Backup for /reload or disconnect while playing.
        db.pendingRestore = {}
        for name, value in pairs(volumeBase.original) do db.pendingRestore[name] = value end
    end
    local master0 = ClampVolume(volumeBase.original.Sound_MasterVolume)
    local v = math.max(0.01, ClampVolume(db.volume))
    local function Set(name, value)
        volumeBase.applied[name] = value
        SetCVar(name, string.format("%.3f", value))
    end
    Set("Sound_MasterVolume", v)
    for _, name in ipairs(GAME_CHANNELS) do
        Set(name, math.min(1, ClampVolume(volumeBase.original[name]) * master0 / v))
    end
end

local function RestoreVolume()
    if not volumeBase then return end
    for name, original in pairs(volumeBase.original) do
        local now = tonumber(GetCVar(name))
        local applied = volumeBase.applied[name]
        -- Keep the user's value if they moved that slider in the options meanwhile.
        if not now or not applied or math.abs(now - applied) < 0.002 then
            SetCVar(name, original)
        end
    end
    volumeBase = nil
    db.pendingRestore = nil
end

-------------------------------------------------------------------------------

local function RebuildEntries()
    entries = {}
    for _, folder in ipairs(folders) do
        if (folder.parent or "") == currentFolder then
            table.insert(entries, { type = "folder", folder = folder })
        end
    end
    for index, song in ipairs(tracks) do
        if (song.folder or "") == currentFolder then
            table.insert(entries, { type = "song", index = index })
        end
    end
    local limit = math.max(0, #entries - ROW_COUNT)
    offset = math.max(0, math.min(offset, limit))
end

local function MoveSelectionIntoView()
    for pos, entry in ipairs(entries) do
        if entry.type == "song" and entry.index == selected then
            if pos <= offset then
                offset = pos - 1
            elseif pos > offset + ROW_COUNT then
                offset = pos - ROW_COUNT
            end
            return
        end
    end
end

local function FormatTime(seconds)
    local whole = math.floor(math.max(0, tonumber(seconds) or 0))
    return string.format("%02d:%02d", math.floor(whole / 60), whole % 60)
end

local function UpdateProgress()
    if not progressBar then return end
    if not playing or not ValidIndex(current) or not trackStartedAt then
        progressBar:SetMinMaxValues(0, 1)
        progressBar:SetValue(0)
        progressTimeText:SetText("00:00 / --:--")
        playbackStateText:SetText("|cffff6060Зупинено|r")
        return
    end

    local elapsed = math.max(0, GetTime() - trackStartedAt)
    local duration = tonumber(tracks[current].duration) or 0
    if duration > 0 then
        local position = math.min(elapsed, duration)
        progressBar:SetMinMaxValues(0, duration)
        progressBar:SetValue(position)
        progressTimeText:SetText(FormatTime(position) .. " / " .. FormatTime(duration))
    else
        progressBar:SetMinMaxValues(0, 1)
        progressBar:SetValue(0)
        progressTimeText:SetText(FormatTime(elapsed) .. " / --:--")
    end
    playbackStateText:SetText("|cff40ff40Відтворення|r")
end

local function UpdateUI()
    if not window then return end
    countText:SetText("Треків: " .. #tracks .. "   Папок: " .. #folders)
    folderPathText:SetText("Music" .. (currentFolder == "" and "" or "  >  " .. currentFolder:gsub("/", "  >  ")))

    if playing and ValidIndex(current) then
        nowPlayingText:SetText(tracks[current].title or "Без назви")
    elseif ValidIndex(selected) then
        nowPlayingText:SetText("|cffaaaaaa" .. (tracks[selected].title or "Без назви") .. "|r")
    else
        nowPlayingText:SetText("|cffaaaaaaНемає музики у плейлисті|r")
    end

    shuffleButton:SetText(db.shuffle and "Випадково: ТАК" or "Випадково: НІ")
    playButton:SetText(playing and "Знову" or "Грати")
    listInfoText:SetText(#entries == 0 and "0 / 0" or
        (tostring(offset + 1) .. "-" .. tostring(math.min(offset + ROW_COUNT, #entries)) .. " / " .. tostring(#entries)))
    if #entries == 0 then emptyText:Show() else emptyText:Hide() end
    if offset > 0 then upButton:Enable() else upButton:Disable() end
    if offset < math.max(0, #entries - ROW_COUNT) then downButton:Enable() else downButton:Disable() end
    if currentFolder ~= "" then folderUpButton:Enable() else folderUpButton:Disable() end

    for n = 1, ROW_COUNT do
        local row = rows[n]
        local entry = entries[offset + n]
        if entry then
            row.entry = entry
            row:Show()
            local stripe = (offset + n) % 2 == 0 and 0.07 or 0.03
            if entry.type == "folder" then
                row.icon:SetTexture("Interface\\Icons\\INV_Misc_Bag_08")
                row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
                row.title:SetText((entry.folder.name or "?") .. "  |cff888888>|r")
                row.title:SetTextColor(1, 0.82, 0)
                row:SetBackdropColor(0.25, 0.18, 0.05, 0.35)
            else
                local index = entry.index
                local song = tracks[index]
                row.title:SetText("|cff888888" .. tostring(index) .. ".|r  " .. (song.title or "Без назви"))
                row.icon:SetTexCoord(0, 1, 0, 1)
                if playing and current == index then
                    row.icon:SetTexture("Interface\\Common\\VoiceChat-Speaker")
                    row.title:SetTextColor(0.4, 1, 0.4)
                    row:SetBackdropColor(0.1, 0.35, 0.1, 0.45)
                elseif selected == index then
                    row.icon:SetTexture(nil)
                    row.title:SetTextColor(1, 0.82, 0)
                    row:SetBackdropColor(0.35, 0.28, 0.05, 0.35)
                else
                    row.icon:SetTexture(nil)
                    row.title:SetTextColor(0.9, 0.9, 0.9)
                    row:SetBackdropColor(1, 1, 1, stripe)
                end
            end
        else
            row.entry = nil
            row:Hide()
        end
    end
    UpdateProgress()
end

local function OpenFolder(path)
    if not FolderExists(path) then
        Chat("Такої папки немає в плейлисті: " .. tostring(path))
        return
    end
    currentFolder = path
    db.folder = path
    offset = 0
    RebuildEntries()
    UpdateUI()
end

local function RememberTrack(index)
    if history[historyPosition] == index then return end
    for i = #history, historyPosition + 1, -1 do
        table.remove(history, i)
    end
    table.insert(history, index)
    historyPosition = #history
end

local function StartSound(index, fromHistory, token)
    if token ~= playToken then return end -- a newer Play/Stop superseded this
    local song = tracks[index]
    ApplyPlayerVolume()
    local ok, result = pcall(PlaySoundFile, song.path, "Master")
    if ok then
        masterSoundActive = true
        -- Survives /reload: the sound keeps playing after a UI reload.
        local duration = tonumber(song.duration) or 0
        db.soundUntil = GetTime() + (duration > 0 and duration or 3600)
    end
    if not ok then
        Chat("Не вдалося запустити: " .. tostring(result))
        playing = false
        RestoreVolume()
        UpdateUI()
        return
    end

    selected, current, playing = index, index, true
    trackStartedAt = GetTime()
    db.selected = index
    if not fromHistory then RememberTrack(index) end
    MoveSelectionIntoView()
    UpdateUI()
end

local function PlayAt(index, fromHistory)
    if not ValidIndex(index) then
        Chat("Немає треків. Покладіть MP3/OGG в AddOns\\AmdirMusicLibrary\\Music, запустіть UpdatePlaylist.bat (Linux: scripts/UpdatePlaylist.sh) у папці AmdirMusicPlayer і перезапустіть WoW.")
        return
    end
    local song = tracks[index]
    if type(song.path) ~= "string" or song.path == "" then
        Chat("Не задано шлях для треку №" .. index)
        return
    end
    if GetCVar("Sound_EnableAllSound") == "0" then
        Chat("У WoW вимкнено загальний звук. Увімкніть його в налаштуваннях.")
        return
    end

    playToken = playToken + 1
    local token = playToken
    -- Show the new selection immediately, even while the old sound is being cut.
    selected, current = index, index
    MoveSelectionIntoView()
    UpdateUI()

    if masterSoundActive or cutting then
        CutAllSounds(function() StartSound(index, fromHistory, token) end)
    else
        StartSound(index, fromHistory, token)
    end
end

local function StopTrack()
    playToken = playToken + 1
    playing = false
    trackStartedAt = nil
    -- Always cut on explicit Stop: after /reload a track may still be playing.
    -- Restore volumes only after the sound is cut, so it does not get loud.
    CutAllSounds(function()
        if not playing then RestoreVolume() end
    end)
    UpdateUI()
end

local function NextTrack()
    if #tracks == 0 then PlayAt(1) return end
    if historyPosition < #history then
        historyPosition = historyPosition + 1
        PlayAt(history[historyPosition], true)
        return
    end
    local target
    local previous = current or selected or 1
    if db.shuffle and #tracks > 1 then
        target = math.random(1, #tracks - 1)
        if target >= previous then target = target + 1 end
    else
        target = FitIndex(previous + 1)
    end
    PlayAt(target)
end

local function PreviousTrack()
    if #tracks == 0 then PlayAt(1) return end
    if historyPosition > 1 then
        historyPosition = historyPosition - 1
        PlayAt(history[historyPosition], true)
    else
        PlayAt(FitIndex((current or selected or 1) - 1))
    end
end

local function ScrollEntries(amount)
    offset = math.max(0, math.min(math.max(0, #entries - ROW_COUNT), offset + amount))
    UpdateUI()
end

local function MakeButton(parent, label, width, x, y, handler)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetWidth(width)
    button:SetHeight(25)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    button:SetText(label)
    button:SetScript("OnClick", handler)
    return button
end

local GOLD_R, GOLD_G, GOLD_B = 0.82, 0.68, 0.36

-- Dark inset panel with a thin tooltip-style border (WoW look).
local function MakePanel(parent, width, height)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetWidth(width)
    panel:SetHeight(height)
    panel:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    panel:SetBackdropColor(0, 0, 0, 0.55)
    panel:SetBackdropBorderColor(GOLD_R, GOLD_G, GOLD_B, 0.9)
    return panel
end

local function MakeLine(parent, width, x, y)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetTexture("Interface\\Buttons\\WHITE8x8")
    line:SetGradientAlpha("HORIZONTAL", GOLD_R, GOLD_G, GOLD_B, 0.05, GOLD_R, GOLD_G, GOLD_B, 0.6)
    line:SetWidth(width / 2)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", x, y)
    local line2 = parent:CreateTexture(nil, "ARTWORK")
    line2:SetTexture("Interface\\Buttons\\WHITE8x8")
    line2:SetGradientAlpha("HORIZONTAL", GOLD_R, GOLD_G, GOLD_B, 0.6, GOLD_R, GOLD_G, GOLD_B, 0.05)
    line2:SetWidth(width / 2)
    line2:SetHeight(1)
    line2:SetPoint("LEFT", line, "RIGHT")
end

local function CreateWindow()
    window = CreateFrame("Frame", "AmdirMusicPlayerFrame", UIParent)
    window:SetWidth(560)
    window:SetHeight(522)
    window:SetFrameStrata("DIALOG")
    window:SetToplevel(true)
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetClampedToScreen(true)
    -- Classic dialog frame: dark background, gold border with ornate corners.
    window:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    window:SetBackdropColor(0.6, 0.6, 0.6, 1)
    window:SetPoint("CENTER", UIParent, "CENTER", db.x or 0, db.y or 0)
    window:SetScript("OnDragStart", function(self) self:StartMoving() end)
    window:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local x, y = self:GetCenter()
        local ux, uy = UIParent:GetCenter()
        if x and y and ux and uy then
            db.x = math.floor(x - ux + 0.5)
            db.y = math.floor(y - uy + 0.5)
        end
    end)
    window:SetScript("OnShow", function() PlaySound("igCharacterInfoOpen") end)
    window:SetScript("OnHide", function() PlaySound("igCharacterInfoClose") end)
    tinsert(UISpecialFrames, "AmdirMusicPlayerFrame") -- Esc closes the window

    -- Header plate with the title
    local header = window:CreateTexture(nil, "ARTWORK")
    header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    header:SetWidth(330)
    header:SetHeight(64)
    header:SetPoint("TOP", 0, 12)
    local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", header, "TOP", 0, -14)
    title:SetText("Amdir |cff6fd3ffMusic Player|r")

    local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", window, "TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() window:Hide() end)

    -- "Now playing" panel ---------------------------------------------------
    local nowPanel = MakePanel(window, 524, 86)
    nowPanel:SetPoint("TOPLEFT", 18, -30)

    local iconFrame = CreateFrame("Frame", nil, nowPanel)
    iconFrame:SetWidth(44)
    iconFrame:SetHeight(44)
    iconFrame:SetPoint("TOPLEFT", 10, -10)
    local icon = iconFrame:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Note_01")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon:SetPoint("TOPLEFT", 3, -3)
    icon:SetPoint("BOTTOMRIGHT", -3, 3)
    local iconBorder = iconFrame:CreateTexture(nil, "OVERLAY")
    iconBorder:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    iconBorder:SetPoint("TOPLEFT", -13, 13)
    iconBorder:SetPoint("BOTTOMRIGHT", 13, -13)

    nowPlayingText = nowPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    nowPlayingText:SetPoint("TOPLEFT", 62, -12)
    nowPlayingText:SetWidth(450)
    nowPlayingText:SetJustifyH("LEFT")
    nowPlayingText:SetWordWrap(false)

    playbackStateText = nowPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    playbackStateText:SetPoint("TOPLEFT", 62, -32)

    countText = nowPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    countText:SetPoint("TOPRIGHT", -12, -33)

    local barFrame = CreateFrame("Frame", nil, nowPanel)
    barFrame:SetPoint("TOPLEFT", 60, -52)
    barFrame:SetWidth(454)
    barFrame:SetHeight(20)
    barFrame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    barFrame:SetBackdropColor(0.05, 0.05, 0.05, 0.9)
    barFrame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

    progressBar = CreateFrame("StatusBar", nil, barFrame)
    progressBar:SetPoint("TOPLEFT", 3, -3)
    progressBar:SetPoint("BOTTOMRIGHT", -3, 3)
    progressBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    progressBar:SetStatusBarColor(0.95, 0.72, 0.15)
    progressBar:SetMinMaxValues(0, 1)
    progressBar:SetValue(0)

    progressTimeText = progressBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    progressTimeText:SetPoint("CENTER", 0, 0)

    -- Transport buttons -----------------------------------------------------
    MakeButton(window, "<< Назад", 94, 20, -124, PreviousTrack)
    playButton = MakeButton(window, "Грати", 83, 122, -124, function() PlayAt(selected) end)
    MakeButton(window, "Стоп", 77, 213, -124, function() StopTrack() end)
    MakeButton(window, "Далі >>", 91, 298, -124, NextTrack)
    shuffleButton = MakeButton(window, "Випадково: НІ", 143, 397, -124, function()
        db.shuffle = not db.shuffle
        UpdateUI()
    end)

    -- Volume ----------------------------------------------------------------
    local volumeLabel = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    volumeLabel:SetPoint("TOPLEFT", 26, -167)
    volumeLabel:SetText("Гучність плеєра:")

    local volumeSlider = CreateFrame("Slider", "AmdirMusicVolumeSlider", window, "OptionsSliderTemplate")
    volumeSlider:SetWidth(250)
    volumeSlider:SetHeight(16)
    volumeSlider:SetPoint("TOPLEFT", 184, -165)
    volumeSlider:SetMinMaxValues(0.05, 1)
    volumeSlider:SetValueStep(0.05)
    _G[volumeSlider:GetName() .. "Low"]:SetText("5%")
    _G[volumeSlider:GetName() .. "High"]:SetText("100%")
    _G[volumeSlider:GetName() .. "Text"]:SetText("")
    local volumePercent = window:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    volumePercent:SetPoint("LEFT", volumeSlider, "RIGHT", 16, 0)
    volumeSlider:SetValue(ClampVolume(db.volume))
    volumePercent:SetText(math.floor(ClampVolume(db.volume) * 100 + 0.5) .. "%")
    volumeSlider:SetScript("OnValueChanged", function(self, value)
        db.volume = math.floor(ClampVolume(value) * 20 + 0.5) / 20
        volumePercent:SetText(math.floor(db.volume * 100 + 0.5) .. "%")
        if volumeBase then ApplyPlayerVolume() end
    end)
    volumeSlider:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Гучність плеєра")
        GameTooltip:AddLine("Під час відтворення змінює «Загальну гучність» WoW,", 1, 1, 1)
        GameTooltip:AddLine("а «Звук», «Музика» і «Світ» підлаштовуються,", 1, 1, 1)
        GameTooltip:AddLine("щоб гра звучала як раніше. «Стоп» усе повертає.", 1, 1, 1)
        GameTooltip:Show()
    end)
    volumeSlider:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Library panel ---------------------------------------------------------
    local listPanel = MakePanel(window, 524, 280)
    listPanel:SetPoint("TOPLEFT", 18, -204)

    local folderIcon = listPanel:CreateTexture(nil, "ARTWORK")
    folderIcon:SetTexture("Interface\\Icons\\INV_Misc_Bag_08")
    folderIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    folderIcon:SetWidth(18)
    folderIcon:SetHeight(18)
    folderIcon:SetPoint("TOPLEFT", 12, -12)

    folderPathText = listPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    folderPathText:SetPoint("LEFT", folderIcon, "RIGHT", 6, 0)
    folderPathText:SetWidth(300)
    folderPathText:SetJustifyH("LEFT")
    folderPathText:SetWordWrap(false)

    listInfoText = listPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    listInfoText:SetPoint("TOPRIGHT", -100, -16)

    folderUpButton = CreateFrame("Button", nil, listPanel, "UIPanelButtonTemplate")
    folderUpButton:SetWidth(80)
    folderUpButton:SetHeight(22)
    folderUpButton:SetPoint("TOPRIGHT", -10, -9)
    folderUpButton:SetText("Вгору")
    folderUpButton:SetScript("OnClick", function() OpenFolder(GetParentFolder(currentFolder)) end)

    MakeLine(listPanel, 500, 12, -38)

    local rowArea = CreateFrame("Frame", nil, listPanel)
    rowArea:SetPoint("TOPLEFT", 8, -44)
    rowArea:SetWidth(482)
    rowArea:SetHeight(ROW_COUNT * ROW_STEP)
    rowArea:EnableMouseWheel(true)
    rowArea:SetScript("OnMouseWheel", function(self, delta) ScrollEntries(-delta * 2) end)

    for n = 1, ROW_COUNT do
        local row = CreateFrame("Button", nil, rowArea)
        row:SetWidth(482)
        row:SetHeight(ROW_STEP - 2)
        row:SetPoint("TOPLEFT", rowArea, "TOPLEFT", 0, -(n - 1) * ROW_STEP)
        row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetWidth(16)
        row.icon:SetHeight(16)
        row.icon:SetPoint("LEFT", 4, 0)
        row.title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.title:SetPoint("LEFT", 26, 0)
        row.title:SetWidth(450)
        row.title:SetJustifyH("LEFT")
        row.title:SetWordWrap(false)
        row:SetScript("OnClick", function(self)
            local entry = self.entry
            if not entry then return end
            if entry.type == "folder" then
                OpenFolder(entry.folder.path)
            else
                PlayAt(entry.index)
            end
        end)
        row:EnableMouseWheel(true)
        row:SetScript("OnMouseWheel", function(self, delta) ScrollEntries(-delta * 2) end)
        rows[n] = row
    end

    upButton = CreateFrame("Button", nil, listPanel, "UIPanelScrollUpButtonTemplate")
    upButton:SetPoint("TOPRIGHT", -9, -46)
    upButton:SetScript("OnClick", function() ScrollEntries(-1) end)
    downButton = CreateFrame("Button", nil, listPanel, "UIPanelScrollDownButtonTemplate")
    downButton:SetPoint("BOTTOMRIGHT", -9, 12)
    downButton:SetScript("OnClick", function() ScrollEntries(1) end)
    local track = listPanel:CreateTexture(nil, "BACKGROUND")
    track:SetTexture("Interface\\Buttons\\WHITE8x8")
    track:SetVertexColor(0, 0, 0, 0.5)
    track:SetWidth(8)
    track:SetPoint("TOP", upButton, "BOTTOM", 0, -2)
    track:SetPoint("BOTTOM", downButton, "TOP", 0, 2)

    emptyText = listPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    emptyText:SetPoint("CENTER", rowArea, "CENTER", 0, 5)
    emptyText:SetWidth(440)
    emptyText:SetText("У цій папці немає пісень.\n\n1. Запустіть UpdatePlaylist.bat у папці AddOns\\AmdirMusicPlayer\n2. Покладіть MP3/OGG в AddOns\\AmdirMusicLibrary\\Music\n3. Ще раз UpdatePlaylist.bat і повністю перезапустіть WoW\n|cff888888Linux: bash scripts/UpdatePlaylist.sh|r")

    local versionText = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    versionText:SetPoint("BOTTOMRIGHT", -22, 18)
    versionText:SetText("Amdir  v" .. VERSION)

    local footer = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("BOTTOM", 0, 18)
    footer:SetText("/music   /music next   /music stop   /music help")

    window:Hide()
    UpdateUI()
end

local function ToggleWindow()
    if not window then
        Chat("Вікно не ініціалізовано. Спробуйте /reload або перезапустіть WoW.")
        return
    end
    if window:IsShown() then window:Hide() else window:Show(); UpdateUI() end
end

-- Minimap button: standard round button, drag it around the minimap edge.
local function UpdateMinimapButtonPosition()
    local angle = math.rad(db.minimapAngle or 220)
    local radius = (Minimap:GetWidth() / 2) + 10
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function CreateMinimapButton()
    minimapButton = CreateFrame("Button", "AmdirMusicPlayerMinimapButton", Minimap)
    minimapButton:SetWidth(31)
    minimapButton:SetHeight(31)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)
    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapButton:RegisterForDrag("LeftButton")
    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local background = minimapButton:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetWidth(20)
    background:SetHeight(20)
    background:SetPoint("TOPLEFT", 7, -5)

    local icon = minimapButton:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Note_01")
    icon:SetWidth(17)
    icon:SetHeight(17)
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local border = minimapButton:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetWidth(53)
    border:SetHeight(53)
    border:SetPoint("TOPLEFT")

    minimapButton:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            if playing then StopTrack() else PlayAt(selected) end
        else
            ToggleWindow()
        end
    end)
    minimapButton:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            db.minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
            UpdateMinimapButtonPosition()
        end)
    end)
    minimapButton:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    minimapButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Amdir |cff6fd3ffMusic Player|r")
        if playing and ValidIndex(current) then
            GameTooltip:AddLine(tracks[current].title or "", 0.48, 1, 0.6)
        end
        GameTooltip:AddLine("ЛКМ: відкрити плеєр", 1, 1, 1)
        GameTooltip:AddLine("ПКМ: грати / стоп", 1, 1, 1)
        GameTooltip:AddLine("Тягни, щоб перемістити", 0.75, 0.85, 1)
        GameTooltip:Show()
    end)
    minimapButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    UpdateMinimapButtonPosition()
    if db.hideMinimap then minimapButton:Hide() end
end

local function Initialize()
    tracks = AmdirMusicTracks or {}
    folders = AmdirMusicFolders or {}
    if type(AmdirMusicPlayerDB) ~= "table" then AmdirMusicPlayerDB = {} end
    db = AmdirMusicPlayerDB
    if db.shuffle == nil then db.shuffle = false end
    db.mode, db.muteGameMusic, db.playerVolume = nil, nil, nil -- old settings
    if db.volume == nil then db.volume = ClampVolume(GetCVar("Sound_MasterVolume")) end
    db.volume = math.max(0.05, ClampVolume(db.volume))
    selected = tonumber(db.selected) or 1
    if not ValidIndex(selected) then selected = 1 end
    currentFolder = db.folder or ""
    if not FolderExists(currentFolder) then currentFolder = "" end
    -- Restore CVars left changed by an older version of the addon.
    if type(db.pendingRestore) == "table" then
        for name, value in pairs(db.pendingRestore) do SetCVar(name, value) end
    end
    db.pendingRestore = nil
    -- A track started before /reload may still be audible: cut it before the next one.
    masterSoundActive = (tonumber(db.soundUntil) or 0) > GetTime()
    RebuildEntries()
    CreateWindow()
    CreateMinimapButton()
    MoveSelectionIntoView()
    UpdateUI()
end

SLASH_AMDIRMUSICPLAYER1 = "/music"
SLASH_AMDIRMUSICPLAYER2 = "/mp"
SlashCmdList["AMDIRMUSICPLAYER"] = function(msg)
    if not db then return end
    msg = string.lower((msg or ""):match("^%s*(.-)%s*$"))
    if msg == "" or msg == "show" or msg == "open" then
        ToggleWindow()
    elseif msg == "play" then
        PlayAt(selected)
    elseif msg == "stop" then
        StopTrack()
    elseif msg == "next" then
        NextTrack()
    elseif msg == "prev" or msg == "previous" then
        PreviousTrack()
    elseif msg == "shuffle" then
        db.shuffle = not db.shuffle
        Chat("Випадково: " .. (db.shuffle and "ТАК" or "НІ"))
        UpdateUI()
    elseif msg == "minimap" then
        db.hideMinimap = not db.hideMinimap
        if db.hideMinimap then minimapButton:Hide() else minimapButton:Show() end
    elseif msg == "root" then
        OpenFolder("")
    elseif msg == "up" then
        OpenFolder(GetParentFolder(currentFolder))
    elseif msg == "list" then
        Chat("Знайдено треків: " .. #tracks .. ", папок: " .. #folders)
        for i, song in ipairs(tracks) do
            local label = song.folder ~= "" and song.folder and (song.folder .. "/") or ""
            Chat(i .. ". " .. label .. (song.title or "Без назви"))
        end
    elseif msg == "help" then
        Chat("/music [play | stop | next | prev | shuffle | minimap | root | up | list | НОМЕР]")
    else
        local number = tonumber(msg)
        if number and number == math.floor(number) then
            PlayAt(number)
        else
            Chat("Невідома команда. Введіть /music help")
        end
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGOUT")
events:SetScript("OnEvent", function(self, event, addon)
    if event == "ADDON_LOADED" and addon == ADDON_NAME then
        Initialize()
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGOUT" then
        local backup = db.pendingRestore
        RestoreVolume()
        db.pendingRestore = backup -- applied again on next login, just in case
    end
end)

events:SetScript("OnUpdate", function(self, elapsed)
    -- Timers
    if #timers > 0 then
        local now = GetTime()
        local due = {}
        for i = #timers, 1, -1 do
            if timers[i].at <= now then
                table.insert(due, 1, timers[i].func)
                table.remove(timers, i)
            end
        end
        for _, func in ipairs(due) do func() end
    end

    lastProgressUpdate = lastProgressUpdate + elapsed
    if lastProgressUpdate < 0.3 then return end
    lastProgressUpdate = 0
    if not playing or not trackStartedAt or not ValidIndex(current) then return end

    -- Auto-advance when the track (by its known duration) has finished.
    local duration = tonumber(tracks[current].duration) or 0
    if duration > 0 and GetTime() - trackStartedAt >= duration + 0.5 then
        masterSoundActive = false -- it ended by itself; no need to cut sounds
        NextTrack()
        return
    end
    if window and window:IsShown() then UpdateProgress() end
end)
