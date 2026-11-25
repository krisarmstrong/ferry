#!/usr/bin/env python3
"""Renders docs/user-guide.md, and docs/user-guide.es.md in Spanish, from Sources/FerryUI/help.json.

The guide carries the app's Help word for word, plus an Install section. The Spanish guide takes
each string's Spanish from Sources/FerryUI/Localizable.xcstrings, as the app does. Edit
help.json and the catalog, then run `make guide`. UserGuideMirrorTests runs this with --stdout
and fails if a committed guide differs by a byte.

Usage: user-guide.py                      write both guides
       user-guide.py --stdout [en|es]     print one guide instead (English by default)
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HELP = ROOT / "Sources/FerryUI/help.json"
CATALOG = ROOT / "Sources/FerryUI/Localizable.xcstrings"
GUIDES = {"en": ROOT / "docs/user-guide.md", "es": ROOT / "docs/user-guide.es.md"}
SPEC = re.compile(r"%(?:\d+\$)?(?:@|lld|llu|ld|lu|d|u)")

# The guide's own words, around the help's.
TEXT = {
    "en": {
        "header": [
            "# Ferry user guide",
            "",
            "<!-- Generated from Sources/FerryUI/help.json by `make guide`. Edit help.json, not this file. -->",
            "",
            "Ferry shows Android devices as locations in Finder on your Mac. It was built first for "
            "network testers, the LinkRunner 10G, LinkRunner 100G, EtherScope nXG and CyberScope, "
            "and it works with the AirCheck G3 and other Android phones too.",
            "",
            "This guide holds the same help as **Help** in the Ferry menu, plus how to install Ferry. "
            "Ferry is free and open source (MIT). It needs macOS 26 or later on an Apple silicon Mac.",
            "",
        ],
        "contents": "Contents",
        "install_title": "Install",
        "install": [
            "Download Ferry from the [latest release](https://github.com/krisarmstrong/ferry/releases/"
            "latest), move **Ferry** to the **Applications** folder and open it. After that, Ferry "
            "keeps itself up to date (see **Updates**).",
            "",
            "Ferry runs in the menu bar. It has no Dock icon and no main window. Until its helper "
            "answers, the menu shows **Checking…**.",
            "",
        ],
        "link": "In the app, **{title}** opens the {what}.",
        "setup": "setup guide",
        "debugging": "USB debugging steps",
        "remove": "The **Remove Ferry…** button is here in Ferry Help. Ferry asks you to confirm first.",
        "welcome": "In Ferry Help, **Show Welcome Window** opens the welcome again.",
    },
    "es": {
        "header": [
            "# Guía del usuario de Ferry",
            "",
            "<!-- Generado desde Sources/FerryUI/help.json y Localizable.xcstrings con `make guide`. "
            "No edites este archivo. -->",
            "",
            "Ferry muestra los dispositivos Android como ubicaciones en Finder en tu Mac. Se creó "
            "primero para probadores de red, el LinkRunner 10G, el LinkRunner 100G, el EtherScope "
            "nXG y el CyberScope, y también funciona con el AirCheck G3 y otros teléfonos Android.",
            "",
            "Esta guía contiene la misma ayuda que **Ayuda** en el menú de Ferry, y además cómo "
            "instalar Ferry. Ferry es gratuito y de código abierto (MIT). Necesita macOS 26 o "
            "posterior en una Mac con Apple silicon.",
            "",
        ],
        "contents": "Contenido",
        "install_title": "Instalación",
        "install": [
            "Descarga Ferry desde la [versión más reciente](https://github.com/krisarmstrong/ferry/"
            "releases/latest), mueve **Ferry** a la carpeta **Aplicaciones** y ábrelo. A partir de "
            "ahí, Ferry se mantiene actualizado solo (consulta **Actualizaciones**).",
            "",
            "Ferry funciona en la barra de menús. No tiene ícono en el Dock ni ventana principal. "
            "Hasta que su asistente responde, el menú muestra **Comprobando…**.",
            "",
        ],
        "link": "En la app, **{title}** abre {what}.",
        "setup": "la guía de configuración",
        "debugging": "los pasos para activar la depuración por USB",
        "remove": "El botón **Eliminar Ferry…** está aquí, en la Ayuda de Ferry. Ferry te pide "
        "confirmación primero.",
        "welcome": "En la Ayuda de Ferry, **Mostrar ventana de bienvenida** vuelve a abrir la "
        "bienvenida.",
    },
}


def wording(key):
    """A message as the reader sees it: each value it is shown with as "…"."""
    return SPEC.sub("…", key).replace("%%", "%")


def anchor(title):
    """The anchor GitHub gives a heading."""
    return re.sub(r"[^\w\- ]", "", title.lower()).replace(" ", "-")


def translator(language):
    """The text of a catalog key in `language`; the key itself is the English."""
    if language == "en":
        return lambda key: key
    strings = json.loads(CATALOG.read_text(encoding="utf-8"))["strings"]

    def translate(key):
        value = strings.get(key, {}).get("localizations", {}).get(language, {})
        if "stringUnit" not in value:
            sys.exit(f"no {language} for help string: {key}")
        return value["stringUnit"]["value"]

    return translate


def body(block, out, t, text):
    for paragraph in block.get("paragraphs", []):
        out += [t(paragraph), ""]
    steps = block.get("steps", [])
    out += [f"{number}. {t(step)}" for number, step in enumerate(steps, 1)]
    if steps:
        out.append("")
    definitions = block.get("definitions", [])
    out += [f"- **{t(d['term'])}**: {t(d['detail'])}" for d in definitions]
    if definitions:
        out.append("")
    if "note" in block:
        out += [t(block["note"]), ""]
    if "link" in block:
        link = block["link"]
        what = text["setup"] if link["target"].startswith("guide") else text["debugging"]
        out += [text["link"].format(title=t(link["title"]), what=what), ""]
    if block.get("action") == "removeFerry":
        out += [text["remove"], ""]
    if block.get("action") == "showWelcome":
        out += [text["welcome"], ""]
    for message in block.get("messages", []):
        out += [
            f"**{t(wording(message['message']))}**", "", t(message["cause"]), "",
            t(message["fix"]), "",
        ]


def render(help_content, language="en"):
    t = translator(language)
    text = TEXT[language]
    install = text["install_title"]
    out = list(text["header"]) + [f"## {text['contents']}", "", f"- [{install}](#{anchor(install)})"]
    for category in help_content["categories"]:
        title = t(category["title"])
        out.append(f"- [{title}](#{anchor(title)})")
        out += [f"  - [{t(x['title'])}](#{anchor(t(x['title']))})" for x in category["topics"]]
    out += ["", f"## {install}", ""] + text["install"]
    for category in help_content["categories"]:
        out += [f"## {t(category['title'])}", ""]
        for topic in category["topics"]:
            out += [f"### {t(topic['title'])}", ""]
            body(topic, out, t, text)
            for group in topic.get("groups", []):
                out += [f"#### {t(group['title'])}", ""]
                body(group, out, t, text)
    while out and out[-1] == "":
        out.pop()
    return "\n".join(out) + "\n"


def main():
    help_content = json.loads(HELP.read_text(encoding="utf-8"))
    args = sys.argv[1:]
    if args[:1] == ["--stdout"] and len(args) <= 2 and (args[1:] or ["en"])[0] in GUIDES:
        sys.stdout.write(render(help_content, (args[1:] or ["en"])[0]))
    elif not args:
        for language, path in GUIDES.items():
            path.write_text(render(help_content, language), encoding="utf-8")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
