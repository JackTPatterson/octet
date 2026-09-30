# Octet plugin registry

The Marketplace's **Plugins** section lists agent plugins and terminal plugins together; filter by *Agents* or *Terminal*. Terminal plugins come from this registry: `registry.json` is the index Octet downloads, and each entry names a plugin's files, their SHA-256, and the GitHub repository they're downloaded from. Octet checks every file against its checksum and the manifest's id against the entry before installing into `~/Library/Application Support/Octet/Plugins/<id>`.

## Octet's own plugins

Each is a folder in `plugins/` with a `plugin.json`. After changing one, bump its `version` (installed copies are offered the update) and rebuild the index:

```sh
scripts/build-plugin-registry.py
```

## Publishing yours

Keep the plugin in your own public GitHub repository, then open a pull request adding an entry to `community.json`:

```json
{ "id": "my-plugin", "name": "My Plugin", "description": "What it adds", "author": "you",
  "version": "1.0.0", "keywords": ["..."], "repo": "you/octet-my-plugin", "ref": "v1.0.0",
  "path": "", "files": ["plugin.json", "scripts/chip.sh"] }
```

Pin `ref` to a tag or commit. `scripts/build-plugin-registry.py --fetch` fills in the checksums, so a later change to the repository can't reach anyone without a new entry.

Plugins run shell commands as the person who installs them; the registry is reviewed, and each plugin is off until someone installs it from the Marketplace. A plugin can contribute terminal completions, status bar chips and runtime icons; see any plugin here, or the built-in ones in `Plugins/`, for the manifest format.
