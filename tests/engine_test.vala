using Singularity.Backups;

string make_dir (string name) {
    try {
        return DirUtils.make_tmp ("backups-" + name + "-XXXXXX");
    } catch (FileError e) {
        error (e.message);
    }
}

void put_file (string path, string content) {
    DirUtils.create_with_parents (Path.get_dirname (path), 0755);
    try {
        FileUtils.set_contents (path, content);
    } catch (FileError e) {
        error (e.message);
    }
}

string get_file (string path) {
    string text;
    try {
        FileUtils.get_contents (path, out text);
    } catch (FileError e) {
        error (e.message);
    }
    return text;
}

uint64 inode (string path) {
    Posix.Stat st;
    assert (Posix.lstat (path, out st) == 0);
    return (uint64) st.st_ino;
}

class Fixture {
    public string home;
    public string repo;
    public LocalBackend backend;
    public BackupPlan plan;

    public Fixture (string store = "auto") {
        home = make_dir ("home");
        repo = make_dir ("repo");
        put_file (home + "/Documents/report.txt", "first draft");
        put_file (home + "/Documents/notes.md", "# notes");
        put_file (home + "/Pictures/cat.txt", "meow");
        put_file (home + "/.cache/junk.bin", "cache");
        put_file (home + "/Downloads/big.part", "partial");
        FileUtils.symlink ("Documents/report.txt", home + "/latest-report");
        backend = new LocalBackend ();
        backend.requested_store = store;
        try {
            backend.open (repo);
        } catch (Error e) {
            error (e.message);
        }
        plan = new BackupPlan ();
        plan.source_home = home;
        plan.exclusions = Exclusions.DEFAULTS;
        plan.host = "test";
    }

    public SnapshotInfo backup (string label = "") {
        plan.label = label;
        var roots = new Gee.ArrayList<SourceRoot> ();
        try {
            roots.add (new UserDataProvider ().prepare (plan, repo, repo));
            return backend.create_snapshot (plan, roots, null, (f, phase, item) => {
                assert (f >= 0 && f <= 1);
            });
        } catch (Error e) {
            error (e.message);
        }
    }

    public string tree (SnapshotInfo s, string rel) {
        return Path.build_filename (repo, "snapshots", s.id, "tree", "userdata", rel);
    }
}

Entry? find_entry (Gee.List<Entry> list, string name) {
    foreach (var e in list) if (e.name == name) return e;
    return null;
}

void test_exclusions () {
    var ex = new Exclusions ({ ".cache", "*.tmp", ".var/app/*/cache", "/Videos/Raw", "node_modules/" });
    assert (ex.excluded (".cache"));
    assert (ex.excluded ("code/.cache"));
    assert (ex.excluded ("a/b/file.tmp"));
    assert (ex.excluded (".var/app/org.x.App/cache"));
    assert (!ex.excluded (".var/app/org.x.App/data"));
    assert (ex.excluded ("Videos/Raw"));
    assert (!ex.excluded ("Old/Videos/Raw"));
    assert (ex.excluded ("proj/node_modules"));
    assert (!ex.excluded ("Documents/report.txt"));
    bool anchored = false;
    foreach (string p in ex.patterns) if (p == "/Videos/Raw") anchored = true;
    assert (anchored);
}

void test_first_backup () {
    var f = new Fixture ();
    var s = f.backup ("first");
    assert (s.files > 0);
    assert (get_file (f.tree (s, "Documents/report.txt")) == "first draft");
    assert (!FileUtils.test (f.tree (s, ".cache"), FileTest.EXISTS));
    assert (!FileUtils.test (f.tree (s, "Downloads/big.part"), FileTest.EXISTS));
    assert (FileUtils.test (f.tree (s, "latest-report"), FileTest.IS_SYMLINK));
    Posix.Stat st;
    Posix.lstat (f.tree (s, "Documents/report.txt"), out st);
    assert ((st.st_mode & 0222) == 0);
    try {
        var list = f.backend.list_snapshots ();
        assert (list.size == 1);
        assert (list[0].label == "first");
        var e = f.backend.lookup (s.id, "userdata/Documents/report.txt");
        assert (e != null);
        assert (e.digest == Checksum.compute_for_string (ChecksumType.SHA256, "first draft"));
        assert (e.mode == 0644);
        var root = f.backend.list_directory (s.id, "userdata");
        assert (find_entry (root, "Documents") != null);
        assert (find_entry (root, "Documents").change == Change.NONE);
        assert (FileUtils.test (Path.build_filename (f.repo, "latest"), FileTest.IS_SYMLINK));
    } catch (Error e) {
        error (e.message);
    }
}

void test_incremental_links () {
    var f = new Fixture ();
    var a = f.backup ();
    Thread.usleep (1100000);
    var b = f.backup ();
    assert (a.id != b.id);
    assert (b.added_bytes == 0);
    assert (inode (f.tree (a, "Documents/report.txt")) == inode (f.tree (b, "Documents/report.txt")));

    Thread.usleep (1100000);
    put_file (f.home + "/Documents/report.txt", "second draft, longer");
    put_file (f.home + "/Documents/new.txt", "brand new");
    FileUtils.unlink (f.home + "/Pictures/cat.txt");
    var c = f.backup ();
    assert (c.added_files == 2);
    assert (inode (f.tree (b, "Documents/report.txt")) != inode (f.tree (c, "Documents/report.txt")));
    assert (inode (f.tree (b, "Documents/notes.md")) == inode (f.tree (c, "Documents/notes.md")));
    assert (get_file (f.tree (b, "Documents/report.txt")) == "first draft");
    assert (get_file (f.tree (c, "Documents/report.txt")) == "second draft, longer");
    try {
        var docs = f.backend.list_directory (c.id, "userdata/Documents");
        assert (find_entry (docs, "report.txt").change == Change.CHANGED);
        assert (find_entry (docs, "new.txt").change == Change.ADDED);
        assert (find_entry (docs, "notes.md").change == Change.NONE);
        var pics = f.backend.list_directory (c.id, "userdata/Pictures");
        var gone = find_entry (pics, "cat.txt");
        assert (gone != null && gone.change == Change.REMOVED && gone.origin == b.id);
        var root = f.backend.list_directory (c.id, "userdata");
        assert (find_entry (root, "Documents").change == Change.CONTAINS);
        assert (find_entry (root, "Pictures").change == Change.CONTAINS);
    } catch (Error e) {
        error (e.message);
    }
}

void test_dedup () {
    var f = new Fixture ();
    put_file (f.home + "/a/copy1.bin", "same content here");
    put_file (f.home + "/b/copy2.bin", "same content here");
    var s = f.backup ();
    assert (inode (f.tree (s, "a/copy1.bin")) == inode (f.tree (s, "b/copy2.bin")));
    Thread.usleep (1100000);
    FileUtils.rename (f.home + "/a/copy1.bin", f.home + "/a/moved.bin");
    var t = f.backup ();
    assert (inode (f.tree (t, "a/moved.bin")) == inode (f.tree (s, "a/copy1.bin")));
}

void test_restore_and_conflicts () {
    var f = new Fixture ();
    var s = f.backup ();
    string data = make_dir ("xdg");
    Environment.set_variable ("XDG_DATA_HOME", data, true);
    var r = new Restorer (f.backend, f.home);
    put_file (f.home + "/Documents/report.txt", "overwritten by mistake");
    try {
        string[] c = r.conflicts ({ "Documents/report.txt", "Documents/missing.txt" }, "");
        assert (c.length == 1);
        string[] done = r.restore (s.id, { "Documents/report.txt" }, "", ConflictPolicy.KEEP_BOTH, null);
        assert (done.length == 1);
        assert (done[0] == f.home + "/Documents/report (restored).txt");
        assert (get_file (done[0]) == "first draft");
        assert (get_file (f.home + "/Documents/report.txt") == "overwritten by mistake");
        Posix.Stat st;
        Posix.lstat (done[0], out st);
        assert ((st.st_mode & 07777) == 0644);

        done = r.restore (s.id, { "Documents/report.txt" }, "", ConflictPolicy.SKIP, null);
        assert (done.length == 0);

        done = r.restore (s.id, { "Documents/report.txt" }, "", ConflictPolicy.REPLACE, null);
        assert (get_file (f.home + "/Documents/report.txt") == "first draft");

        string elsewhere = make_dir ("elsewhere");
        done = r.restore (s.id, { "Documents" }, elsewhere, ConflictPolicy.KEEP_BOTH, null);
        assert (get_file (elsewhere + "/Documents/notes.md") == "# notes");
        assert (get_file (elsewhere + "/Documents/report.txt") == "first draft");

        LocalBackend.remove_tree (f.home + "/Pictures");
        done = r.restore (s.id, { "Pictures" }, "", ConflictPolicy.KEEP_BOTH, null);
        assert (get_file (f.home + "/Pictures/cat.txt") == "meow");

        put_file (f.home + "/Documents/notes.md", "changed");
        f.backend.restore (s.id, "userdata", f.home, true, null);
        assert (get_file (f.home + "/Documents/notes.md") == "# notes");
    } catch (Error e) {
        error (e.message);
    }
}

void test_verify_detects_damage () {
    var f = new Fixture ();
    var s = f.backup ();
    try {
        assert (f.backend.verify (s.id, null, null).ok);
        string file = f.tree (s, "Documents/notes.md");
        Posix.chmod (file, 0644);
        put_file (file, "tampered");
        var r = f.backend.verify (s.id, null, null);
        assert (!r.ok);
        assert (r.damaged.length == 1 && r.damaged[0] == "userdata/Documents/notes.md");
        FileUtils.unlink (f.tree (s, "Pictures/cat.txt"));
        r = f.backend.verify (s.id, null, null);
        assert (r.missing.length == 1);
        Thread.usleep (1100000);
        var healed = f.backup ();
        assert (get_file (f.tree (healed, "Documents/notes.md")) == "# notes");
        assert (inode (f.tree (healed, "Documents/notes.md")) != inode (file));
        assert (get_file (f.tree (healed, "Pictures/cat.txt")) == "meow");
        assert (f.backend.verify (healed.id, null, null).ok);
    } catch (Error e) {
        error (e.message);
    }
}

void test_prune () {
    var f = new Fixture ();
    for (int i = 0; i < 4; i++) {
        put_file (f.home + "/counter.txt", "value %d".printf (i));
        f.backup ();
        Thread.usleep (1100000);
    }
    try {
        assert (f.backend.list_snapshots ().size == 4);
        f.backend.prune (2);
        var left = f.backend.list_snapshots ();
        assert (left.size == 2);
        assert (get_file (f.tree (left[1], "counter.txt")) == "value 3");
        f.plan.keep_last = 1;
        put_file (f.home + "/counter.txt", "value 4");
        f.backup ();
        assert (f.backend.list_snapshots ().size == 1);
        var stats = f.backend.stats ();
        assert (stats.used > 0);
        assert (stats.free > 0);
        assert (stats.links);
    } catch (Error e) {
        error (e.message);
    }
}

void test_cancel () {
    var f = new Fixture ();
    var c = new Cancellable ();
    c.cancel ();
    var roots = new Gee.ArrayList<SourceRoot> ();
    try {
        roots.add (new UserDataProvider ().prepare (f.plan, f.repo, f.repo));
        f.backend.create_snapshot (f.plan, roots, c, (fr, p, i) => {});
        assert_not_reached ();
    } catch (BackupError.CANCELLED e) {
    } catch (Error e) {
        error (e.message);
    }
    try {
        assert (f.backend.list_snapshots ().size == 0);
    } catch (Error e) {
        error (e.message);
    }
}

void test_repo_inside_home () {
    var f = new Fixture ();
    string repo = f.home + "/Backups";
    var b = new LocalBackend ();
    try {
        b.open (repo);
        var roots = new Gee.ArrayList<SourceRoot> ();
        roots.add (new UserDataProvider ().prepare (f.plan, repo, repo));
        var s = b.create_snapshot (f.plan, roots, null, (fr, p, i) => {});
        assert (b.lookup (s.id, "userdata/Backups") == null);
        assert (b.lookup (s.id, "userdata/Documents/report.txt") != null);
    } catch (Error e) {
        error (e.message);
    }
}

void test_schedule () {
    int64 now = 1000000;
    assert (Schedule.next_run (Frequency.HOURLY, 0, 0, now) == now);
    assert (Schedule.next_run (Frequency.HOURLY, now - 600, 0, now) == now - 600 + 3600);
    assert (Schedule.next_run (Frequency.DAILY, now - 90000, 0, now) == now);
    assert (Schedule.next_run (Frequency.WEEKLY, now, 0, now) == now + 7 * 86400);
    assert (Schedule.next_run (Frequency.MANUAL, now, 0, now) == 0);
    assert (Schedule.next_run (Frequency.HOURLY, now - 7200, now - 60, now) == now - 60 + Schedule.RETRY_DELAY);
    assert (Frequency.parse ("weekly") == Frequency.WEEKLY);
    assert (parse_snapshot_id ("20260928T120000Z") == new DateTime.utc (2026, 9, 28, 12, 0, 0).to_unix ());
}

void test_system_config () {
    string dir = make_dir ("conf");
    put_file (dir + "/a.conf", "[Backups]\nBackend=exec:/usr/libexec/restic-adapter\nProviders=userdata;\n");
    put_file (dir + "/b.conf", "[Backups]\nRepositoryName=Copies\n");
    var c = SystemConfig.load ({ dir + "/a.conf", dir + "/missing.conf", dir + "/b.conf" });
    assert (c.backend == "exec:/usr/libexec/restic-adapter");
    assert (c.offers ("userdata") && !c.offers ("flatpak"));
    assert (c.repository_name == "Copies");
    var d = SystemConfig.load ({});
    assert (d.backend == "local" && d.offers ("abroot"));
    try {
        BackendRegistry.create ("nonexistent");
        assert_not_reached ();
    } catch (Error e) {
    }
    try {
        assert (BackendRegistry.create ("local") is LocalBackend);
        assert (BackendRegistry.create ("exec:/bin/true") is ExecBackend);
    } catch (Error e) {
        error (e.message);
    }
}

void test_flatpak_provider () {
    var apps = FlatpakProvider.parse_list ("org.gnome.Maps\tflathub\tstable\tsystem\norg.x.Tool\tflathub\tbeta\tuser\n\nbroken\n");
    assert (apps.size == 2);
    assert (apps[0].installation == "system" && apps[1].branch == "beta");
    try {
        var back = FlatpakProvider.from_json (FlatpakProvider.to_json (apps));
        assert (back.size == 2 && back[1].app_id == "org.x.Tool");
    } catch (Error e) {
        error (e.message);
    }

    string bin = make_dir ("bin");
    string log = bin + "/calls.log";
    put_file (bin + "/flatpak", "#!/bin/sh\necho \"$@\" >> '%s'\ncase \"$1\" in\nlist) printf 'org.example.App\\tflathub\\tstable\\tuser\\n';;\ninfo) exit 1;;\nesac\nexit 0\n".printf (log));
    Posix.chmod (bin + "/flatpak", 0755);
    string old_path = Environment.get_variable ("PATH");
    Environment.set_variable ("PATH", bin + ":" + old_path, true);
    var f = new Fixture ();
    var p = new FlatpakProvider ();
    assert (p.available (f.plan));
    try {
        var roots = new Gee.ArrayList<SourceRoot> ();
        roots.add (new UserDataProvider ().prepare (f.plan, f.repo, f.repo));
        string staging = make_dir ("staging");
        roots.add (p.prepare (f.plan, staging, f.repo));
        var s = f.backend.create_snapshot (f.plan, roots, null, (fr, ph, i) => {});
        assert (f.backend.lookup (s.id, "flatpak/apps.json") != null);
        p.restore_all (f.backend, s.id, f.plan, null);
        string calls = get_file (log);
        assert ("install --user --noninteractive -y flathub org.example.App//stable" in calls);
    } catch (Error e) {
        error (e.message);
    }
    Environment.set_variable ("PATH", old_path, true);
}

void test_abroot_detection () {
    var plan = new BackupPlan ();
    string sys = make_dir ("sysroot");
    plan.system_root = sys;
    var p = new ABRootProvider ();
    string bin = make_dir ("abroot-bin");
    plan.abroot_command = bin + "/abroot";
    put_file (bin + "/abroot", "#!/bin/sh\n[ \"$1 $2\" = \"status --json\" ] && echo '{}' && exit 0\nexit 1\n");
    Posix.chmod (bin + "/abroot", 0755);
    assert (!p.available (plan));
    DirUtils.create_with_parents (sys + "/etc/abroot", 0755);
    assert (!p.available (plan));
    put_file (sys + "/etc/abroot/abroot.json", "{\"packages\": [\"htop\"]}");
    put_file (sys + "/etc/abroot/extra/packages.add", "htop\n");
    plan.abroot_command = bin + "/missing-abroot";
    assert (!p.available (plan));
    put_file (bin + "/broken-abroot", "#!/bin/sh\necho 'not an ABRoot system' >&2\nexit 1\n");
    Posix.chmod (bin + "/broken-abroot", 0755);
    plan.abroot_command = bin + "/broken-abroot";
    assert (!p.available (plan));
    plan.abroot_command = bin + "/abroot";
    assert (p.available (plan));

    string? helper = Environment.get_variable ("TEST_SYSTEM_HELPER");
    if (helper == null) return;
    var f = new Fixture ();
    plan.source_home = f.home;
    plan.system_helper = helper;
    try {
        var roots = new Gee.ArrayList<SourceRoot> ();
        roots.add (p.prepare (plan, f.repo, f.repo));
        var s = f.backend.create_snapshot (plan, roots, null, (fr, ph, i) => {});
        assert (f.backend.lookup (s.id, "abroot/extra/packages.add") != null);
        put_file (sys + "/etc/abroot/abroot.json", "{\"packages\": []}");
        FileUtils.unlink (sys + "/etc/abroot/extra/packages.add");
        p.restore_all (f.backend, s.id, plan, null);
        assert (get_file (sys + "/etc/abroot/abroot.json") == "{\"packages\": [\"htop\"]}");
        assert (get_file (sys + "/etc/abroot/extra/packages.add") == "htop\n");
    } catch (Error e) {
        error (e.message);
    }
    int status;
    try {
        Process.spawn_sync (null, { helper, "restore-abroot", sys + "/etc" }, null, SpawnFlags.STDERR_TO_DEV_NULL, null, null, null, out status);
    } catch (Error e) {
        error (e.message);
    }
    assert (status != 0);
}

void test_exec_backend () {
    string adapter = Environment.get_variable ("TEST_ADAPTER");
    if (adapter == null) {
        Test.skip ("TEST_ADAPTER not set");
        return;
    }
    var f = new Fixture ();
    string repo = make_dir ("execrepo");
    try {
        var b = BackendRegistry.create ("exec:" + adapter);
        b.open (repo);
        var roots = new Gee.ArrayList<SourceRoot> ();
        roots.add (new UserDataProvider ().prepare (f.plan, repo, repo));
        bool progressed = false;
        var s1 = b.create_snapshot (f.plan, roots, null, (fr, ph, i) => { progressed = true; });
        assert (progressed);
        Thread.usleep (1100000);
        put_file (f.home + "/Documents/report.txt", "changed through adapter");
        var s2 = b.create_snapshot (f.plan, roots, null, (fr, ph, i) => {});
        var snaps = b.list_snapshots ();
        assert (snaps.size == 2 && snaps[0].id == s1.id && snaps[1].id == s2.id);
        var docs = b.list_directory (s2.id, "userdata/Documents");
        assert (find_entry (docs, "report.txt").change == Change.CHANGED);
        assert (find_entry (docs, "notes.md").change == Change.NONE);
        assert (!FileUtils.test (f.home + "/.cache/junk.bin", FileTest.EXISTS) || b.lookup (s1.id, "userdata/.cache") == null);
        string file = b.materialize (s1.id, "userdata/Documents/report.txt", null);
        assert (get_file (file) == "first draft");
        var r = new Restorer (b, f.home);
        string[] done = r.restore (s1.id, { "Documents/report.txt" }, "", ConflictPolicy.KEEP_BOTH, null);
        assert (get_file (done[0]) == "first draft");
        assert (b.verify (s2.id, null, null).ok);
        assert (b.stats ().used > 0);
        b.delete_snapshot (s1.id);
        assert (b.list_snapshots ().size == 1);
    } catch (Error e) {
        error (e.message);
    }
}

SnapshotInfo fake_snapshot (int64 created) {
    var s = new SnapshotInfo ();
    s.created = created;
    s.id = snapshot_id_for (new DateTime.from_unix_utc (created));
    return s;
}

void test_retention_smart () {
    var zone = new TimeZone.utc ();
    int64 now = new DateTime.utc (2026, 9, 28, 12, 30, 0).to_unix ();
    var list = new Gee.ArrayList<SnapshotInfo> ();
    for (int64 t = now - 90 * 86400; t <= now; t += 900) list.add (fake_snapshot (t));
    var kept = Retention.keep_smart (list, now, zone);
    assert (kept.contains (list[list.size - 1].id));
    var hours = new Gee.HashMap<string, int> ();
    var days = new Gee.HashMap<string, int> ();
    var weeks = new Gee.HashMap<string, int> ();
    foreach (var s in list) {
        if (!kept.contains (s.id)) continue;
        int64 age = now - s.created;
        var t = new DateTime.from_unix_utc (s.created);
        if (age == 0) continue;
        if (age < Retention.HOURLY_SPAN) {
            string k = t.format ("%Y%m%d%H");
            hours[k] = hours.has_key (k) ? hours[k] + 1 : 1;
        } else if (age < Retention.DAILY_SPAN) {
            string k = t.format ("%Y%m%d");
            days[k] = days.has_key (k) ? days[k] + 1 : 1;
        } else {
            string k = "%d-%d".printf (t.get_week_numbering_year (), t.get_week_of_year ());
            weeks[k] = weeks.has_key (k) ? weeks[k] + 1 : 1;
        }
    }
    foreach (var v in hours.values) assert (v == 1);
    foreach (var v in days.values) assert (v == 1);
    foreach (var v in weeks.values) assert (v == 1);
    assert (hours.size >= 24 && hours.size <= 25);
    assert (days.size >= 29 && days.size <= 31);
    assert (weeks.size >= 8 && weeks.size <= 10);
    assert (kept.size < 80);

    var survivors = new Gee.ArrayList<SnapshotInfo> ();
    foreach (var s in list) if (kept.contains (s.id)) survivors.add (s);
    assert (Retention.doomed (survivors, RetentionMode.SMART, 0, now, zone).size == 0);

    int64 later = now + 3 * 86400;
    var again = Retention.doomed (survivors, RetentionMode.SMART, 0, later, zone);
    foreach (string id in again) assert (id != survivors[survivors.size - 1].id);
    var older_week = Retention.bucket_for (now - 40 * 86400, now, zone);
    assert (older_week != null && older_week.has_prefix ("w"));
    assert (Retention.bucket_for (now + 60, now, zone) == null);

    var single = new Gee.ArrayList<SnapshotInfo> ();
    single.add (fake_snapshot (now - 400 * 86400));
    assert (Retention.doomed (single, RetentionMode.SMART, 0, now, zone).size == 0);

    var fixed = Retention.doomed (list, RetentionMode.KEEP_LAST, 5, now, zone);
    assert (fixed.size == list.size - 5);
    assert (fixed[0] == list[0].id);
    assert (Retention.doomed (list, RetentionMode.KEEP_LAST, 0, now, zone).size == 0);
    assert (RetentionMode.parse ("keep-last") == RetentionMode.KEEP_LAST);
    assert (RetentionMode.parse ("smart") == RetentionMode.SMART);
}

void test_retention_backend () {
    var f = new Fixture ();
    f.plan.retention = RetentionMode.SMART;
    string[] ids = {};
    for (int i = 0; i < 3; i++) {
        put_file (f.home + "/counter.txt", "value %d".printf (i));
        ids += f.backup ().id;
        Thread.usleep (1100000);
    }
    try {
        var left = f.backend.list_snapshots ();
        string first_hour = new DateTime.from_unix_local (parse_snapshot_id (ids[0])).format ("%Y%m%d%H");
        string last_hour = new DateTime.from_unix_local (parse_snapshot_id (ids[2])).format ("%Y%m%d%H");
        if (first_hour == last_hour) {
            assert (left.size == 2);
            assert (left[0].id == ids[0] && left[1].id == ids[2]);
        }
        assert (left[left.size - 1].id == ids[2]);
        assert (get_file (f.tree (left[left.size - 1], "counter.txt")) == "value 2");
    } catch (Error e) {
        error (e.message);
    }
}

string object_file (string repo, string digest) {
    return Path.build_filename (repo, "objects", digest.substring (0, 2), digest);
}

int count_objects (string repo) {
    int n = 0;
    try {
        var buckets = Dir.open (Path.build_filename (repo, "objects"));
        string? b;
        while ((b = buckets.read_name ()) != null) {
            if (b.has_prefix (".")) continue;
            var dir = Dir.open (Path.build_filename (repo, "objects", b));
            while (dir.read_name () != null) n++;
        }
    } catch (FileError e) {
        error (e.message);
    }
    return n;
}

void test_objects_store () {
    var f = new Fixture ("objects");
    put_file (f.home + "/a/copy1.bin", "same content here");
    put_file (f.home + "/b/copy2.bin", "same content here");
    try {
        string info;
        FileUtils.get_contents (Path.build_filename (f.repo, "repository.json"), out info);
        assert ("\"store\" : \"objects\"" in info);
        assert (f.backend.store_mode == "objects");
        var s1 = f.backup ();
        assert (!FileUtils.test (Path.build_filename (f.repo, "snapshots", s1.id, "tree"), FileTest.EXISTS));
        string same = Checksum.compute_for_string (ChecksumType.SHA256, "same content here");
        assert (FileUtils.test (object_file (f.repo, same), FileTest.IS_REGULAR));
        int first_objects = count_objects (f.repo);
        assert (first_objects == 4);
        assert (s1.added_files == 4);
        assert (s1.added_bytes == 39);

        Thread.usleep (1100000);
        var s2 = f.backup ();
        assert (s2.added_files == 0 && s2.added_bytes == 0);
        assert (count_objects (f.repo) == first_objects);

        Thread.usleep (1100000);
        put_file (f.home + "/Documents/report.txt", "second draft, longer");
        put_file (f.home + "/c/copy3.bin", "same content here");
        var s3 = f.backup ();
        assert (s3.added_files == 1);
        assert (count_objects (f.repo) == first_objects + 1);

        var docs = f.backend.list_directory (s3.id, "userdata/Documents");
        assert (find_entry (docs, "report.txt").change == Change.CHANGED);
        assert (find_entry (docs, "notes.md").change == Change.NONE);

        string file = f.backend.materialize (s1.id, "userdata/Documents/report.txt", null);
        assert (get_file (file) == "first draft");

        string elsewhere = make_dir ("objects-restore");
        f.backend.restore (s1.id, "userdata", elsewhere + "/home", false, null);
        assert (get_file (elsewhere + "/home/Documents/report.txt") == "first draft");
        assert (get_file (elsewhere + "/home/b/copy2.bin") == "same content here");
        assert (FileUtils.read_link (elsewhere + "/home/latest-report") == "Documents/report.txt");
        Posix.Stat st;
        Posix.lstat (elsewhere + "/home/Documents/notes.md", out st);
        assert ((st.st_mode & 07777) == 0644);

        assert (f.backend.verify (s3.id, null, null).ok);
        string notes = object_file (f.repo, Checksum.compute_for_string (ChecksumType.SHA256, "# notes"));
        Posix.chmod (notes, 0644);
        put_file (notes, "tampered");
        var r = f.backend.verify (s3.id, null, null);
        assert (!r.ok && r.damaged.length == 1 && r.damaged[0] == "userdata/Documents/notes.md");
        Thread.usleep (1100000);
        var healed = f.backup ();
        assert (healed.added_files == 1);
        assert (f.backend.verify (healed.id, null, null).ok);

        string old_draft = object_file (f.repo, Checksum.compute_for_string (ChecksumType.SHA256, "first draft"));
        assert (FileUtils.test (old_draft, FileTest.EXISTS));
        f.backend.delete_snapshot (s1.id);
        f.backend.delete_snapshot (s2.id);
        assert (!FileUtils.test (old_draft, FileTest.EXISTS));
        assert (FileUtils.test (object_file (f.repo, same), FileTest.EXISTS));
        assert (f.backend.stats ().links);
        assert (f.backend.stats ().store == "objects");

        var reopened = new LocalBackend ();
        reopened.open (f.repo);
        assert (reopened.store_mode == "objects");
        assert (reopened.list_snapshots ().size == 2);
    } catch (Error e) {
        error (e.message);
    }
}

[CCode (cname = "setxattr", cheader_filename = "sys/xattr.h")]
extern int test_setxattr (string path, string name, uint8[] value, int flags);
[CCode (cname = "lgetxattr", cheader_filename = "sys/xattr.h")]
extern ssize_t test_getxattr (string path, string name, uint8[] value);

string? xattr_value (string path, string name) {
    var buf = new uint8[256];
    ssize_t n = test_getxattr (path, name, buf);
    if (n < 0) return null;
    uint8[] value = buf[0:n];
    value += 0;
    return ((string) value).dup ();
}

string acl_of (string path) {
    string output;
    int status;
    try {
        Process.spawn_sync (null, { "getfacl", "--omit-header", "--absolute-names", "--numeric", path }, null, SpawnFlags.SEARCH_PATH,
                            null, out output, null, out status);
    } catch (SpawnError e) {
        return "";
    }
    return output;
}

bool set_acl (string spec, string path) {
    int status;
    try {
        Process.spawn_sync (null, { "setfacl", "-m", spec, path }, null,
                            SpawnFlags.SEARCH_PATH | SpawnFlags.STDERR_TO_DEV_NULL, null, null, null, out status);
    } catch (SpawnError e) {
        return false;
    }
    return status == 0;
}

void check_xattrs (string store) {
    var f = new Fixture (store);
    string file = f.home + "/Documents/report.txt";
    string dir = f.home + "/Shared";
    DirUtils.create_with_parents (dir, 0750);
    put_file (dir + "/plan.txt", "plan");
    if (test_setxattr (file, "user.origin", "downloaded".data, 0) != 0) {
        Test.skip ("user extended attributes are not supported here");
        return;
    }
    test_setxattr (dir, "user.colour", "blue".data, 0);
    bool acl = Environment.find_program_in_path ("setfacl") != null &&
               set_acl ("u:65534:r", file) && set_acl ("d:u:65534:rx", dir) && set_acl ("u:65534:rx", dir);
    string file_acl = acl_of (file).replace (file, "X");
    string dir_acl = acl_of (dir).replace (dir, "X");
    var s = f.backup ();
    string target = make_dir ("xattr-restore") + "/home";
    try {
        f.backend.restore (s.id, "userdata", target, false, null);
        assert (xattr_value (target + "/Documents/report.txt", "user.origin") == "downloaded");
        assert (xattr_value (target + "/Shared", "user.colour") == "blue");
        if (acl) {
            assert ("user:65534:r--" in file_acl);
            assert (acl_of (target + "/Documents/report.txt").replace (target + "/Documents/report.txt", "X") == file_acl);
            assert ("default:user:65534:r-x" in dir_acl);
            assert (acl_of (target + "/Shared").replace (target + "/Shared", "X") == dir_acl);
        }
        string single = make_dir ("xattr-single") + "/report.txt";
        f.backend.restore (s.id, "userdata/Documents/report.txt", single, false, null);
        assert (xattr_value (single, "user.origin") == "downloaded");
        assert (xattr_value (target + "/Documents/notes.md", "user.origin") == null);
    } catch (Error e) {
        error (e.message);
    }
    if (!acl) Test.message ("setfacl is missing, only user attributes were checked");
}

void test_xattrs_tree () {
    check_xattrs ("tree");
}

void test_xattrs_objects () {
    check_xattrs ("objects");
}

void test_battery_policy () {
    assert (!BatteryPolicy.should_pause (false, false, true, 5, 20));
    assert (!BatteryPolicy.should_pause (true, false, false, 5, 20));
    assert (BatteryPolicy.should_pause (true, false, true, 19, 20));
    assert (!BatteryPolicy.should_pause (true, false, true, 20, 20));
    assert (BatteryPolicy.should_pause (true, true, true, 22, 20));
    assert (!BatteryPolicy.should_pause (true, true, true, 25, 20));
    assert (!BatteryPolicy.should_pause (true, true, false, 10, 20));
    assert (!BatteryPolicy.should_pause (true, false, true, -1, 20));
}

void test_pause_gate () {
    var f = new Fixture ("objects");
    for (int i = 0; i < 20; i++) put_file (f.home + "/many/file%d.txt".printf (i), "content %d".printf (i));
    var gate = new PauseGate ();
    gate.pause ();
    f.plan.gate = gate;
    var roots = new Gee.ArrayList<SourceRoot> ();
    try {
        roots.add (new UserDataProvider ().prepare (f.plan, f.repo, f.repo));
    } catch (Error e) {
        error (e.message);
    }
    bool saw_pause = false;
    SnapshotInfo? result = null;
    var worker = new Thread<bool> ("backup", () => {
        try {
            result = f.backend.create_snapshot (f.plan, roots, null, (fr, phase, item) => {
                if (phase == "paused") AtomicInt.set (ref paused_flag, 1);
            });
        } catch (Error e) {
            error (e.message);
        }
        return true;
    });
    Thread.usleep (700000);
    saw_pause = AtomicInt.get (ref paused_flag) == 1;
    assert (saw_pause);
    assert (result == null);
    try {
        assert (f.backend.list_snapshots ().size == 0);
    } catch (Error e) {
        error (e.message);
    }
    gate.resume ();
    worker.join ();
    assert (result != null && result.files > 20);

    var cancel = new Cancellable ();
    gate.pause ();
    var stuck = new Thread<bool> ("cancel", () => {
        try {
            f.backend.create_snapshot (f.plan, roots, cancel, (fr, phase, item) => {});
        } catch (BackupError.CANCELLED e) {
            return true;
        } catch (Error e) {
            return false;
        }
        return false;
    });
    Thread.usleep (300000);
    cancel.cancel ();
    assert (stuck.join ());
}

Bytes builder_bytes (Gee.List<Entry> list) {
    var b = new VariantBuilder (new VariantType ("a(ayyutxsay)"));
    foreach (var e in list) {
        b.add ("(@ayyutxs@ay)", new Variant.bytestring (e.path), (uchar) e.kind.to_char (), e.mode, e.size, e.mtime_ns, e.digest, new Variant.bytestring (e.target));
    }
    return b.end ().get_data_as_bytes ();
}

void test_index_format () {
    string dir = make_dir ("index");
    foreach (int n in new int[] { 0, 1, 3, 40, 2000, 6000 }) {
        var list = new Gee.ArrayList<Entry> ();
        var memory = new SnapshotIndex ();
        for (int i = 0; i < n; i++) {
            string path = i % 10 == 0 ? "d%d".printf (i / 10) : "d%d/f%d".printf (i / 10, i);
            var e = new Entry.with (path, i % 10 == 0 ? EntryKind.DIRECTORY : EntryKind.FILE, 0644 + i % 3, i * 7, i * 1000000000LL,
                                    i % 10 == 0 ? "" : Checksum.compute_for_string (ChecksumType.SHA256, path));
            if (i % 17 == 5) {
                e.kind = EntryKind.SYMLINK;
                e.target = "../t%d".printf (i);
                e.digest = "";
            }
            list.add (e);
            memory.add (e);
        }
        string file = Path.build_filename (dir, "index-%d".printf (n));
        try {
            memory.save (file);
            uint8[] data;
            FileUtils.get_data (file, out data);
            var expected = builder_bytes (list);
            assert (data.length == expected.length);
            assert (Memory.cmp (data, expected.get_data (), data.length) == 0);
            var loaded = SnapshotIndex.load (file);
            assert (loaded.size == n);
            int seen = 0;
            foreach (var e in loaded) {
                var want = list[seen++];
                assert (e.path == want.path && e.kind == want.kind && e.mode == want.mode && e.size == want.size);
                assert (e.mtime_ns == want.mtime_ns && e.digest == want.digest && e.target == want.target);
            }
            assert (seen == n);
            foreach (var want in list) {
                var got = loaded.lookup (want.path);
                assert (got != null && got.path == want.path && got.digest == want.digest);
            }
            assert (loaded.lookup ("missing/file") == null);
            if (n >= 40) {
                assert (loaded.has_dir ("d2"));
                assert (!loaded.has_dir ("d2/f21"));
                assert (loaded.list ("d2").size == 9);
                assert (loaded.list ("").size == n / 10);
                assert (loaded.digest_at (21) == list[21].digest);
            }
        } catch (Error e) {
            error (e.message);
        }
    }
}

uint64 links_of (string path) {
    Posix.Stat st;
    assert (Posix.lstat (path, out st) == 0);
    return (uint64) st.st_nlink;
}

void test_link_limit () {
    var f = new Fixture ("tree");
    f.backend.link_limit = 4;
    for (int i = 0; i < 10; i++) put_file (f.home + "/same/copy%d.txt".printf (i), "identical content");
    var s1 = f.backup ();
    assert (s1.added_files == 13);
    var s2 = f.backup ();
    assert (s2.added_files == 0);
    uint64 anchors2 = f.backend.last_anchor_copies;
    assert (anchors2 > 0);
    var s3 = f.backup ();
    assert (s3.added_files == 0);
    var s4 = f.backup ();
    assert (s4.added_files == 0);
    assert (f.backend.last_anchor_copies > 0);
    foreach (var s in new SnapshotInfo[] { s1, s2, s3, s4 }) {
        for (int i = 0; i < 10; i++) {
            string file = f.tree (s, "same/copy%d.txt".printf (i));
            assert (get_file (file) == "identical content");
            assert (links_of (file) <= 4);
        }
        assert (get_file (f.tree (s, "Documents/report.txt")) == "first draft");
        try {
            assert (f.backend.verify (s.id, null, null).ok);
        } catch (Error e) {
            error (e.message);
        }
    }
    var inodes = new Gee.HashSet<string> ();
    for (int i = 0; i < 10; i++) inodes.add (inode (f.tree (s4, "same/copy%d.txt".printf (i))).to_string ());
    assert (inodes.size >= 3 && inodes.size < 10);
}

int paused_flag = 0;

void test_object_references_streamed () {
    var f = new Fixture ("objects");
    f.backend.reference_chunk = 3;
    for (int i = 0; i < 40; i++) put_file (f.home + "/many/kept%02d.txt".printf (i), "kept %d".printf (i));
    for (int i = 0; i < 25; i++) put_file (f.home + "/many/gone%02d.txt".printf (i), "gone %d".printf (i));
    try {
        var s1 = f.backup ();
        for (int i = 0; i < 25; i++) FileUtils.unlink (f.home + "/many/gone%02d.txt".printf (i));
        put_file (f.home + "/many/fresh.txt", "fresh");
        Thread.usleep (1100000);
        var s2 = f.backup ();
        string stray = object_file (f.repo, Checksum.compute_for_string (ChecksumType.SHA256, "never referenced"));
        DirUtils.create_with_parents (Path.get_dirname (stray), 0700);
        put_file (stray, "never referenced");
        int before = count_objects (f.repo);
        f.backend.delete_snapshot (s1.id);
        assert (count_objects (f.repo) == before - 26);
        assert (!FileUtils.test (stray, FileTest.EXISTS));
        for (int i = 0; i < 25; i++) {
            string digest = Checksum.compute_for_string (ChecksumType.SHA256, "gone %d".printf (i));
            assert (!FileUtils.test (object_file (f.repo, digest), FileTest.EXISTS));
        }
        for (int i = 0; i < 40; i++) {
            string digest = Checksum.compute_for_string (ChecksumType.SHA256, "kept %d".printf (i));
            assert (FileUtils.test (object_file (f.repo, digest), FileTest.EXISTS));
        }
        assert (f.backend.verify (s2.id, null, null).ok);
        var leftovers = Dir.open (Path.build_filename (f.repo, "snapshots", ".partial"));
        assert (leftovers.read_name () == null);

        string index = Path.build_filename (f.repo, "snapshots", s2.id, "index");
        var loaded = SnapshotIndex.load (index);
        var streamed = new Gee.ArrayList<string> ();
        SnapshotIndex.each_digest (index, (digest) => streamed.add (digest));
        assert (streamed.size == loaded.size);
        for (int i = 0; i < loaded.size; i++) assert (streamed[i] == loaded.digest_at (i));

        uint8[] data;
        FileUtils.get_data (index, out data);
        FileUtils.set_data (index, data[0:data.length - 3]);
        int kept = count_objects (f.repo);
        Thread.usleep (1100000);
        var s3 = f.backup ();
        f.backend.delete_snapshot (s3.id);
        assert (count_objects (f.repo) == kept);
    } catch (Error e) {
        error (e.message);
    }
}

void test_resume_large_file () {
    var f = new Fixture ("objects");
    var data = new uint8[70 * 1024 * 1024];
    for (int i = 0; i < data.length; i++) data[i] = (uint8) ((i * 31 + (i >> 12)) & 0xff);
    try {
        FileUtils.set_data (f.home + "/big.bin", data);
    } catch (FileError e) {
        error (e.message);
    }
    string expected = Checksum.compute_for_data (ChecksumType.SHA256, data);
    var cancel = new Cancellable ();
    var roots = new Gee.ArrayList<SourceRoot> ();
    bool cancelled = false;
    try {
        roots.add (new UserDataProvider ().prepare (f.plan, f.repo, f.repo));
        f.backend.create_snapshot (f.plan, roots, cancel, (fr, phase, item) => {
            if (fr > 0.2 && !cancel.is_cancelled ()) cancel.cancel ();
        });
    } catch (BackupError.CANCELLED e) {
        cancelled = true;
    } catch (Error e) {
        error (e.message);
    }
    assert (cancelled);
    string resume = Path.build_filename (f.repo, "objects", ".resume");
    int64 partial = 0;
    try {
        var d = Dir.open (resume);
        string? name;
        while ((name = d.read_name ()) != null) {
            if (!name.has_suffix (".part")) continue;
            Posix.Stat st;
            if (Posix.stat (Path.build_filename (resume, name), out st) == 0) partial = (int64) st.st_size;
        }
    } catch (FileError e) {
        error (e.message);
    }
    assert (partial > 0 && partial < data.length);
    var s = f.backup ();
    assert (FileUtils.test (object_file (f.repo, expected), FileTest.IS_REGULAR));
    uint8[] stored;
    try {
        FileUtils.get_data (object_file (f.repo, expected), out stored);
    } catch (FileError e) {
        error (e.message);
    }
    assert (stored.length == data.length && Checksum.compute_for_data (ChecksumType.SHA256, stored) == expected);
    assert (s.added_files > 0);
    try {
        var d = Dir.open (resume);
        string? name;
        while ((name = d.read_name ()) != null) assert (!name.has_suffix (".part"));
    } catch (FileError e) {
        error (e.message);
    }
}

int main (string[] args) {
    Test.init (ref args);
    Intl.setlocale (LocaleCategory.ALL, "C");
    Test.add_func ("/backups/exclusions", test_exclusions);
    Test.add_func ("/backups/first-backup", test_first_backup);
    Test.add_func ("/backups/incremental-links", test_incremental_links);
    Test.add_func ("/backups/dedup", test_dedup);
    Test.add_func ("/backups/restore-conflicts", test_restore_and_conflicts);
    Test.add_func ("/backups/verify", test_verify_detects_damage);
    Test.add_func ("/backups/prune", test_prune);
    Test.add_func ("/backups/cancel", test_cancel);
    Test.add_func ("/backups/repo-inside-home", test_repo_inside_home);
    Test.add_func ("/backups/schedule", test_schedule);
    Test.add_func ("/backups/system-config", test_system_config);
    Test.add_func ("/backups/flatpak-provider", test_flatpak_provider);
    Test.add_func ("/backups/abroot-detection", test_abroot_detection);
    Test.add_func ("/backups/exec-backend", test_exec_backend);
    Test.add_func ("/backups/retention-smart", test_retention_smart);
    Test.add_func ("/backups/retention-backend", test_retention_backend);
    Test.add_func ("/backups/objects-store", test_objects_store);
    Test.add_func ("/backups/resume-large-file", test_resume_large_file);
    Test.add_func ("/backups/object-references-streamed", test_object_references_streamed);
    Test.add_func ("/backups/xattrs-tree", test_xattrs_tree);
    Test.add_func ("/backups/xattrs-objects", test_xattrs_objects);
    Test.add_func ("/backups/battery-policy", test_battery_policy);
    Test.add_func ("/backups/pause-gate", test_pause_gate);
    Test.add_func ("/backups/index-format", test_index_format);
    Test.add_func ("/backups/link-limit", test_link_limit);
    register_remote_tests ();
    return Test.run ();
}
