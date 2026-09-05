#!/usr/bin/env python3
"""Rebuild data-only packs and pin catalog/fallback metadata; run after replacing source artwork."""
import base64
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
entries = [
    dict(version=1, id="rift-arena", engine="rift-arena-v1", title="Rift Arena", summary="A two-player platform fighter. Practice, invite a room member, or watch a duel.", arenaName="The Hollow", subtitle="A quiet sky. A friendly rivalry.", accentHex="A2ADBE"),
    dict(version=1, id="fourfold", engine="fourfold-v1", title="Fourfold", summary="A four-in-a-row board game. Play the bot or pass and play on this Mac.", arenaName="Fourfold", subtitle="A thoughtful little rivalry.", accentHex="A2ADBE"),
]
catalog = []
for entry in entries:
    pack = {"schemaVersion": 1, "version": entry["version"], **{key: entry[key] for key in ("id", "engine", "arenaName", "subtitle", "accentHex")}}
    if entry["id"] == "rift-arena":
        for field, filename in [("backgroundImageBase64", "hollow-observatory.jpg"), ("fighterImageBase64", "fighters.png")]:
            artwork = root / "GamePacks" / "source-art" / filename
            if artwork.exists():
                pack[field] = base64.b64encode(artwork.read_bytes()).decode()
    data = (json.dumps(pack, separators=(",", ":")) + "\n").encode()
    path = root / "GamePacks" / entry["id"] / str(entry["version"]) / "pack.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    catalog.append({**{key: entry[key] for key in ("id", "engine", "title", "summary")}, "version": entry["version"],
                    "url": f'https://raw.githubusercontent.com/theShyamsindhia/ALO/main/GamePacks/{entry["id"]}/{entry["version"]}/pack.json',
                    "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
(root / "GamePacks" / "catalog.json").write_text(json.dumps({"schemaVersion": 1, "games": catalog}, indent=2) + "\n")
lines = ["import Foundation", "import ALOCore", "", "// Tiny offline catalog metadata; game artwork/content is downloaded on demand.", "enum GameCatalogFallback {", "    static let games = ["]
for entry in catalog:
    q = json.dumps
    lines.append(f'        GamePackDescriptor(id: {q(entry["id"])}, engine: {q(entry["engine"])}, title: {q(entry["title"])}, summary: {q(entry["summary"])}, version: {entry["version"]}, url: URL(string: {q(entry["url"])})!, sha256: {q(entry["sha256"])}, bytes: {entry["bytes"]}),')
lines += ["    ]", "}", ""]
(root / "Sources" / "ALO" / "GameCatalogFallback.swift").write_text("\n".join(lines))
for entry in catalog:
    print(f'{entry["id"]}: {entry["bytes"]:,} bytes, SHA256 {entry["sha256"]}')
