#!/usr/bin/env python3
"""Builds Registry/registry.json, the index the Marketplace reads.

Octet's own plugins live in Registry/plugins/<id>/; each is listed with
every file and its SHA-256, which Octet checks before installing. Plugins
published from other repositories go in Registry/community.json, one entry
each ({"id", "name", "repo", "ref", "path", "files": [...]}, the same shape);
run with --fetch to fill in their files and checksums from GitHub.

Run after changing a plugin, and commit the result:
  scripts/build-plugin-registry.py
"""
import hashlib, json, os, sys, urllib.request

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
registry_dir = os.path.join(root, "Registry")
plugins_dir = os.path.join(registry_dir, "plugins")
REPO, REF = "JackTPatterson/octet", "master"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def local_entry(folder):
    base = os.path.join(plugins_dir, folder)
    manifest = json.load(open(os.path.join(base, "plugin.json")))
    assert manifest["id"] == folder, f"{folder}: its manifest id is {manifest['id']}"
    files = []
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for name in sorted(filenames):
            if name.startswith("."):
                continue
            full = os.path.join(dirpath, name)
            files.append({"path": os.path.relpath(full, base), "sha256": sha256(open(full, "rb").read())})
    return {
        "id": manifest["id"],
        "name": manifest["name"],
        "description": manifest.get("description", ""),
        "author": manifest.get("author", ""),
        "version": manifest.get("version", "0.0.0"),
        "keywords": manifest.get("keywords", []),
        # Plain-string commands are sh: macOS and Linux unless it says.
        "platforms": manifest.get("platforms", ["macos", "linux"]),
        "repo": REPO,
        "ref": REF,
        "path": f"Registry/plugins/{folder}",
        "files": files,
    }


def fetched(entry):
    """Checksums for a community entry's files, read from GitHub."""
    files = []
    for f in entry["files"]:
        path = f["path"] if isinstance(f, dict) else f
        prefix = entry.get("path", "").strip("/")
        url = f"https://raw.githubusercontent.com/{entry['repo']}/{entry.get('ref', 'main')}/{prefix + '/' if prefix else ''}{path}"
        files.append({"path": path, "sha256": sha256(urllib.request.urlopen(url).read())})
    return {**entry, "files": files}


entries = [local_entry(d) for d in sorted(os.listdir(plugins_dir)) if not d.startswith(".")]
community_path = os.path.join(registry_dir, "community.json")
if os.path.exists(community_path):
    community = json.load(open(community_path))
    if "--fetch" in sys.argv:
        community = [fetched(e) for e in community]
        json.dump(community, open(community_path, "w"), indent=2)
    entries += community
ids = [e["id"] for e in entries]
assert len(ids) == len(set(ids)), "two plugins share an id"
with open(os.path.join(registry_dir, "registry.json"), "w") as out:
    json.dump({"version": 1, "plugins": entries}, out, indent=2, ensure_ascii=False)
    out.write("\n")
print(f"{len(entries)} plugins -> Registry/registry.json")
