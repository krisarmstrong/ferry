#!/usr/bin/env python3
"""Renders docs/user-guide.md from Sources/FerryUI/help.json.

The guide carries the app's Help word for word, plus an Install section. Edit help.json, then
run `make guide`. UserGuideMirrorTests runs this with --stdout and fails if the committed guide
differs by a byte.

Usage: user-guide.py            write docs/user-guide.md
       user-guide.py --stdout   print the guide instead
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HELP = ROOT / "Sources/FerryUI/help.json"
GUIDE = ROOT / "docs/user-guide.md"
SPEC = re.compile(r"%(?:\d+\$)?(?:@|lld|llu|ld|lu|d|u)")

HEADER = [
    "# Ferry user guide",
    "",
    "<!-- Generated from Sources/FerryUI/help.json by `make guide`. Edit help.json, not this file. -->",
    "",
    "Ferry shows Android devices as locations in Finder on your Mac. It was built first for "
    "network testers, the LinkRunner 10G, EtherScope nXG and LinkRunner 100G, and it works with "
    "other Android phones too.",
    "",
    "This guide holds the same help as **Help** in the Ferry menu, plus how to install Ferry. "
    "Ferry is free and open source (MIT). It needs macOS 26 or later on an Apple silicon Mac.",
    "",
]

INSTALL = [
    "## Install",
    "",
    "Download Ferry from the [latest release](https://github.com/krisarmstrong/ferry/releases/"
    "latest), move **Ferry** to the **Applications** folder and open it. After that, Ferry keeps "
    "itself up to date (see **Updates**).",
    "",
    "Ferry runs in the menu bar. It has no Dock icon and no main window. Until its helper "
    "answers, the menu shows **Checking…**.",
    "",
]


def wording(key):
    """A message as the reader sees it: each value it is shown with as "…"."""
    return SPEC.sub("…", key).replace("%%", "%")


def anchor(title):
    """The anchor GitHub gives a heading."""
    return re.sub(r"[^\w\- ]", "", title.lower()).replace(" ", "-")


def body(block, out):
    for paragraph in block.get("paragraphs", []):
        out += [paragraph, ""]
    steps = block.get("steps", [])
    out += [f"{number}. {step}" for number, step in enumerate(steps, 1)]
    if steps:
        out.append("")
    definitions = block.get("definitions", [])
    out += [f"- **{d['term']}**: {d['detail']}" for d in definitions]
    if definitions:
        out.append("")
    if "note" in block:
        out += [block["note"], ""]
    if "link" in block:
        link = block["link"]
        what = "setup guide" if link["target"].startswith("guide") else "USB debugging steps"
        out += [f"In the app, **{link['title']}** opens the {what}.", ""]
    if block.get("action") == "removeFerry":
        out += [
            "The **Remove Ferry…** button is here in Ferry Help. Ferry asks you to confirm first.",
            "",
        ]
    if block.get("action") == "showWelcome":
        out += ["In Ferry Help, **Show Welcome Window** opens the welcome again.", ""]
    for message in block.get("messages", []):
        out += [f"**{wording(message['message'])}**", "", message["cause"], "", message["fix"], ""]


def render(help_content):
    out = list(HEADER) + ["## Contents", "", "- [Install](#install)"]
    for category in help_content["categories"]:
        out.append(f"- [{category['title']}](#{anchor(category['title'])})")
        out += [f"  - [{t['title']}](#{anchor(t['title'])})" for t in category["topics"]]
    out += [""] + INSTALL
    for category in help_content["categories"]:
        out += [f"## {category['title']}", ""]
        for topic in category["topics"]:
            out += [f"### {topic['title']}", ""]
            body(topic, out)
            for group in topic.get("groups", []):
                out += [f"#### {group['title']}", ""]
                body(group, out)
    while out and out[-1] == "":
        out.pop()
    return "\n".join(out) + "\n"


def main():
    guide = render(json.loads(HELP.read_text(encoding="utf-8")))
    if sys.argv[1:] == ["--stdout"]:
        sys.stdout.write(guide)
    elif not sys.argv[1:]:
        GUIDE.write_text(guide, encoding="utf-8")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
