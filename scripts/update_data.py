import json
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

REGIONS = ["cn", "tw", "us", "eu", "kr"]
TIERS = ["p999", "p990", "p900", "p750", "p600"]
FACTIONS = ["all", "horde", "alliance"]
HEADERS = {"User-Agent": "WoW-Cutoff-Addon/2.0"}
DATA_PATH = Path(__file__).resolve().parent.parent / "Data.lua"


def fetch_json(url: str) -> dict:
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode("utf-8"))


def parse_iso_utc(ts: str | None) -> datetime | None:
    if not ts:
        return None
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def get_latest_season_slug(region: str = "cn", start_exp: int = 10) -> str:
    latest_seasons = []
    exp_id = start_exp
    while True:
        url = f"https://raider.io/api/v1/mythic-plus/static-data?expansion_id={exp_id}"
        try:
            seasons = fetch_json(url).get("seasons", [])
            if seasons:
                latest_seasons = seasons
                exp_id += 1
            else:
                break
        except urllib.error.HTTPError:
            break

    if not latest_seasons:
        raise RuntimeError("Failed to fetch seasons from Raider.IO")

    now = datetime.now(timezone.utc)
    main_seasons = [s for s in latest_seasons if s.get("is_main_season")] or latest_seasons

    for s in main_seasons:
        start_dt = parse_iso_utc(s.get("starts", {}).get(region) or s.get("starts", {}).get("us"))
        end_dt = parse_iso_utc(s.get("ends", {}).get(region) or s.get("ends", {}).get("us"))
        if start_dt and start_dt <= now and (end_dt is None or now <= end_dt):
            return s["slug"]

    started = [
        (parse_iso_utc(s.get("starts", {}).get(region) or s.get("starts", {}).get("us")), s["slug"])
        for s in main_seasons
    ]
    started = [(dt, slug) for dt, slug in started if dt and dt <= now]
    if started:
        started.sort(key=lambda x: x[0], reverse=True)
        return started[0][1]

    return main_seasons[-1]["slug"]


def build_cutoffs_block(season_slug: str) -> str:
    lines = ["ns.Cutoffs = {"]
    for region in REGIONS:
        url = f"https://raider.io/api/v1/mythic-plus/season-cutoffs?season={season_slug}&region={region}"
        try:
            cutoffs = fetch_json(url).get("cutoffs", {})
        except Exception as e:
            print(f"[{region}] skip: {e}")
            continue

        lines.append(f'    ["{region}"] = {{')
        for tier in TIERS:
            parts = []
            for fac in FACTIONS:
                node = cutoffs.get(tier, {}).get(fac, {}) or {}
                val = node.get("quantileMinValue") or 0
                pop = node.get("quantilePopulationCount") or 0
                parts.append(f"{fac} = {{ val = {val}, pop = {pop} }}")
            lines.append(f"        {tier} = {{ {', '.join(parts)} }},")
        lines.append("    },")
    lines.append("}")
    return "\n".join(lines)


def main():
    season_slug = get_latest_season_slug("cn")
    new_cutoffs = build_cutoffs_block(season_slug)

    # 如果分数线内容和上次完全一致，不改写文件，避免无意义的重复发版
    if DATA_PATH.exists():
        old_text = DATA_PATH.read_text(encoding="utf-8")
        marker = "ns.Cutoffs = {"
        if marker in old_text and old_text[old_text.index(marker):].strip() == new_cutoffs.strip():
            print("Cutoffs unchanged, skip updating Data.lua")
            return

    tz_cn = timezone(timedelta(hours=8))
    now_str = datetime.now(tz_cn).strftime("%Y-%m-%d %H:%M")

    content = (
        "local _, ns = ...\n"
        f'ns.SeasonSlug = "{season_slug}"\n'
        f'ns.LastUpdated = "{now_str}"\n'
        f"{new_cutoffs}\n"
    )
    DATA_PATH.write_text(content, encoding="utf-8")
    print(f"Updated Data.lua for {season_slug} at {now_str}")


if __name__ == "__main__":
    main()
