"""Adapt pinned KvMojave controls to the shared desktop palette and glass alpha."""

import configparser
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

source, theme_file, destination = map(Path, sys.argv[1:])
theme = json.loads(theme_file.read_text())
colors = theme["colors"]
config = configparser.ConfigParser(interpolation=None)
config.optionxform = str
config.read(source / "KvMojave.kvconfig")
config["%General"].update({
    "comment": "Shared desktop liquid glass",
    "layout_spacing": "6",
    "toolbar_interior_spacing": "6",
    "toolbar_icon_size": "22",
    "no_inactiveness": "true",
})
for key in config["GeneralColors"]:
    if "highlight.text" in key:
        role = "foreground"
    elif key == "link.visited.color":
        role = "secondary"
    elif "highlight.color" in key:
        role = "selection"
    elif key == "link.color":
        role = "accent"
    elif "inactive.text" in key or key == "disabled.text.color":
        role = "muted"
    elif "text.color" in key:
        role = "foreground"
    elif key == "tooltip.base.color":
        role = "sidebar"
    elif key in ("button.color", "light.color", "mid.light.color", "mid.color"):
        role = "surface"
    else:
        role = "background"
    config["GeneralColors"][key] = "#" + colors[role]
for section in config.sections():
    for key in config[section]:
        if key.startswith("text.") and key.endswith("color"):
            config[section][key] = "#" + colors["foreground"]
        if key == "text.shadow":
            config[section][key] = "false"

# A quiet flat heading instead of KvMojave's metallic button-shaped header.
config["HeaderSection"].update({
    "frame": "false",
    "interior": "true",
    "interior.element": "desktop-header",
    "text.normal.color": "#" + colors["muted"],
    "text.normal.inactive.color": "#" + colors["muted"],
    "text.focus.color": "#" + colors["foreground"],
    "text.margin.top": "7",
    "text.margin.bottom": "7",
    "text.margin.left": "10",
    "text.margin.right": "10",
})

# Places uses Kvantum's native item primitive, bypassing widget ::item QSS.
# Nine slices keep the corner radius fixed when a row stretches horizontally.
item_radius = min(theme["qt"]["controlRadius"], 4)
config["ItemView"].update({
    "frame.element": "desktop-itemview",
    "interior.element": "desktop-itemview",
    **{f"frame.{edge}": str(item_radius) for edge in ("top", "bottom", "left", "right")},
})

svg = (source / "KvMojave.svg").read_text()


def recolor(match):
    value = match.group()[1:]
    if len(value) == 3:
        value = "".join(c * 2 for c in value)
    channels = [int(value[i:i + 2], 16) for i in (0, 2, 4)]
    # Keep upstream shading and geometry, using the shared palette for controls.
    if max(channels) - min(channels) > 40 and channels[0] > channels[1]:
        return "#" + colors["secondary"]
    if value.lower() in ("c3c3c6", "adadaf"):
        return "#" + colors["selection"]
    if max(channels) - min(channels) > 40:
        return "#" + colors["accent"]
    luminance = sum(channels) / 3 / 255
    background = [int(colors["background"][i:i + 2], 16) for i in (0, 2, 4)]
    foreground = [int(colors["foreground"][i:i + 2], 16) for i in (0, 2, 4)]
    if luminance < 0.25:
        result = [round(c * (0.55 + 1.8 * luminance)) for c in background]
    else:
        amount = (luminance - 0.25) / 0.75
        result = [round(b + (f - b) * amount) for b, f in zip(background, foreground)]
    return "#" + "".join(f"{c:02x}" for c in result)


svg = re.sub(r"#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{3}\b", recolor, svg)
ET.register_namespace("", "http://www.w3.org/2000/svg")
ET.register_namespace("xlink", "http://www.w3.org/1999/xlink")
tree = ET.fromstring(svg)


def itemview_background(state, color):
    prefix = f"desktop-itemview-{state}"
    radius = item_radius
    pieces = {
        "": (8, 8),
        "-top": (8, radius),
        "-bottom": (8, radius),
        "-left": (radius, 8),
        "-right": (radius, 8),
    }
    for suffix, (width, height) in pieces.items():
        ET.SubElement(tree, "{http://www.w3.org/2000/svg}rect", {
            "id": prefix + suffix, "x": "0", "y": "0",
            "width": str(width), "height": str(height), "fill": "#" + color,
        })
    corners = {
        "topleft": f"M {radius} 0 V {radius} H 0 A {radius} {radius} 0 0 1 {radius} 0 Z",
        "topright": f"M 0 0 A {radius} {radius} 0 0 1 {radius} {radius} H 0 Z",
        "bottomright": f"M 0 0 H {radius} A {radius} {radius} 0 0 1 0 {radius} Z",
        "bottomleft": f"M 0 0 H {radius} V {radius} A {radius} {radius} 0 0 1 0 0 Z",
    }
    for corner, path in corners.items():
        ET.SubElement(tree, "{http://www.w3.org/2000/svg}path", {
            "id": f"{prefix}-{corner}", "d": path, "fill": "#" + color,
        })


for state, role in (("focused", "surface"), ("pressed", "selection"), ("toggled", "selection")):
    itemview_background(state, colors[role])
    itemview_background(state + "-inactive", colors[role])

for index, state in enumerate(("normal", "focused", "pressed", "toggled", "normal-inactive")):
    ET.SubElement(tree, "{http://www.w3.org/2000/svg}rect", {
        "id": f"desktop-header-{state}", "x": "0", "y": str(index * 20),
        "width": "20", "height": "20",
        "fill": "#" + colors["surface" if state in ("focused", "pressed") else "background"],
    })
for element in tree.iter():
    identifier = element.get("id", "")
    if identifier in ("window-normal", "window-normal-inactive", "dialog-normal", "dialog-normal-inactive"):
        element.set("style", f'fill:#{colors["background"]};opacity:{theme["qt"]["surfaceOpacity"]}')
    elif identifier in ("menubar-normal", "dock-normal"):
        element.set("style", f'fill:#{colors["background"]};opacity:{theme["qt"]["surfaceOpacity"]}')

destination.mkdir(parents=True, exist_ok=True)
name = theme["qt"]["name"]
with (destination / f"{name}.kvconfig").open("w") as output:
    config.write(output, space_around_delimiters=False)
ET.ElementTree(tree).write(destination / f"{name}.svg", encoding="unicode")
