local ADDON_NAME, ns = ...

local REGION_MAP = {
    [1] = "us",
    [2] = "kr",
    [3] = "eu",
    [4] = "tw",
    [5] = "cn",
}

local FACTION_LABELS = {
    all = "所有阵营",
    horde = "仅部落",
    alliance = "仅联盟",
}

local TIER_META = {
    { key = "p999", pct = 0.1,  label = "前 0.1%", sub = "赛季称号", color = { 1.00, 0.50, 0.00 } },
    { key = "p990", pct = 1.0,  label = "前 1%",   sub = "",         color = { 0.95, 0.25, 0.35 } },
    { key = "p900", pct = 10.0, label = "前 10%",  sub = "",         color = { 0.68, 0.28, 0.92 } },
    { key = "p750", pct = 25.0, label = "前 25%",  sub = "",         color = { 0.20, 0.52, 0.98 } },
    { key = "p600", pct = 40.0, label = "前 40%",  sub = "",         color = { 0.16, 0.72, 0.85 } },
}

local DEFAULTS = {
    factionMode = "all",
    showChallenges = true,
    showUnitTooltip = true,
    showLFGTooltip = true,
    showMinimap = true,
    minimapAngle = 225,
}

local function GetDB()
    if type(MyScorePercentileDB) ~= "table" then
        MyScorePercentileDB = {}
    end
    for k, v in pairs(DEFAULTS) do
        if MyScorePercentileDB[k] == nil then
            MyScorePercentileDB[k] = v
        end
    end
    return MyScorePercentileDB
end

local function GetRegion()
    return REGION_MAP[GetCurrentRegion()] or "cn"
end

-- 兼容旧版数字格式与新版全阵营表格式
local function GetTierData(regionData, tierKey, faction)
    if not regionData or not regionData[tierKey] then
        return 0, 0
    end
    local entry = regionData[tierKey]
    if type(entry) == "number" then
        return entry, 0
    end
    local f = entry[faction] or entry.all
    if type(f) == "table" then
        return f.val or 0, f.pop or 0
    end
    return 0, 0
end

------------------------------------------------------------------------
-- 核心算法：对数线性插值估算百分位
------------------------------------------------------------------------
local function CalculatePercentile(score, compact, overrideFaction)
    local db = GetDB()
    local faction = overrideFaction or db.factionMode or "all"
    local c = ns.Cutoffs and ns.Cutoffs[GetRegion()]
    if not c or type(score) ~= "number" or score <= 0 then
        return nil, nil
    end

    local anchors = {}
    for _, meta in ipairs(TIER_META) do
        local val = GetTierData(c, meta.key, faction)
        anchors[#anchors + 1] = {
            key = meta.key,
            pct = meta.pct,
            val = val,
            name = meta.label,
        }
    end

    if anchors[1].val <= 0 then
        return nil, nil
    end

    if score >= anchors[1].val then
        if compact then
            return "|cffff8000前 0.1% (称号线以上)|r", "p999"
        end
        return string.format("|cffff8000前 0.1%%|r (高于称号线 +%.1f)", score - anchors[1].val), "p999"
    end

    if score < anchors[#anchors].val then
        if compact then
            return "|cffaaaaaa40% 以后|r", nil
        end
        return string.format("|cffaaaaaa40%% 以后|r (距前 40%% 差 %.1f)", anchors[#anchors].val - score), nil
    end

    for i = 1, #anchors - 1 do
        local high, low = anchors[i], anchors[i + 1]
        if score >= low.val and score < high.val and high.val > low.val then
            local ratio = (score - low.val) / (high.val - low.val)
            local logPct = math.log(low.pct) + ratio * (math.log(high.pct) - math.log(low.pct))
            local estPct = math.exp(logPct)

            local color = "|cff28b8d8"
            if estPct <= 1.0 then
                color = "|cffff4060"
            elseif estPct <= 10.0 then
                color = "|cffa335ee"
            elseif estPct <= 25.0 then
                color = "|cff3385ff"
            end

            if compact then
                return string.format("%s约前 %.2f%%|r", color, estPct), low.key
            end
            return string.format("%s约前 %.2f%%|r (距%s差 %.1f)", color, estPct, high.name, high.val - score), low.key
        end
    end
end

------------------------------------------------------------------------
-- 1. 单位分数获取 & 鼠标提示 Hook
------------------------------------------------------------------------
local function GetUnitMythicPlusScore(unit)
    local summary = C_PlayerInfo.GetPlayerMythicPlusRatingSummary(unit)
    if summary and summary.currentSeasonScore and summary.currentSeasonScore > 0 then
        return summary.currentSeasonScore
    end
    if RaiderIO and RaiderIO.GetProfile then
        local profile = RaiderIO.GetProfile(unit)
        if profile and profile.mythicKeystoneProfile and profile.mythicKeystoneProfile.currentScore then
            return profile.mythicKeystoneProfile.currentScore
        end
    end
    return 0
end

local function OnTooltipSetUnit(tooltip)
    if not GetDB().showUnitTooltip then return end
    if tooltip ~= GameTooltip or InCombatLockdown() then return end

    local _, unit = tooltip:GetUnit()
    if not unit or (issecretvalue and issecretvalue(unit)) then return end
    if not UnitIsPlayer(unit) then return end

    local score = GetUnitMythicPlusScore(unit)
    local pctText = CalculatePercentile(score, true)
    if pctText then
        tooltip:AddDoubleLine("大秘境排名", pctText, 0.7, 0.85, 1.0, 1, 1, 1)
    end
end

TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnTooltipSetUnit)

------------------------------------------------------------------------
-- 2. 集合石（LFG）提示 Hook
------------------------------------------------------------------------
if LFGListApplicantMember_OnEnter then
    hooksecurefunc("LFGListApplicantMember_OnEnter", function(self)
        if not GetDB().showLFGTooltip then return end
        local parent = self and self:GetParent()
        local applicantID = parent and parent.applicantID
        local memberIdx = self and self.memberIdx
        if not applicantID or not memberIdx then return end

        local dungeonScore = select(12, C_LFGList.GetApplicantMemberInfo(applicantID, memberIdx))
        local pctText = CalculatePercentile(dungeonScore, true)
        if pctText then
            GameTooltip:AddDoubleLine("大秘境排名", pctText, 0.7, 0.85, 1.0, 1, 1, 1)
            GameTooltip:Show()
        end
    end)
end

if LFGListUtil_SetSearchEntryTooltip then
    hooksecurefunc("LFGListUtil_SetSearchEntryTooltip", function(tooltip, resultID)
        if not GetDB().showLFGTooltip or not resultID then return end
        local info = C_LFGList.GetSearchResultInfo(resultID)
        if not info or not info.leaderOverallDungeonScore then return end

        local pctText = CalculatePercentile(info.leaderOverallDungeonScore, true)
        if pctText then
            tooltip:AddDoubleLine("队长大秘境排名", pctText, 0.7, 0.85, 1.0, 1, 1, 1)
            tooltip:Show()
        end
    end)
end

------------------------------------------------------------------------
-- 3. 原生大秘境界面（ChallengesFrame）显示 + 快捷按钮
------------------------------------------------------------------------
local percentileText
local openPanelBtn
local ToggleMainPanel
local UpdateMinimapButton

local function UpdateChallengesDisplay()
    if not ChallengesFrame or not ChallengesFrame.WeeklyInfo then return end
    local child = ChallengesFrame.WeeklyInfo.Child
    local parent = child and child.DungeonScoreInfo
    if not parent then return end

    if not percentileText then
        percentileText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        percentileText:SetDrawLayer("OVERLAY", 7)
        local anchor = parent.Score or parent
        percentileText:SetPoint("TOP", anchor, "BOTTOM", 0, -2)
    end

    if not openPanelBtn then
        openPanelBtn = CreateFrame("Button", nil, ChallengesFrame, "UIPanelButtonTemplate")
        openPanelBtn:SetSize(64, 22)
        openPanelBtn:SetPoint("TOPRIGHT", ChallengesFrame, "TOPRIGHT", -34, -4)
        openPanelBtn:SetText("分数线")
        openPanelBtn:SetScript("OnClick", function()
            if ToggleMainPanel then ToggleMainPanel() end
        end)
    end

    if not GetDB().showChallenges then
        percentileText:Hide()
        return
    end

    local score = C_ChallengeMode.GetOverallDungeonScore() or 0
    local text = CalculatePercentile(score, false) or "|cffaaaaaa暂无分数线数据|r"
    percentileText:SetText(text)
    percentileText:Show()
end

------------------------------------------------------------------------
-- 4. 独立小地图图标按钮（支持沿边缘拖动 + 悬停预览）
------------------------------------------------------------------------
local minimapBtn

local function SetMinimapButtonPosition(btn, angle)
    local radius = ((Minimap:GetWidth() or 140) / 2) + 5
    local rad = math.rad(angle or 225)
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * radius, math.sin(rad) * radius)
end

UpdateMinimapButton = function()
    if not minimapBtn then return end
    local db = GetDB()
    if db.showMinimap then
        SetMinimapButtonPosition(minimapBtn, db.minimapAngle)
        minimapBtn:Show()
    else
        minimapBtn:Hide()
    end
end

local function CreateMinimapButton()
    if minimapBtn then return minimapBtn end

    local btn = CreateFrame("Button", "MSPMinimapButton", Minimap)
    btn:SetSize(32, 32)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(24, 24)
    bg:SetPoint("CENTER", 0, 0)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 0)
    icon:SetTexture("Interface\\Icons\\INV_Relics_Hourglass")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local mask = btn:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(icon)
    icon:AddMaskTexture(mask)

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    btn:SetScript("OnClick", function()
        if ToggleMainPanel then ToggleMainPanel() end
    end)

    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function(s)
            local mx, my = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            local cx, cy = Minimap:GetCenter()
            if cx and cy then
                local angle = math.deg(math.atan2((my / scale) - cy, (mx / scale) - cx))
                GetDB().minimapAngle = angle
                SetMinimapButtonPosition(s, angle)
            end
        end)
    end)

    btn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("大秘境分数线统计", 1, 0.88, 0.45)
        local myScore = C_ChallengeMode.GetOverallDungeonScore() or 0
        local myText = CalculatePercentile(myScore, false) or "|cffaaaaaa暂无数据|r"
        GameTooltip:AddDoubleLine(string.format("当前角色 (%.1f分)", myScore), myText, 0.8, 0.85, 0.9, 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("左键点击：打开/关闭分数线总表", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("左键拖动：移动图标位置", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)

    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    minimapBtn = btn
    UpdateMinimapButton()
    return btn
end

------------------------------------------------------------------------
-- 5. 游戏内交互总表窗口（MSPMainFrame）
------------------------------------------------------------------------
local mainFrame
local rowWidgets = {}
local factionButtons = {}

local function RefreshMainPanel()
    if not mainFrame or not mainFrame:IsShown() then return end
    local db = GetDB()
    local region = GetRegion()
    local c = ns.Cutoffs and ns.Cutoffs[region]
    local myScore = C_ChallengeMode.GetOverallDungeonScore() or 0
    local myText, myTierKey = CalculatePercentile(myScore, false)

    mainFrame.subTitle:SetText(string.format(
        "赛季: %s   |   大区: %s   |   更新时间: %s",
        ns.SeasonSlug or "未知", string.upper(region), ns.LastUpdated or "未知"
    ))

    for mode, btn in pairs(factionButtons) do
        if db.factionMode == mode then
            btn.bg:SetColorTexture(0.18, 0.45, 0.78, 0.9)
            btn.text:SetTextColor(1, 1, 1)
        else
            btn.bg:SetColorTexture(0.16, 0.16, 0.20, 0.85)
            btn.text:SetTextColor(0.75, 0.75, 0.75)
        end
    end

    for i, meta in ipairs(TIER_META) do
        local row = rowWidgets[i]
        local isCurrentRow = (myTierKey == meta.key)
        if isCurrentRow then
            row.bg:SetColorTexture(0.16, 0.32, 0.22, 0.55)
        else
            local shade = (i % 2 == 0) and 0.11 or 0.08
            row.bg:SetColorTexture(shade, shade, shade + 0.02, 0.85)
        end

        for _, fac in ipairs({ "all", "horde", "alliance" }) do
            local val, pop = GetTierData(c, meta.key, fac)
            local cell = row.cells[fac]
            if val > 0 then
                cell.score:SetText(string.format("%.2f", val))
            else
                cell.score:SetText("--")
            end
            if pop > 0 then
                cell.pop:SetText(string.format("%d个角色", pop))
            else
                cell.pop:SetText("")
            end
        end
    end

    mainFrame.myStatus:SetText(string.format(
        "当前角色 (%.1f 分，按%s):  %s",
        myScore,
        FACTION_LABELS[db.factionMode] or "所有阵营",
        myText or "|cffaaaaaa暂无数据|r"
    ))
end

local function CreateCheckbox(parent, label, x, y, dbKey)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", x, y)
    cb:SetChecked(GetDB()[dbKey])

    local txt = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    txt:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    txt:SetText(label)

    cb:SetScript("OnClick", function(self)
        GetDB()[dbKey] = self:GetChecked() and true or false
        UpdateChallengesDisplay()
        UpdateMinimapButton()
    end)
    return cb
end

local function CreateMainPanel()
    if mainFrame then return mainFrame end

    local f = CreateFrame("Frame", "MSPMainFrame", UIParent, "BackdropTemplate")
    f:SetSize(490, 470)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    f:SetBackdropColor(0.06, 0.06, 0.08, 0.94)
    f:SetBackdropBorderColor(0.28, 0.28, 0.34, 1)
    tinsert(UISpecialFrames, "MSPMainFrame")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -14)
    title:SetText("大秘境分数线统计")
    title:SetTextColor(1, 0.88, 0.45)

    local subTitle = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subTitle:SetPoint("TOP", title, "BOTTOM", 0, -4)
    subTitle:SetTextColor(0.65, 0.65, 0.70)
    f.subTitle = subTitle

    local modeLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    modeLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -60)
    modeLabel:SetText("百分位计算口径：")
    modeLabel:SetTextColor(0.8, 0.8, 0.85)

    local modes = {
        { key = "all",      label = "所有阵营" },
        { key = "horde",    label = "仅部落" },
        { key = "alliance", label = "仅联盟" },
    }
    for idx, m in ipairs(modes) do
        local btn = CreateFrame("Button", nil, f)
        btn:SetSize(78, 22)
        btn:SetPoint("LEFT", modeLabel, "RIGHT", 6 + (idx - 1) * 84, 0)
        btn.bg = btn:CreateTexture(nil, "BACKGROUND")
        btn.bg:SetAllPoints()
        btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        btn.text:SetPoint("CENTER")
        btn.text:SetText(m.label)
        btn:SetScript("OnClick", function()
            GetDB().factionMode = m.key
            RefreshMainPanel()
            UpdateChallengesDisplay()
        end)
        factionButtons[m.key] = btn
    end

    local colX = { tier = 24, all = 150, horde = 265, alliance = 380 }
    local headerY = -92
    local headerBg = f:CreateTexture(nil, "ARTWORK")
    headerBg:SetColorTexture(0.14, 0.14, 0.18, 0.95)
    headerBg:SetPoint("TOPLEFT", f, "TOPLEFT", 16, headerY + 6)
    headerBg:SetSize(458, 24)

    local headers = {
        { x = colX.tier,     text = "分数百分位", color = { 0.85, 0.85, 0.85 } },
        { x = colX.all,      text = "所有阵营",   color = { 0.90, 0.90, 0.90 } },
        { x = colX.horde,    text = "仅部落",     color = { 0.95, 0.35, 0.35 } },
        { x = colX.alliance, text = "仅联盟",     color = { 0.35, 0.65, 1.00 } },
    }
    for _, h in ipairs(headers) do
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", f, "TOPLEFT", h.x, headerY)
        fs:SetText(h.text)
        fs:SetTextColor(h.color[1], h.color[2], h.color[3])
    end

    local rowHeight = 40
    local startY = -114
    for i, meta in ipairs(TIER_META) do
        local row = { cells = {} }
        local y = startY - (i - 1) * (rowHeight + 2)

        row.bg = f:CreateTexture(nil, "ARTWORK")
        row.bg:SetPoint("TOPLEFT", f, "TOPLEFT", 16, y)
        row.bg:SetSize(458, rowHeight)

        local tLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        tLabel:SetPoint("TOPLEFT", f, "TOPLEFT", colX.tier, y - 6)
        tLabel:SetText(meta.label)
        tLabel:SetTextColor(1, 1, 1)

        if meta.sub ~= "" then
            local tSub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            tSub:SetPoint("TOPLEFT", tLabel, "BOTTOMLEFT", 0, -2)
            tSub:SetText(meta.sub)
            tSub:SetTextColor(0.6, 0.6, 0.65)
        end

        for _, fac in ipairs({ "all", "horde", "alliance" }) do
            local scoreFS = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            scoreFS:SetPoint("TOPLEFT", f, "TOPLEFT", colX[fac], y - 5)
            scoreFS:SetTextColor(meta.color[1], meta.color[2], meta.color[3])

            local popFS = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            popFS:SetPoint("TOPLEFT", scoreFS, "BOTTOMLEFT", 0, -2)
            popFS:SetTextColor(0.55, 0.55, 0.60)

            row.cells[fac] = { score = scoreFS, pop = popFS }
        end

        rowWidgets[i] = row
    end

    local myStatus = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    myStatus:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -334)
    f.myStatus = myStatus

    local simLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    simLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -366)
    simLabel:SetText("模拟分数：")

    local simBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    simBox:SetSize(72, 22)
    simBox:SetPoint("LEFT", simLabel, "RIGHT", 6, 0)
    simBox:SetAutoFocus(false)
    simBox:SetNumeric(false)

    local simBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    simBtn:SetSize(52, 22)
    simBtn:SetPoint("LEFT", simBox, "RIGHT", 6, 0)
    simBtn:SetText("计算")

    local simResult = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    simResult:SetPoint("LEFT", simBtn, "RIGHT", 10, 0)
    simResult:SetText("|cff888888输入分数回车测试|r")

    local function RunSim()
        local val = tonumber(simBox:GetText())
        if not val or val <= 0 then
            simResult:SetText("|cffff5555请输入有效数字|r")
            return
        end
        local res = CalculatePercentile(val, false)
        simResult:SetText(res or "|cffaaaaaa无数据|r")
        simBox:ClearFocus()
    end
    simBtn:SetScript("OnClick", RunSim)
    simBox:SetScript("OnEnterPressed", RunSim)
    simBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    CreateCheckbox(f, "大秘境面板", 16, 46, "showChallenges")
    CreateCheckbox(f, "人物鼠标提示", 120, 46, "showUnitTooltip")
    CreateCheckbox(f, "集合石提示", 236, 46, "showLFGTooltip")
    CreateCheckbox(f, "小地图图标", 342, 46, "showMinimap")

    local reloadBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    reloadBtn:SetSize(112, 24)
    reloadBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 14)
    reloadBtn:SetText("重载刷新数据")
    reloadBtn:SetScript("OnClick", function() ReloadUI() end)

    local tip = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tip:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 20)
    tip:SetText("|cff777777提示：云端更新并安装新版后点右侧按钮生效|r")

    f:Hide()
    mainFrame = f
    return f
end

ToggleMainPanel = function()
    local f = CreateMainPanel()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
        RefreshMainPanel()
    end
end

------------------------------------------------------------------------
-- 6. 事件监听与斜杠命令
------------------------------------------------------------------------
local function HookChallengesFrame()
    if not ChallengesFrame or ChallengesFrame._MSPHooked then return end
    ChallengesFrame._MSPHooked = true
    hooksecurefunc(ChallengesFrame, "Update", UpdateChallengesDisplay)
    ChallengesFrame:HookScript("OnShow", UpdateChallengesDisplay)
    if ChallengesFrame:IsShown() then
        UpdateChallengesDisplay()
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(self, event, addonName)
    if event == "ADDON_LOADED" then
        if addonName == ADDON_NAME then
            GetDB()
        elseif addonName == "Blizzard_ChallengesUI" then
            HookChallengesFrame()
        end
    elseif event == "PLAYER_LOGIN" then
        CreateMinimapButton()
    end
end)

if C_AddOns.IsAddOnLoaded("Blizzard_ChallengesUI") then
    HookChallengesFrame()
end

SLASH_MYSCOREPERCENTILE1 = "/msp"
SlashCmdList["MYSCOREPERCENTILE"] = function(msg)
    local testScore = tonumber(msg)
    if testScore then
        local res = CalculatePercentile(testScore, false) or "无数据"
        print(string.format("|cff00ccff[MSP]|r %.1f 分 -> %s", testScore, res))
    else
        ToggleMainPanel()
    end
end
