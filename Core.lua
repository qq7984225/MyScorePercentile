local _, ns = ...

local REGION_MAP = {
    [1] = "us",
    [2] = "kr",
    [3] = "eu",
    [4] = "tw",
    [5] = "cn",
}

------------------------------------------------------------------------
-- 核心算法：对数线性插值估算百分位
------------------------------------------------------------------------
local function CalculatePercentile(score, compact)
    local region = REGION_MAP[GetCurrentRegion()] or "cn"
    local c = ns.Cutoffs and ns.Cutoffs[region]
    if not c or type(score) ~= "number" or score <= 0 then
        return nil
    end

    local anchors = {
        { pct = 0.1,  val = c.p999 or 0, name = "前 0.1% (称号)" },
        { pct = 1.0,  val = c.p990 or 0, name = "前 1%" },
        { pct = 10.0, val = c.p900 or 0, name = "前 10%" },
        { pct = 25.0, val = c.p750 or 0, name = "前 25%" },
        { pct = 40.0, val = c.p600 or 0, name = "前 40%" },
    }

    if anchors[1].val <= 0 then
        return nil
    end

    if score >= anchors[1].val then
        if compact then
            return "|cffff8000前 0.1% (称号线以上)|r"
        end
        return string.format("|cffff8000前 0.1%%|r (高于称号线 +%.1f)", score - anchors[1].val)
    end

    if score < anchors[#anchors].val then
        if compact then
            return "|cffaaaaaa40% 以后|r"
        end
        return string.format("|cffaaaaaa40%% 以后|r (距前 40%% 差 %.1f)", anchors[#anchors].val - score)
    end

    for i = 1, #anchors - 1 do
        local high, low = anchors[i], anchors[i + 1]
        if score >= low.val and score < high.val and high.val > low.val then
            local ratio = (score - low.val) / (high.val - low.val)
            local logPct = math.log(low.pct) + ratio * (math.log(high.pct) - math.log(low.pct))
            local estPct = math.exp(logPct)

            local color = "|cff00ff96"
            if estPct <= 1.0 then
                color = "|cffff4060"
            elseif estPct <= 10.0 then
                color = "|cffa335ee"
            elseif estPct <= 25.0 then
                color = "|cff0070dd"
            end

            if compact then
                return string.format("%s约前 %.2f%%|r", color, estPct)
            end
            return string.format("%s约前 %.2f%%|r (距%s差 %.1f)", color, estPct, high.name, high.val - score)
        end
    end
end

------------------------------------------------------------------------
-- 1. 获取单位分数（暴雪原生 API 优先 + RaiderIO 兜底）
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

------------------------------------------------------------------------
-- 2. 人物鼠标提示（Tooltip）
------------------------------------------------------------------------
local function OnTooltipSetUnit(tooltip)
    if tooltip ~= GameTooltip or InCombatLockdown() then
        return
    end

    local _, unit = tooltip:GetUnit()
    if not unit or (issecretvalue and issecretvalue(unit)) then
        return
    end

    if not UnitIsPlayer(unit) then
        return
    end

    local score = GetUnitMythicPlusScore(unit)
    local pctText = CalculatePercentile(score, true)
    if pctText then
        tooltip:AddDoubleLine("大秘境排名", pctText, 0.7, 0.85, 1.0, 1, 1, 1)
    end
end

TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnTooltipSetUnit)

------------------------------------------------------------------------
-- 3. 集合石（LFG）：申请者列表 & 队伍列表（队长分数）
------------------------------------------------------------------------
if LFGListApplicantMember_OnEnter then
    hooksecurefunc("LFGListApplicantMember_OnEnter", function(self)
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
        if not resultID then return end
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
-- 4. 原生大秘境界面（ChallengesFrame）
------------------------------------------------------------------------
local percentileText

local function UpdateChallengesDisplay()
    if not ChallengesFrame or not ChallengesFrame.WeeklyInfo then
        return
    end

    if not percentileText then
        local parent = ChallengesFrame.WeeklyInfo.Child.DungeonScoreInfo
        percentileText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        percentileText:SetPoint("TOP", parent.Score, "BOTTOM", 0, -4)
    end

    local score = C_ChallengeMode.GetOverallDungeonScore() or 0
    local text = CalculatePercentile(score, false) or "|cffaaaaaa暂无分数线数据|r"
    percentileText:SetText(text)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, addonName)
    if addonName == "Blizzard_ChallengesUI" then
        hooksecurefunc(ChallengesFrame, "Update", UpdateChallengesDisplay)
        self:UnregisterEvent("ADDON_LOADED")
    end
end)

if C_AddOns.IsAddOnLoaded("Blizzard_ChallengesUI") then
    hooksecurefunc(ChallengesFrame, "Update", UpdateChallengesDisplay)
end

------------------------------------------------------------------------
-- 5. 斜杠命令：/msp 查看状态，/msp 3500 模拟查询
------------------------------------------------------------------------
SLASH_MYSCOREPERCENTILE1 = "/msp"
SlashCmdList["MYSCOREPERCENTILE"] = function(msg)
    local testScore = tonumber(msg)
    if testScore then
        local res = CalculatePercentile(testScore, false) or "无数据"
        print(string.format("|cff00ccff[MSP]|r %.1f 分 -> %s", testScore, res))
    else
        local region = REGION_MAP[GetCurrentRegion()] or "cn"
        local myScore = C_ChallengeMode.GetOverallDungeonScore() or 0
        local res = CalculatePercentile(myScore, false) or "无数据"
        print(string.format("|cff00ccff[MSP]|r 赛季: %s | 大区: %s | 更新时间: %s",
            ns.SeasonSlug or "未知", region, ns.LastUpdated or "未知"))
        print(string.format("|cff00ccff[MSP]|r 当前角色 (%.1f 分) -> %s", myScore, res))
    end
end