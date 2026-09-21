#!/usr/bin/env python3
"""Copies the language logos Herd shows on code into
Herd/Assets.xcassets/Languages as template images, tinted in the app with
each brand's color. Logos come from Simple Icons (CC0 1.0, simpleicons.org).

Usage: scripts/import-language-logos.py <extracted simple-icons package dir>
  (npm pack simple-icons && tar xzf simple-icons-*.tgz gives ./package)
The slugs are the right-hand side of LanguageLogo.table in
Herd/Agent/LanguageLogo.swift.
"""
import json, os, re, shutil, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
package = sys.argv[1] if len(sys.argv) > 1 else "package"
swift = open(os.path.join(root, "Herd/Agent/LanguageLogo.swift")).read()
slugs = sorted(set(re.findall(r'\.init\("([a-z0-9]+)",', swift)))

out = os.path.join(root, "Herd/Assets.xcassets/Languages")
shutil.rmtree(out, ignore_errors=True)
os.makedirs(out)
with open(os.path.join(out, "Contents.json"), "w") as f:
    json.dump({"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": True}}, f, indent=2)
for slug in slugs:
    svg = open(os.path.join(package, "icons", slug + ".svg")).read()
    folder = os.path.join(out, slug + ".imageset")
    os.makedirs(folder)
    open(os.path.join(folder, slug + ".svg"), "w").write(svg)
    with open(os.path.join(folder, "Contents.json"), "w") as f:
        json.dump({
            "images": [{"filename": slug + ".svg", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
            "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
        }, f, indent=2)
print(f"{len(slugs)} logos -> {out}")
