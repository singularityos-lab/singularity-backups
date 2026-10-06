using Singularity.Backups;

string sha_of (string path) {
    uint8[] data;
    try {
        FileUtils.get_data (path, out data);
    } catch (Error e) {
        error (e.message);
    }
    return Checksum.compute_for_data (ChecksumType.SHA256, data);
}

class RemoteFixture {
    public string home;
    public string remote;
    public string cache;
    public FolderStore store;
    public BackupPlan plan;

    public RemoteFixture () {
        home = make_dir ("rhome");
        remote = make_dir ("remote");
        cache = make_dir ("rcache");
        put_file (home + "/Documents/report.txt", "first draft");
        put_file (home + "/Documents/copy.txt", "first draft");
        put_file (home + "/Pictures/cat.txt", "meow");
        put_file (home + "/empty.txt", "");
        uint8[] big = new uint8[3 * 1024 * 1024 + 17];
        for (int i = 0; i < big.length; i++) big[i] = (uint8) ((i * 7919) & 0xff);
        try {
            FileUtils.set_data (home + "/Pictures/big.raw", big);
        } catch (Error e) {
            error (e.message);
        }
        FileUtils.symlink ("Documents/report.txt", home + "/latest-report");
        store = new FolderStore (remote);
        plan = new BackupPlan ();
        plan.source_home = home;
        plan.exclusions = Exclusions.DEFAULTS;
        plan.host = "test";
    }

    public RemoteBackend open (string? passphrase) throws Error {
        var b = new RemoteBackend (store, cache, passphrase);
        b.retry_delay_ms = 10;
        b.open ("Singularity Backups/test@host");
        return b;
    }

    public SnapshotInfo backup (RemoteBackend b) throws Error {
        var roots = new Gee.ArrayList<SourceRoot> ();
        roots.add (new UserDataProvider ().prepare (plan, cache, null));
        return b.create_snapshot (plan, roots, null, (f, phase, item) => {
            assert (f >= 0 && f <= 1);
        });
    }

    public int count_objects () {
        int n = 0;
        try {
            var d = Dir.open (remote + "/Singularity Backups/test@host/objects");
            while (d.read_name () != null) n++;
        } catch (FileError e) {
        }
        return n;
    }
}

bool contains_bytes (string file, string needle) {
    uint8[] data;
    try {
        FileUtils.get_data (file, out data);
    } catch (Error e) {
        return false;
    }
    string text = (string) data;
    for (int i = 0; i + needle.length <= data.length; i++) {
        if (Memory.cmp (&data[i], needle.data, needle.length) == 0) return true;
    }
    return text.contains (needle);
}

void check_remote_roundtrip (string? passphrase) {
    var f = new RemoteFixture ();
    try {
        var b = f.open (passphrase);
        assert (b.encrypted == (passphrase != null));
        var s1 = f.backup (b);
        assert (s1.files > 0 && s1.added_files == 4);
        int objects = f.count_objects ();
        assert (objects == 4);

        if (passphrase != null) {
            string objdir = f.remote + "/Singularity Backups/test@host/objects";
            var d = Dir.open (objdir);
            string? n;
            while ((n = d.read_name ()) != null) {
                assert (!contains_bytes (objdir + "/" + n, "first draft"));
                assert (!contains_bytes (objdir + "/" + n, "meow"));
                assert (n != Checksum.compute_for_string (ChecksumType.SHA256, "meow"));
            }
            assert (!contains_bytes (f.remote + "/Singularity Backups/test@host/snapshots/%s.index".printf (s1.id), "report.txt"));
        }

        Thread.usleep (1100000);
        put_file (f.home + "/Documents/report.txt", "final version");
        put_file (f.home + "/Documents/new.txt", "brand new");
        FileUtils.unlink (f.home + "/Pictures/cat.txt");
        var s2 = f.backup (b);
        assert (s2.added_files == 2);
        assert (f.count_objects () == 6);

        var fresh_cache = make_dir ("rcache2");
        var other = new RemoteBackend (f.store, fresh_cache, passphrase);
        other.open ("Singularity Backups/test@host");
        var list = other.list_snapshots ();
        assert (list.size == 2 && list[0].id == s1.id);
        var entries = other.list_directory (s2.id, "userdata/Documents");
        bool saw_changed = false;
        bool saw_added = false;
        foreach (var e in entries) {
            if (e.name == "report.txt") saw_changed = e.change == Change.CHANGED;
            if (e.name == "new.txt") saw_added = e.change == Change.ADDED;
        }
        assert (saw_changed && saw_added);
        var gone = other.list_directory (s2.id, "userdata/Pictures");
        bool saw_removed = false;
        foreach (var e in gone) if (e.name == "cat.txt") saw_removed = e.change == Change.REMOVED;
        assert (saw_removed);

        string target = make_dir ("rrestore") + "/home";
        other.restore (s1.id, "userdata", target, false, null);
        assert (get_file (target + "/Documents/report.txt") == "first draft");
        assert (get_file (target + "/Pictures/cat.txt") == "meow");
        assert (get_file (target + "/empty.txt") == "");
        assert (sha_of (target + "/Pictures/big.raw") == sha_of (f.home + "/Pictures/big.raw"));
        assert (FileUtils.read_link (target + "/latest-report") == "Documents/report.txt");
        string file = other.materialize (s2.id, "userdata/Documents/report.txt", null);
        assert (get_file (file) == "final version");

        var v = other.verify (s2.id, null, null);
        assert (v.ok && v.checked >= 4);
        other.delete_snapshot (s1.id);
        assert (other.list_snapshots ().size == 1);
        assert (f.count_objects () == 5);
    } catch (Error e) {
        error (e.message);
    }
}

void test_remote_plain () {
    check_remote_roundtrip (null);
}

void test_remote_encrypted () {
    check_remote_roundtrip ("correct horse battery staple");
}

void test_remote_passphrase () {
    var f = new RemoteFixture ();
    try {
        var b = f.open ("secret one");
        f.backup (b);
    } catch (Error e) {
        error (e.message);
    }
    try {
        f.open ("wrong");
        assert_not_reached ();
    } catch (BackupError.PASSPHRASE e) {
    } catch (Error e) {
        error (e.message);
    }
    try {
        f.open (null);
        assert_not_reached ();
    } catch (BackupError.PASSPHRASE e) {
    } catch (Error e) {
        error (e.message);
    }
    try {
        var b = f.open ("secret one");
        assert (b.list_snapshots ().size == 1);
    } catch (Error e) {
        error (e.message);
    }
}

void test_remote_damage () {
    var f = new RemoteFixture ();
    try {
        var b = f.open ("pw");
        var s = f.backup (b);
        string objdir = f.remote + "/Singularity Backups/test@host/objects";
        var d = Dir.open (objdir);
        string? n;
        string victim = "";
        int64 largest = -1;
        while ((n = d.read_name ()) != null) {
            Posix.Stat st;
            Posix.stat (objdir + "/" + n, out st);
            if (st.st_size > largest) {
                largest = st.st_size;
                victim = objdir + "/" + n;
            }
        }
        uint8[] data;
        FileUtils.get_data (victim, out data);
        data[data.length / 2] ^= 0x55;
        FileUtils.set_data (victim, data);
        var v = b.verify (s.id, null, null);
        assert (!v.ok && v.damaged.length == 1 && v.damaged[0] == "userdata/Pictures/big.raw");
        assert (!FileUtils.test (victim, FileTest.EXISTS));
        Thread.usleep (1100000);
        var s2 = f.backup (b);
        assert (s2.added_files == 1);
        assert (b.verify (s2.id, null, null).ok);
    } catch (Error e) {
        error (e.message);
    }
}

void test_exec_store () {
    string? script = Environment.get_variable ("TEST_DESTINATION");
    if (script == null) {
        Test.skip ("TEST_DESTINATION not set");
        return;
    }
    var f = new RemoteFixture ();
    string root = make_dir ("destroot");
    Environment.set_variable ("FAKE_DEST_ROOT", root, true);
    try {
        var store = new ExecStore (script, "box");
        var b = new RemoteBackend (store, f.cache, "pw");
        b.retry_delay_ms = 10;
        b.open ("Singularity Backups/test@host");
        Environment.set_variable ("FAKE_DEST_FAIL_AFTER", "2", true);
        store.close ();
        var roots = new Gee.ArrayList<SourceRoot> ();
        roots.add (new UserDataProvider ().prepare (f.plan, f.cache, null));
        try {
            b.create_snapshot (f.plan, roots, null, (fr, ph, it) => {});
            assert_not_reached ();
        } catch (BackupError.UNAVAILABLE e) {
        }
        Environment.unset_variable ("FAKE_DEST_FAIL_AFTER");
        store.close ();
        assert (b.list_snapshots ().size == 0);
        var s = b.create_snapshot (f.plan, roots, null, (fr, ph, it) => {});
        assert (s.added_files == 2);
        uint64 used, total;
        store.space (out used, out total);
        assert (total == 1073741824 && used > 0);
        var stats = b.stats ();
        assert (stats.encrypted && stats.capacity == 1073741824);
        FileUtils.set_contents (root + "/.offline", "");
        try {
            b.list_snapshots ();
            assert_not_reached ();
        } catch (BackupError.UNAVAILABLE e) {
        }
        FileUtils.unlink (root + "/.offline");
        string target = make_dir ("xrestore") + "/out";
        b.restore (s.id, "userdata/Pictures", target, false, null);
        assert (sha_of (target + "/big.raw") == sha_of (f.home + "/Pictures/big.raw"));
        store.close ();
    } catch (Error e) {
        error (e.message);
    }
}

void test_plugin_discovery () {
    string data = make_dir ("xdgdata");
    string old = Environment.get_variable ("XDG_DATA_HOME");
    Environment.set_variable ("XDG_DATA_HOME", data, true);
    string sources = data + "/singularity/backups/sources";
    string dests = data + "/singularity/backups/destinations";
    put_file (sources + "/notes.backup-source", "[Backup Source]\nName=Notes\nDescription=Test notes\nIcon=text-x-generic\nExec=./notes.sh\n");
    put_file (sources + "/notes.sh", "#!/bin/sh\necho '{\"available\": true}'\n");
    Posix.chmod (sources + "/notes.sh", 0755);
    put_file (sources + "/broken.backup-source", "[Backup Source]\nName=Broken\n");
    put_file (sources + "/future.backup-source", "[Backup Source]\nName=Future\nExec=/bin/true\nProtocol=9\n");
    put_file (dests + "/box.backup-destination", "[Backup Destination]\nName=Box\nExec=/bin/true\n");
    put_file (data + "/singularity/backups/sources/missing.backup-source", "[Backup Source]\nName=Missing\nExec=/nonexistent/plugin\n");
    var found = PluginRegistry.discover (PluginKind.SOURCE);
    PluginManifest? notes = null;
    PluginManifest? missing = null;
    foreach (var m in found) {
        if (m.id == "notes") notes = m;
        if (m.id == "missing") missing = m;
        assert (m.id != "broken" && m.id != "future");
    }
    assert (notes != null && notes.user_installed && notes.exec == sources + "/notes.sh" && notes.runnable);
    assert (missing != null && !missing.runnable);
    assert (PluginRegistry.find (PluginKind.DESTINATION, "box") != null);
    bool listed = false;
    foreach (var p in Providers.all ()) if (p.id == "notes") listed = true;
    assert (listed);
    if (old != null) Environment.set_variable ("XDG_DATA_HOME", old, true);
    else Environment.unset_variable ("XDG_DATA_HOME");
}

void test_plugin_source () {
    string? script = Environment.get_variable ("TEST_SOURCE");
    if (script == null) {
        Test.skip ("TEST_SOURCE not set");
        return;
    }
    var f = new Fixture ();
    string payload = f.home + "/fake-source";
    put_file (payload + "/app-one/settings.ini", "[a]\nb=1\n");
    put_file (payload + "/app-one/debug.log", "noise");
    put_file (payload + "/app-two/state.json", "{}");
    Environment.set_variable ("FAKE_SOURCE_DATA", payload, true);
    var m = new PluginManifest ();
    m.kind = PluginKind.SOURCE;
    m.id = "fake";
    m.name = "Fake";
    m.exec = script;
    var p = new PluginProvider (m);
    PluginProvider.forget_checks ();
    assert (p.available (f.plan));
    try {
        string staging = make_dir ("pstaging");
        var roots = new Gee.ArrayList<SourceRoot> ();
        roots.add (p.prepare (f.plan, staging, f.repo));
        foreach (var r in p.data_roots (f.plan)) roots.add (r);
        assert (p.home_exclusions.length == 1 && p.warnings.length == 1);
        var s = f.backend.create_snapshot (f.plan, roots, null, (fr, ph, i) => {});
        assert (f.backend.lookup (s.id, "fake/list.txt") != null);
        assert (f.backend.lookup (s.id, "fake/data/app-one/settings.ini") != null);
        assert (f.backend.lookup (s.id, "fake/data/app-one/debug.log") == null);
        FileUtils.unlink (payload + "/app-one/settings.ini");
        put_file (payload + "/app-two/state.json", "{\"changed\": true}");
        p.restore_all (f.backend, s.id, f.plan, null);
        assert (get_file (payload + "/app-one/settings.ini") == "[a]\nb=1\n");
        assert (get_file (payload + "/app-two/state.json") == "{}");
        assert (get_file (payload + ".restored-list") == "app-one\napp-two\n");
    } catch (Error e) {
        error (e.message);
    }
    Environment.set_variable ("FAKE_SOURCE_DATA", "/nonexistent", true);
    PluginProvider.forget_checks ();
    assert (!p.available (f.plan) && p.unavailable_reason == "Nothing to back up");
}

void register_remote_tests () {
    Test.add_func ("/backups/remote-plain", test_remote_plain);
    Test.add_func ("/backups/remote-encrypted", test_remote_encrypted);
    Test.add_func ("/backups/remote-passphrase", test_remote_passphrase);
    Test.add_func ("/backups/remote-damage", test_remote_damage);
    Test.add_func ("/backups/exec-store", test_exec_store);
    Test.add_func ("/backups/plugin-discovery", test_plugin_discovery);
    Test.add_func ("/backups/plugin-source", test_plugin_source);
}
