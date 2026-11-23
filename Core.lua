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
