#!/usr/bin/env python3 -I
"""Adds a release to apps/<slug>/releases.json and regenerates apps/<slug>/appcast.xml (Sparkle 2 feed).

releases.json is the source of truth (newest first); the appcast is always rebuilt from it, so the feed
never contains a half-written item.

Usage:
  appcast.py add --dir apps/mypaste --app-name MyPaste --version 1.1.0 --build 1.1.0 --min-os 14.0 \
                 --url https://... --length 123 --signature BASE64 [--notes "texto"]
  appcast.py latest --dir apps/mypaste      # prints the newest build version (or nothing)
"""
import argparse
import json
import os
import sys
from datetime import datetime, timezone
from email.utils import format_datetime
from xml.sax.saxutils import escape

MAX_ITEMS = 20


def version_key(v):
    return [int(p) if p.isdigit() else p for p in v.replace("-", ".").split(".")]


def load(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def write_appcast(directory, app_name, releases):
    items = []
    for r in releases[:MAX_ITEMS]:
        notes = escape(r.get("notes") or "").replace("\n", "<br/>")
        items.append(f"""    <item>
      <title>{escape(app_name)} {escape(r['shortVersion'])}</title>
      <pubDate>{r['pubDate']}</pubDate>
      <sparkle:version>{escape(r['version'])}</sparkle:version>
      <sparkle:shortVersionString>{escape(r['shortVersion'])}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(r['minimumSystemVersion'])}</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>{notes}</p>]]></description>
      <enclosure url="{escape(r['url'])}" length="{r['length']}" type="application/octet-stream" sparkle:edSignature="{escape(r['signature'])}"/>
    </item>""")
    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>{escape(app_name)}</title>
{chr(10).join(items)}
  </channel>
</rss>
"""
    tmp = os.path.join(directory, "appcast.xml.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(xml)
    os.replace(tmp, os.path.join(directory, "appcast.xml"))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    add = sub.add_parser("add")
    for name in ("dir", "app-name", "version", "build", "min-os", "url", "length", "signature"):
        add.add_argument(f"--{name}", required=True)
    add.add_argument("--notes", default="")
    latest = sub.add_parser("latest")
    latest.add_argument("--dir", required=True)
    args = parser.parse_args()

    releases_path = os.path.join(args.dir, "releases.json")
    releases = load(releases_path)

    if args.command == "latest":
        if releases:
            print(releases[0]["version"])
        return

    if any(r["version"] == args.build for r in releases):
        sys.exit(f"La versión {args.build} ya está en el feed.")
    if releases and version_key(args.build) <= version_key(releases[0]["version"]):
        sys.exit(f"La versión {args.build} debe ser mayor que la última publicada ({releases[0]['version']}).")

    releases.insert(0, {
        "version": args.build,
        "shortVersion": args.version,
        "minimumSystemVersion": args.min_os,
        "url": args.url,
        "length": int(args.length),
        "signature": args.signature,
        "notes": args.notes,
        "pubDate": format_datetime(datetime.now(timezone.utc)),
    })
    os.makedirs(args.dir, exist_ok=True)
    tmp = releases_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(releases, f, indent=2, ensure_ascii=False)
    os.replace(tmp, releases_path)
    write_appcast(args.dir, args.app_name, releases)


if __name__ == "__main__":
    main()
