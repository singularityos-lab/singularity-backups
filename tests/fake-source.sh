#!/bin/sh
set -eu
case "${1:-}" in
check)
    if [ -d "$FAKE_SOURCE_DATA" ]; then
        echo '{"available": true}'
    else
        echo '{"available": false, "reason": "Nothing to back up"}'
    fi
    ;;
backup)
    ls "$FAKE_SOURCE_DATA" > "$2/list.txt"
    printf '{"roots": [{"name": "data", "path": "%s", "exclude": ["*.log"]}], "home-exclusions": ["/fake-source"], "warnings": ["one app was running"]}\n' "$FAKE_SOURCE_DATA"
    ;;
restore)
    cp "$2/list.txt" "$FAKE_SOURCE_DATA.restored-list"
    echo '{"failed": []}'
    ;;
*)
    echo "usage: $0 check | backup DIR | restore DIR" >&2
    exit 2
    ;;
esac
