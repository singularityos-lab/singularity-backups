#!/bin/sh
set -eu
home="${SINGULARITY_BACKUPS_HOME:-$HOME}"
saves="$home/.local/share/example-launcher/saves"
case "${1:-}" in
check)
    if [ -d "$saves" ]; then
        echo '{"available": true}'
    else
        echo '{"available": false, "reason": "The example launcher has no saved games"}'
    fi
    ;;
backup)
    ls "$saves" > "$2/games.txt"
    printf '{"roots": [{"name": "saves", "path": "%s", "exclude": ["*.tmp"]}], "home-exclusions": ["/.local/share/example-launcher/saves"]}\n' "$saves"
    ;;
restore)
    echo "restored $(wc -l < "$2/games.txt") games" >&2
    echo '{"failed": []}'
    ;;
*)
    echo "usage: $0 check | backup DIR | restore DIR" >&2
    exit 2
    ;;
esac
