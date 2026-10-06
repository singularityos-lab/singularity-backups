#!/usr/bin/env python3
import datetime
import fnmatch
import json
import os
import shutil
import sys


def tree(repo, snap):
    return os.path.join(repo, "snaps", snap, "tree")


def excluded(rel, patterns):
    name = os.path.basename(rel)
    for p in patterns:
        if p.startswith("/"):
            if rel == p[1:] or fnmatch.fnmatch(rel, p[1:]):
                return True
        elif "/" in p:
            if fnmatch.fnmatch(rel, p) or fnmatch.fnmatch(rel, "*/" + p):
                return True
        elif fnmatch.fnmatch(name, p):
            return True
    return False


def entry(base, rel):
    full = os.path.join(base, rel)
    st = os.lstat(full)
    kind = "directory" if os.path.isdir(full) and not os.path.islink(full) else ("symlink" if os.path.islink(full) else "file")
    return {"path": rel, "kind": kind, "size": st.st_size if kind == "file" else 0,
            "mtime": int(st.st_mtime), "mode": st.st_mode & 0o7777}


def main(argv):
    cmd = argv[1]
    if cmd == "open":
        os.makedirs(os.path.join(argv[2], "snaps"), exist_ok=True)
        return 0
    repo = argv[2]
    if cmd == "snapshots":
        out = []
        base = os.path.join(repo, "snaps")
        for name in sorted(os.listdir(base)):
            with open(os.path.join(base, name, "meta.json")) as f:
                out.append(json.load(f))
        print(json.dumps(out))
        return 0
    if cmd == "backup":
        with open(argv[3]) as f:
            roots = json.load(f)
        snap = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        dest = tree(repo, snap)
        files = 0
        size = 0
        for root in roots:
            for dirpath, dirnames, filenames in os.walk(root["path"]):
                rel_dir = os.path.relpath(dirpath, root["path"])
                rel_dir = "" if rel_dir == "." else rel_dir
                dirnames[:] = [d for d in dirnames if not excluded(os.path.join(rel_dir, d) if rel_dir else d, root["exclude"])]
                os.makedirs(os.path.join(dest, root["prefix"], rel_dir), exist_ok=True)
                for name in filenames:
                    rel = os.path.join(rel_dir, name) if rel_dir else name
                    if excluded(rel, root["exclude"]):
                        continue
                    src = os.path.join(dirpath, name)
                    target = os.path.join(dest, root["prefix"], rel)
                    if os.path.islink(src):
                        os.symlink(os.readlink(src), target)
                        continue
                    shutil.copy2(src, target)
                    files += 1
                    size += os.path.getsize(src)
                    print("progress 0.5 %s" % rel, flush=True)
        meta = {"id": snap, "created": int(datetime.datetime.now().timestamp()), "label": argv[4] if len(argv) > 4 else "",
                "files": files, "bytes": size}
        with open(os.path.join(repo, "snaps", snap, "meta.json"), "w") as f:
            json.dump(meta, f)
        print("progress 1 done")
        print("snapshot " + json.dumps(meta))
        return 0
    if cmd in ("ls", "stat"):
        base = tree(repo, argv[3])
        path = argv[4]
        full = os.path.join(base, path)
        if not os.path.lexists(full):
            sys.stderr.write("not found\n")
            return 2
        if cmd == "stat":
            print(json.dumps(entry(base, path)))
            return 0
        if not os.path.isdir(full):
            return 2
        print(json.dumps([entry(base, os.path.join(path, n)) for n in sorted(os.listdir(full))]))
        return 0
    if cmd in ("extract", "restore"):
        src = os.path.join(tree(repo, argv[3]), argv[4])
        dst = argv[5]
        if os.path.isdir(src):
            shutil.copytree(src, dst, symlinks=True, dirs_exist_ok=len(argv) > 6 and argv[6] == "merge")
        else:
            shutil.copy2(src, dst)
        return 0
    if cmd == "forget":
        shutil.rmtree(os.path.join(repo, "snaps", argv[3]))
        return 0
    if cmd == "check":
        base = tree(repo, argv[3])
        count = sum(len(f) for _, _, f in os.walk(base))
        print(json.dumps({"checked": count, "damaged": [], "missing": []}))
        return 0
    if cmd == "stats":
        used = 0
        for dirpath, _, filenames in os.walk(repo):
            for name in filenames:
                used += os.lstat(os.path.join(dirpath, name)).st_size
        st = os.statvfs(repo)
        print(json.dumps({"used": used, "free": st.f_bavail * st.f_frsize, "capacity": st.f_blocks * st.f_frsize}))
        return 0
    sys.stderr.write("unknown command %s\n" % cmd)
    return 1


sys.exit(main(sys.argv))
