#!/bin/sh
# The project's Python environment: a virtualenv in the repo, a conda
# environment file, or a pyenv version file.
top="${OCTET_REPO_ROOT:-$OCTET_CWD}"
for dir in "$OCTET_CWD" "$top"; do
  for venv in .venv venv env; do
    cfg="$dir/$venv/pyvenv.cfg"
    if [ -f "$cfg" ]; then
      version=$(sed -n 's/^version[_info]* *= *//p' "$cfg" | head -n 1)
      echo "$venv${version:+ $version}"
      echo "help: Virtualenv at $dir/$venv"
      exit 0
    fi
  done
  if [ -f "$dir/environment.yml" ]; then
    name=$(sed -n 's/^name: *//p' "$dir/environment.yml" | head -n 1)
    [ -n "$name" ] && { echo "conda $name"; echo "help: From $dir/environment.yml"; exit 0; }
  fi
  if [ -f "$dir/.python-version" ]; then
    echo "pyenv $(head -n 1 "$dir/.python-version")"
    echo "help: From $dir/.python-version"
    exit 0
  fi
done
exit 0
