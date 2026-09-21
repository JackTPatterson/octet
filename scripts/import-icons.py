#!/usr/bin/env python3
"""Copies the iconsax icons (linear, or another style where named) Herd uses into Herd/Assets.xcassets/Icons
as template images, so they take the color of the text around them.

Usage: scripts/import-icons.py [iconsax static/standard folder]
The icon list is the right-hand side of HerdIcon.map in Herd/Theme/HerdIcon.swift.
"""
import json, os, re, shutil, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
source = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Documents/icons/static/standard")
swift = open(os.path.join(root, "Herd/Theme/HerdIcon.swift")).read()
table = swift[swift.index("static let map"):swift.index("]\n", swift.index("static let map"))]
# (name, style) pairs; style defaults to linear, e.g. .init("tick-circle", style: "bold").
entries = re.findall(r':\s*\.init\("([a-z0-9-]+)"(?:[^)]*?style:\s*"([a-z]+)")?', table)
icons = sorted({(name, style or "linear") for name, style in entries} | {("more", "linear")})

out = os.path.join(root, "Herd/Assets.xcassets/Icons")
shutil.rmtree(out, ignore_errors=True)
os.makedirs(out)
with open(os.path.join(out, "Contents.json"), "w") as f:
    json.dump({"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": True}}, f, indent=2)
for name, style in icons:
    svg = open(os.path.join(source, style, name + ".svg")).read()
    asset = name if style == "linear" else name + "-" + style
    # Template rendering keeps only alpha; make strokes opaque black.
    svg = re.sub(r'(stroke|fill)="(white|#fff(fff)?|#292D32)"', r'\1="#000000"', svg, flags=re.I)
    folder = os.path.join(out, asset + ".imageset")
    os.makedirs(folder)
    open(os.path.join(folder, asset + ".svg"), "w").write(svg)
    with open(os.path.join(folder, "Contents.json"), "w") as f:
        json.dump({
            "images": [{"filename": asset + ".svg", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
            "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
        }, f, indent=2)
print(f"{len(icons)} icons -> {out}")
