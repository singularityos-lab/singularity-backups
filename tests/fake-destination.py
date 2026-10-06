#!/usr/bin/env python3
import json
import os
import shutil
import sys

ROOT = os.environ.get("FAKE_DEST_ROOT", "")


def answer(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def safe(base, key):
    path = os.path.normpath(os.path.join(base, key))
    if not path.startswith(base + os.sep) and path != base:
        raise ValueError("bad key")
    return path


def serve(target):
    base = os.path.join(ROOT, target)
    os.makedirs(base, exist_ok=True)
    puts = 0
    for line in sys.stdin:
        req = json.loads(line)
        op = req.get("op")
        if os.path.exists(os.path.join(ROOT, ".offline")) and op != "hello":
            answer({"ok": False, "error": "offline", "message": "The test box is offline"})
            continue
        try:
            if op == "hello":
                answer({"ok": True, "protocol": 1, "name": "Test Box"})
            elif op == "put":
                limit = os.environ.get("FAKE_DEST_FAIL_AFTER")
                if limit is not None and puts >= int(limit):
                    answer({"ok": False, "error": "offline", "message": "The connection dropped"})
                    continue
                puts += 1
                path = safe(base, req["key"])
                os.makedirs(os.path.dirname(path), exist_ok=True)
                size = os.path.getsize(req["file"])
                answer({"progress": size // 2})
                shutil.copyfile(req["file"], path + ".part")
                os.replace(path + ".part", path)
                answer({"ok": True})
            elif op == "get":
                path = safe(base, req["key"])
                if not os.path.isfile(path):
                    answer({"ok": False, "error": "not-found", "message": req["key"] + " is missing"})
                    continue
                shutil.copyfile(path, req["file"])
                answer({"ok": True})
            elif op == "list":
                prefix = req.get("prefix", "")
                start = safe(base, prefix) if prefix else base
                entries = []
                for dirpath, _, files in os.walk(start):
                    for f in files:
                        if f.endswith(".part"):
                            continue
                        full = os.path.join(dirpath, f)
                        entries.append({"key": os.path.relpath(full, base), "size": os.path.getsize(full)})
                answer({"ok": True, "entries": entries})
            elif op == "delete":
                path = safe(base, req["key"])
                if os.path.isfile(path):
                    os.unlink(path)
                answer({"ok": True})
            elif op == "space":
                total = int(os.environ.get("FAKE_DEST_TOTAL", "1073741824"))
                used = 0
                for dirpath, _, files in os.walk(base):
                    used += sum(os.path.getsize(os.path.join(dirpath, f)) for f in files)
                answer({"ok": True, "used": used, "total": total})
            else:
                answer({"ok": False, "error": "unsupported", "message": "unknown operation " + str(op)})
        except Exception as e:
            answer({"ok": False, "error": "failed", "message": str(e)})


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "targets":
        print(json.dumps([{"id": "box", "name": "Test Box", "detail": "A folder that acts as a remote store",
                           "icon": "folder-remote", "total": 1073741824, "used": 0}]))
    elif len(sys.argv) >= 3 and sys.argv[1] == "serve":
        serve(sys.argv[2])
    else:
        sys.stderr.write("usage: fake-destination.py targets | serve TARGET\n")
        sys.exit(2)


if __name__ == "__main__":
    main()
