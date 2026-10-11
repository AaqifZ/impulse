"""Import Raycast's most used emoji into config/emoji-seed.json, most used first.

Raycast keeps an unencrypted emoji database. Each use pushes an emoji's frecencyDate later,
so ordering by that column gives most used and most recent first. The database is opened
read-only and never changed.

    python scripts/import_raycast_emoji.py [--out config/emoji-seed.json]
"""
import json
import sqlite3
import sys
from datetime import date
from pathlib import Path

DATABASE = Path.home() / "Library/Application Support/com.raycast.macos/raycast-emoji.sqlite"


def main():
    out = Path(sys.argv[sys.argv.index("--out") + 1]) if "--out" in sys.argv else Path("config/emoji-seed.json")
    if not DATABASE.exists():
        sys.exit(f"Raycast emoji database not found: {DATABASE}")
    with sqlite3.connect(f"file:{DATABASE}?mode=ro", uri=True) as db:
        rows = db.execute("SELECT symbol FROM emojis WHERE frecencyDate IS NOT NULL ORDER BY frecencyDate DESC").fetchall()
    symbols = [row[0] for row in rows]
    out.parent.mkdir(parents=True, exist_ok=True)
    seed = {"source": "Raycast", "imported": date.today().isoformat(), "symbols": symbols}
    out.write_text(json.dumps(seed, ensure_ascii=False, indent=2) + "\n")
    print(f"ok {len(symbols)} emoji -> {out}")


if __name__ == "__main__":
    main()
