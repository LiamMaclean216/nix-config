"""Merge the shared appearance into KDE's writable settings, preserving preferences."""

import configparser
import json
import os
from pathlib import Path
import sys
import tempfile

theme = json.loads(Path(sys.argv[1]).read_text())
target = Path(sys.argv[2])
colors = theme["colors"]


def rgb(name):
    value = colors[name]
    return ",".join(str(int(value[i:i + 2], 16)) for i in (0, 2, 4))


def merge_settings(path, values):
    settings = configparser.ConfigParser(interpolation=None, strict=False)
    settings.optionxform = str
    if path.exists():
        settings.read(path)
    for group, entries in values.items():
        if not settings.has_section(group):
            settings.add_section(group)
        settings[group].update(entries)
    path.parent.mkdir(parents=True, exist_ok=True)
    # Atomic replacement also safely detaches the old managed kdeglobals link.
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as output:
        settings.write(output, space_around_delimiters=False)
        temporary = output.name
    os.replace(temporary, path)

owned = {
    "General": {
        "ColorScheme": theme["qt"]["name"],
        "Name": theme["qt"]["name"],
        "font": f'{theme["font"]},{theme["qt"]["fontSize"]},-1,5,50,0,0,0,0,0',
        "menuFont": f'{theme["font"]},{theme["qt"]["fontSize"]},-1,5,50,0,0,0,0,0',
        "toolBarFont": f'{theme["font"]},{theme["qt"]["fontSize"]},-1,5,50,0,0,0,0,0',
        "TerminalApplication": "alacritty",
        "TerminalService": "alacritty.desktop",
    },
    "KDE": {"widgetStyle": "kvantum"},
    "Icons": {"Theme": theme["qt"]["icons"]},
    "ColorEffects:Inactive": {"Enable": "false"},
}
for role in ("View", "Window", "Button", "Tooltip", "Selection", "Complementary", "Header"):
    selection = role == "Selection"
    # KDE derives QPalette.Accent (used by Breeze folders) from this role.
    # Kvantum and the stylesheet independently keep selection fills subtle.
    owned[f"Colors:{role}"] = {
        "BackgroundNormal": rgb("folder" if selection else "background"),
        "BackgroundAlternate": rgb("folder" if selection else "background"),
        "ForegroundNormal": rgb("foreground"),
        "ForegroundInactive": rgb("muted"),
        "ForegroundLink": rgb("accent"),
        "ForegroundVisited": rgb("secondary"),
        "ForegroundNegative": rgb("error"),
        "DecorationFocus": rgb("accent"),
        "DecorationHover": rgb("accent"),
    }
merge_settings(target, owned)
if len(sys.argv) > 3:
    merge_settings(Path(sys.argv[3]), {
        "General": {"ShowSelectionToggle": "false", "ShowStatusBar": "Disabled"},
        "MainWindow": {"MenuBar": "Disabled"},
        "MainWindow][Toolbar mainToolBar": {
            "ToolButtonStyle": "IconOnly",
            "IconSize": str(theme["qt"]["iconSize"]),
        },
        "PlacesPanel": {"IconSize": str(theme["qt"]["iconSize"])},
        "DetailsMode": {
            "IconSize": str(theme["qt"]["iconSize"]),
            "PreviewSize": "32",
            "LeftPadding": "0",
            "RightPadding": "0",
            "ExpandableFolders": "false",
        },
    })
