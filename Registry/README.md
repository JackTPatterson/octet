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

Plugins run shell commands as the person who installs them; the registry is reviewed, and each plugin is off until someone installs it from the Marketplace. A plugin can contribute terminal completions, status bar chips, runtime icons, and items in a tab's or workspace's right-click menu (`menuItems`: a command that prints what to start in a new tab, like `dev-server`); see any plugin here for the manifest format. (`Plugins/` in the app holds only what stands for native features, like Other Macs.)

## macOS, Linux and Windows

One plugin, one registry, every platform Octet runs on. Manifests, the index and checksums are plain JSON; only the commands differ.

- A `run` that is a string is a POSIX `sh` command, for macOS and Linux.
- A `run` can instead name a command per platform: `unix` (macOS and Linux), `macos`, `linux`, or `windows`, a PowerShell command. A contribution with no command for the platform Octet is running on is left out there; the rest of the plugin still works.

  ```json
  "run": { "unix": "sh \"$OCTET_PLUGIN_DIR/chip.sh\"",
           "windows": "& \"$env:OCTET_PLUGIN_DIR\\chip.ps1\"" }
  ```

- `platforms` in `plugin.json` says where it runs (default `["macos", "linux"]`); the index carries it, and the Marketplace lists only what runs where it's open. Runtime icons run nothing, so a plugin of only those can list all three.
- Every command sees the same environment everywhere: `OCTET_PLUGIN_DIR`, and for chips `OCTET_CWD`, `OCTET_REPO_ROOT`, `OCTET_SHELL_PID`, `OCTET_SSH_HOST`, `OCTET_SSH_USER`. Output is the same text on every platform.
- Prefer tools every platform has (`git`, `gh`, `curl`). Where one isn't (`osascript`, the Keychain), check with `command -v` and fall back, as `issues/scripts/jira-lib.sh` does with Node and `secret-tool` on Linux. `github-repos` has a `list-repos.ps1` beside its `list-repos.sh` as the example for Windows.
