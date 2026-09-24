#!/bin/sh
# Which .env files the project has and how many variables they set. Only
# names are read for the tooltip; values never leave the file.
top="${OCTET_REPO_ROOT:-$OCTET_CWD}"
files=""
count=0
names=""
for dir in "$OCTET_CWD" "$top"; do
  for file in "$dir"/.env "$dir"/.env.local "$dir"/.env.development; do
    [ -f "$file" ] || continue
    case " $files " in *" $file "*) continue ;; esac
    files="$files $file"
    these=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)=.*/\2/p' "$file")
    count=$((count + $(printf '%s\n' "$these" | grep -c .)))
    names="$names $(printf '%s ' $these)"
  done
done
[ -n "$files" ] || exit 0
echo ".env · $count vars"
echo "help: $(echo $names | tr ' ' '\n' | sort -u | head -n 30 | tr '\n' ' ')"
