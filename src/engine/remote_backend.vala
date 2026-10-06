namespace Singularity.Backups {

    public class RemoteBackend : Object, Backend {
        public const int FORMAT = 1;
        private const int ATTEMPTS = 3;

        private RemoteStore store;
        private string prefix = "";
        private string cache = "";
        private string? passphrase;
        private Sealing? sealing = null;
        private string uuid = "";
        private HashTable<string, SnapshotIndex> indexes = new HashTable<string, SnapshotIndex> (str_hash, str_equal);
        private HashTable<string, SnapshotInfo> manifests = new HashTable<string, SnapshotInfo> (str_hash, str_equal);
        private HashTable<string, Gee.HashSet<string>> touched = new HashTable<string, Gee.HashSet<string>> (str_hash, str_equal);
        private HashTable<string, uint64?>? objects = null;
        private Mutex mutex = Mutex ();
        public uint retry_delay_ms { get; set; default = 2000; }

        public string id { owned get { return "remote"; } }
        public string location { owned get { return prefix; } }
        public bool supports_dedup { get { return true; } }
        public bool encrypted { get { return sealing != null; } }
        public bool created_now { get; private set; default = false; }
        public string repository_uuid { get { return uuid; } }

        public void close () {
            store.close ();
        }

        public RemoteBackend (RemoteStore store, string cache_root, string? passphrase) {
            this.store = store;
            this.cache = cache_root;
            this.passphrase = passphrase;
        }

        private string key (string name) {
            return prefix == "" ? name : prefix + "/" + name;
        }

        private delegate void Attempt () throws Error;

        private void retrying (Attempt attempt, Cancellable? cancellable) throws Error {
            for (int i = 1; ; i++) {
                try {
                    attempt ();
                    return;
                } catch (BackupError e) {
                    bool transient = e is BackupError.FAILED || e is BackupError.UNAVAILABLE;
                    if (!transient || i >= ATTEMPTS) throw e;
                    if (cancellable != null && cancellable.is_cancelled ()) throw new BackupError.CANCELLED (_("The backup was cancelled"));
                    Thread.usleep ((ulong) retry_delay_ms * 1000 * i);
                } catch (IOError.CANCELLED e) {
                    throw new BackupError.CANCELLED (_("The backup was cancelled"));
                }
            }
        }

        private void upload (string name, string file, Cancellable? cancellable, SealStep? step) throws Error {
            retrying (() => store.put (key (name), file, cancellable, step), cancellable);
        }

        private void download (string name, string file, Cancellable? cancellable) throws Error {
            retrying (() => store.fetch (key (name), file, cancellable), cancellable);
        }

        private string scratch (string name) {
            string dir = Path.build_filename (cache, ".incoming");
            DirUtils.create_with_parents (dir, 0700);
            return Path.build_filename (dir, "%s-%s".printf (name, Uuid.string_random ()));
        }

        private void put_small (string name, uint8[] plain) throws Error {
            string tmp = scratch ("meta");
            try {
                FileUtils.set_data (tmp, sealing != null ? sealing.seal_bytes (plain) : plain);
                upload (name, tmp, null, null);
            } finally {
                FileUtils.unlink (tmp);
            }
        }

        private uint8[] get_small (string name) throws Error {
            string tmp = scratch ("meta");
            try {
                download (name, tmp, null);
                uint8[] data;
                FileUtils.get_data (tmp, out data);
                return sealing != null ? sealing.open_bytes (data) : data;
            } finally {
                FileUtils.unlink (tmp);
            }
        }

        public static Json.Object? peek (RemoteStore store, string prefix) throws Error {
            var parser = new Json.Parser ();
            string dir = Path.build_filename (Environment.get_user_cache_dir (), "singularity-backups");
            DirUtils.create_with_parents (dir, 0700);
            string tmp = Path.build_filename (dir, ".peek-%s".printf (Uuid.string_random ()));
            try {
                store.fetch (prefix + "/repository.json", tmp, null);
                parser.load_from_file (tmp);
            } catch (BackupError.NOT_FOUND e) {
                return null;
            } finally {
                FileUtils.unlink (tmp);
            }
            return parser.get_root ().get_object ();
        }

        public void open (string location) throws Error {
            prefix = location;
            while (prefix.has_suffix ("/")) prefix = prefix.substring (0, prefix.length - 1);
            Json.Object? info = null;
            string tmp = Path.build_filename (Environment.get_user_cache_dir (), "singularity-backups", ".repo-%s".printf (Uuid.string_random ()));
            DirUtils.create_with_parents (Path.get_dirname (tmp), 0700);
            try {
                retrying (() => store.fetch (key ("repository.json"), tmp, null), null);
                var parser = new Json.Parser ();
                parser.load_from_file (tmp);
                info = parser.get_root ().get_object ();
            } catch (BackupError.NOT_FOUND e) {
                info = null;
            } finally {
                FileUtils.unlink (tmp);
            }
            if (info != null) {
                if (info.get_int_member_with_default ("format", 1) > FORMAT) {
                    throw new BackupError.UNSUPPORTED (_("These backups were made by a newer version of Backups"));
                }
                uuid = info.get_string_member_with_default ("uuid", "");
                if (info.has_member ("encryption")) {
                    if (passphrase == null || passphrase == "") throw new BackupError.PASSPHRASE (_("These backups are encrypted. Enter the passphrase to use them."));
                    sealing = Sealing.unlock (passphrase, info.get_object_member ("encryption"));
                }
            } else {
                if (passphrase != null && passphrase != "") sealing = Sealing.create (passphrase);
                uuid = Uuid.string_random ();
                var b = new Json.Builder ();
                b.begin_object ();
                b.set_member_name ("format");
                b.add_int_value (FORMAT);
                b.set_member_name ("engine");
                b.add_string_value ("singularity-backups");
                b.set_member_name ("store");
                b.add_string_value ("remote");
                b.set_member_name ("created");
                b.add_int_value (new DateTime.now_utc ().to_unix ());
                b.set_member_name ("uuid");
                b.add_string_value (uuid);
                if (sealing != null) {
                    b.set_member_name ("encryption");
                    b.add_value (sealing.to_json ());
                }
                b.end_object ();
                var g = new Json.Generator ();
                g.pretty = true;
                g.root = b.get_root ();
                string file = scratch ("repository");
                try {
                    FileUtils.set_contents (file, g.to_data (null));
                    upload ("repository.json", file, null, null);
                } finally {
                    FileUtils.unlink (file);
                }
                created_now = true;
            }
            cache = Path.build_filename (cache, uuid != "" ? uuid : Checksum.compute_for_string (ChecksumType.SHA1, store.identity + prefix));
            DirUtils.create_with_parents (Path.build_filename (cache, "snapshots"), 0700);
        }

        private HashTable<string, uint64?> remote_objects (Cancellable? cancellable) throws Error {
            var table = new HashTable<string, uint64?> (str_hash, str_equal);
            Gee.List<RemoteObject>? found = null;
            retrying (() => { found = store.list (key ("objects"), cancellable); }, cancellable);
            string head = key ("objects") + "/";
            foreach (var o in found) {
                string name = o.key.has_prefix (head) ? o.key.substring (head.length) : Path.get_basename (o.key);
                table[name] = o.size;
            }
            return table;
        }

        private string object_name (string digest) {
            return sealing != null ? sealing.object_name (digest) : digest;
        }

        public Gee.List<SnapshotInfo> list_snapshots () throws Error {
            Gee.List<RemoteObject>? found = null;
            retrying (() => { found = store.list (key ("snapshots"), null); }, null);
            var list = new Gee.ArrayList<SnapshotInfo> ();
            foreach (var o in found) {
                string name = Path.get_basename (o.key);
                if (!name.has_suffix (".manifest")) continue;
                var info = read_manifest (name.substring (0, name.length - 9));
                if (info != null) list.add (info);
            }
            list.sort ((a, b) => {
                if (a.created != b.created) return a.created < b.created ? -1 : 1;
                return strcmp (a.id, b.id);
            });
            return list;
        }

        private SnapshotInfo? read_manifest (string snapshot) {
            mutex.lock ();
            var cached = manifests[snapshot];
            mutex.unlock ();
            if (cached != null) return cached;
            string file = Path.build_filename (cache, "snapshots", snapshot + ".manifest");
            var parser = new Json.Parser ();
            try {
                if (!FileUtils.test (file, FileTest.EXISTS)) {
                    uint8[] data = get_small ("snapshots/%s.manifest".printf (snapshot));
                    FileUtils.set_data (file, data);
                }
                parser.load_from_file (file);
            } catch (Error e) {
                return null;
            }
            var o = parser.get_root ().get_object ();
            if (!o.get_boolean_member_with_default ("complete", false)) return null;
            var info = new SnapshotInfo ();
            info.id = snapshot;
            info.created = o.get_int_member_with_default ("created", parse_snapshot_id (snapshot));
            info.label = o.get_string_member_with_default ("label", "");
            info.host = o.get_string_member_with_default ("host", "");
            info.files = o.get_int_member_with_default ("files", 0);
            info.bytes = o.get_int_member_with_default ("bytes", 0);
            info.added_files = o.get_int_member_with_default ("added-files", 0);
            info.added_bytes = o.get_int_member_with_default ("added-bytes", 0);
            string[] providers = {};
            if (o.has_member ("providers")) foreach (var n in o.get_array_member ("providers").get_elements ()) providers += n.get_string ();
            info.providers = providers;
            string[] warnings = {};
            if (o.has_member ("warnings")) foreach (var n in o.get_array_member ("warnings").get_elements ()) warnings += n.get_string ();
            info.warnings = warnings;
            mutex.lock ();
            manifests[snapshot] = info;
            mutex.unlock ();
            return info;
        }

        private static uint8[] manifest_json (SnapshotInfo info) {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("format");
            b.add_int_value (FORMAT);
            b.set_member_name ("id");
            b.add_string_value (info.id);
            b.set_member_name ("created");
            b.add_int_value (info.created);
            b.set_member_name ("label");
            b.add_string_value (info.label);
            b.set_member_name ("host");
            b.add_string_value (info.host);
            b.set_member_name ("files");
            b.add_int_value ((int64) info.files);
            b.set_member_name ("bytes");
            b.add_int_value ((int64) info.bytes);
            b.set_member_name ("added-files");
            b.add_int_value ((int64) info.added_files);
            b.set_member_name ("added-bytes");
            b.add_int_value ((int64) info.added_bytes);
            b.set_member_name ("providers");
            b.begin_array ();
            foreach (string p in info.providers) b.add_string_value (p);
            b.end_array ();
            b.set_member_name ("warnings");
            b.begin_array ();
            foreach (string w in info.warnings) b.add_string_value (w);
            b.end_array ();
            b.set_member_name ("complete");
            b.add_boolean_value (true);
            b.end_object ();
            var g = new Json.Generator ();
            g.pretty = true;
            g.root = b.get_root ();
            return g.to_data (null).data;
        }

        public SnapshotIndex index_for (string snapshot) throws Error {
            mutex.lock ();
            var cached = indexes[snapshot];
            mutex.unlock ();
            if (cached != null) return cached;
            string file = Path.build_filename (cache, "snapshots", snapshot + ".index");
            if (!FileUtils.test (file, FileTest.EXISTS)) {
                uint8[] data;
                try {
                    data = get_small ("snapshots/%s.index".printf (snapshot));
                } catch (BackupError.NOT_FOUND e) {
                    throw new BackupError.NOT_FOUND (_("The backup %s does not exist"), snapshot);
                }
                FileUtils.set_data (file + ".part", data);
                FileUtils.rename (file + ".part", file);
            }
            var index = SnapshotIndex.load (file);
            mutex.lock ();
            indexes[snapshot] = index;
            mutex.unlock ();
            return index;
        }

        private XattrSet attrs_for (string snapshot) {
            string file = Path.build_filename (cache, "snapshots", snapshot + ".xattrs");
            if (!FileUtils.test (file, FileTest.EXISTS)) {
                try {
                    FileUtils.set_data (file, get_small ("snapshots/%s.xattrs".printf (snapshot)));
                } catch (Error e) {
                    return new XattrSet ();
                }
            }
            return XattrSet.load (file);
        }

        private class Run {
            public BackupPlan plan;
            public Cancellable? cancellable;
            public unowned ProgressFunc progress;
            public SnapshotIndex? previous = null;
            public HashTable<string, uint64?> objects;
            public IndexWriter index;
            public XattrSet attrs = new XattrSet ();
            public Gee.ArrayList<string> warnings = new Gee.ArrayList<string> ();
            public uint64 to_send = 0;
            public uint64 sent = 0;
            public uint64 total_bytes = 0;
            public uint64 added_files = 0;
            public uint64 added_bytes = 0;
            public int total_items = 0;
            public int done = 0;
            public int64 last_report = 0;

            public void report (string item) {
                int64 t = get_monotonic_time ();
                if (t - last_report <= 100000) return;
                last_report = t;
                double f = to_send > 0 ? (double) sent / to_send : (double) done / int.max (total_items, 1);
                progress (f.clamp (0, 1), "uploading", item);
            }
        }

        private static int64 mtime_of (Posix.Stat st) {
            return (int64) st.st_mtim.tv_sec * 1000000000 + (int64) st.st_mtim.tv_nsec;
        }

        private Entry? reusable (Run run, string rel, Posix.Stat st) {
            if (run.previous == null) return null;
            var old = run.previous.lookup (rel);
            if (old == null || old.kind != EntryKind.FILE || old.size != (uint64) st.st_size ||
                old.mtime_ns != mtime_of (st) || old.mode != (uint32) (st.st_mode & 07777) || old.digest.length <= 2) return null;
            if (!run.objects.contains (object_name (old.digest))) return null;
            return old;
        }

        private static Gee.ArrayList<string> sorted_names (string dir) throws FileError {
            var handle = Dir.open (dir);
            var names = new Gee.ArrayList<string> ();
            string? n;
            while ((n = handle.read_name ()) != null) names.add (n);
            names.sort ((a, b) => strcmp (a, b));
            return names;
        }

        private static void check_cancel (Cancellable? cancellable) throws Error {
            if (cancellable != null && cancellable.is_cancelled ()) throw new BackupError.CANCELLED (_("The backup was cancelled"));
        }

        private void measure (SourceRoot source, string dir, string rel, Run run) throws Error {
            Gee.ArrayList<string> names;
            try {
                names = sorted_names (dir);
            } catch (FileError e) {
                return;
            }
            foreach (string name in names) {
                check_cancel (run.cancellable);
                string child_rel = rel == "" ? name : rel + "/" + name;
                if (source.exclusions != null && source.exclusions.excluded (child_rel)) continue;
                string full = Path.build_filename (dir, name);
                Posix.Stat st;
                if (Posix.lstat (full, out st) != 0) continue;
                run.total_items++;
                if (Posix.S_ISDIR (st.st_mode)) measure (source, full, child_rel, run);
                else if (Posix.S_ISREG (st.st_mode) && reusable (run, source.prefix + "/" + child_rel, st) == null) run.to_send += (uint64) st.st_size;
            }
        }

        private void walk (SourceRoot source, string dir, string rel, Run run) throws Error {
            Gee.ArrayList<string> names;
            try {
                names = sorted_names (dir);
            } catch (FileError e) {
                run.warnings.add (_("Skipped %s: %s").printf (rel, e.message));
                return;
            }
            foreach (string name in names) {
                check_cancel (run.cancellable);
                string child_rel = rel == "" ? name : rel + "/" + name;
                if (source.exclusions != null && source.exclusions.excluded (child_rel)) continue;
                string full = Path.build_filename (dir, name);
                Posix.Stat st;
                if (Posix.lstat (full, out st) != 0) {
                    run.warnings.add (_("Skipped %s: %s").printf (child_rel, strerror (errno)));
                    continue;
                }
                string item_rel = source.prefix + "/" + child_rel;
                if (Posix.S_ISDIR (st.st_mode)) {
                    record (run, full, item_rel, EntryKind.DIRECTORY, st, "", "");
                    walk (source, full, child_rel, run);
                } else if (Posix.S_ISREG (st.st_mode)) {
                    wait_gate (run, item_rel);
                    var old = reusable (run, item_rel, st);
                    string digest = old != null ? old.digest : "";
                    if (old == null) {
                        try {
                            digest = send_file (run, full, item_rel);
                        } catch (BackupError.CANCELLED e) {
                            throw e;
                        } catch (BackupError.UNAVAILABLE e) {
                            throw e;
                        } catch (BackupError.NO_SPACE e) {
                            throw e;
                        } catch (Error e) {
                            run.warnings.add (_("Skipped %s: %s").printf (item_rel, e.message));
                            continue;
                        }
                    }
                    record (run, full, item_rel, EntryKind.FILE, st, digest, "");
                } else if (Posix.S_ISLNK (st.st_mode)) {
                    string target;
                    try {
                        target = FileUtils.read_link (full);
                    } catch (FileError e) {
                        run.warnings.add (_("Skipped %s: %s").printf (child_rel, e.message));
                        continue;
                    }
                    record (run, full, item_rel, EntryKind.SYMLINK, st, "", target);
                }
            }
        }

        private void wait_gate (Run run, string item) throws Error {
            var gate = run.plan.gate;
            if (gate == null || !gate.is_paused) return;
            run.progress (run.to_send > 0 ? ((double) run.sent / run.to_send).clamp (0, 1) : 0, "paused", item);
            gate.wait (run.cancellable);
            check_cancel (run.cancellable);
        }

        private void record (Run run, string full, string rel, EntryKind kind, Posix.Stat st, string digest, string target) {
            if (kind != EntryKind.SYMLINK) {
                var x = XattrSet.read (full);
                if (x != null) run.attrs.add (rel, x);
            }
            uint64 size = kind == EntryKind.FILE ? (uint64) st.st_size : 0;
            run.index.add_fields (rel, kind, (uint32) (st.st_mode & 07777), size, mtime_of (st), digest, target);
            if (kind == EntryKind.FILE) run.total_bytes += size;
            run.done++;
            run.report (rel);
        }

        private string send_file (Run run, string full, string rel) throws Error {
            int input = Posix.open (full, Posix.O_RDONLY | Posix.O_NOFOLLOW | Posix.O_CLOEXEC);
            if (input < 0) throw new BackupError.FAILED ("%s", strerror (errno));
            string tmp = scratch ("object");
            int output = Posix.open (tmp, Posix.O_WRONLY | Posix.O_CREAT | Posix.O_EXCL | Posix.O_CLOEXEC, 0600);
            if (output < 0) {
                int err = errno;
                Posix.close (input);
                throw new BackupError.FAILED (_("Cannot write %s: %s"), tmp, strerror (err));
            }
            var sum = new Checksum (ChecksumType.SHA256);
            uint64 size = 0;
            try {
                if (sealing != null) {
                    sealing.seal_fd (input, output, sum, run.cancellable, (n) => size += n);
                } else {
                    uint8[] buffer = new uint8[1024 * 1024];
                    while (true) {
                        check_cancel (run.cancellable);
                        ssize_t n = Posix.read (input, buffer, buffer.length);
                        if (n < 0 && errno == Posix.EINTR) continue;
                        if (n < 0) throw new BackupError.FAILED ("%s", strerror (errno));
                        if (n == 0) break;
                        sum.update (buffer, (size_t) n);
                        size += (uint64) n;
                        if (Posix.write (output, buffer, (size_t) n) != n) throw new BackupError.FAILED (_("Cannot write %s: %s"), tmp, strerror (errno));
                    }
                }
            } catch (Error e) {
                Posix.close (input);
                Posix.close (output);
                FileUtils.unlink (tmp);
                throw e;
            }
            Posix.close (input);
            Posix.close (output);
            string digest = sum.get_string ();
            string name = object_name (digest);
            try {
                if (!run.objects.contains (name)) {
                    uint64 before = run.sent;
                    upload ("objects/" + name, tmp, run.cancellable, (bytes) => {
                        run.sent += bytes;
                        run.report (rel);
                    });
                    run.sent = before + size;
                    run.objects[name] = size;
                    run.added_files++;
                    run.added_bytes += size;
                } else {
                    run.sent += size;
                }
            } finally {
                FileUtils.unlink (tmp);
            }
            return digest;
        }

        public SnapshotInfo create_snapshot (BackupPlan plan, Gee.List<SourceRoot> roots,
                                             Cancellable? cancellable, ProgressFunc progress) throws Error {
            progress (0, "scanning", "");
            var run = new Run ();
            run.plan = plan;
            run.cancellable = cancellable;
            run.progress = progress;
            run.objects = remote_objects (cancellable);
            mutex.lock ();
            objects = run.objects;
            mutex.unlock ();
            var existing = list_snapshots ();
            SnapshotInfo? previous = existing.size > 0 ? existing[existing.size - 1] : null;
            if (previous != null) {
                try {
                    run.previous = index_for (previous.id);
                } catch (Error e) {
                    run.previous = null;
                }
            }
            var now = new DateTime.now_utc ();
            string id = snapshot_id_for (now);
            int suffix = 2;
            foreach (var s in existing) if (s.id == id) id = "%s-%d".printf (snapshot_id_for (now), suffix++);
            foreach (string note in plan.notes) run.warnings.add (note);

            var sources = new Gee.ArrayList<SourceRoot> ();
            string[] used = {};
            foreach (var source in roots) {
                Posix.Stat st;
                if (Posix.lstat (source.path, out st) != 0 || !Posix.S_ISDIR (st.st_mode)) {
                    run.warnings.add (_("Skipped %s: the folder is missing").printf (source.prefix));
                    continue;
                }
                sources.add (source);
                if (!(source.prefix in used) && !source.prefix.contains ("/")) used += source.prefix;
                run.total_items++;
                measure (source, source.path, "", run);
            }

            uint64 used_space, total_space;
            try {
                store.space (out used_space, out total_space);
            } catch (Error e) {
                used_space = 0;
                total_space = 0;
            }
            if (total_space > 0) {
                uint64 free = total_space > used_space ? total_space - used_space : 0;
                if (run.to_send > free) {
                    throw new BackupError.NO_SPACE (_("There is not enough space for this backup: %s needed, %s free"),
                                                   format_bytes (run.to_send), format_bytes (free));
                }
            }

            string partial = Path.build_filename (cache, "snapshots", ".partial-" + id);
            run.index = new IndexWriter (partial + ".index");
            try {
                foreach (var source in sources) {
                    Posix.Stat st;
                    Posix.lstat (source.path, out st);
                    record (run, source.path, source.prefix, EntryKind.DIRECTORY, st, "", "");
                    walk (source, source.path, "", run);
                }
            } catch (Error e) {
                run.index.abandon ();
                throw e;
            }

            progress (1, "finishing", "");
            run.index.finish ();
            uint8[] index_data;
            FileUtils.get_data (partial + ".index", out index_data);
            put_small ("snapshots/%s.index".printf (id), index_data);
            if (run.attrs.size > 0) {
                run.attrs.save (partial + ".xattrs");
                uint8[] attr_data;
                FileUtils.get_data (partial + ".xattrs", out attr_data);
                put_small ("snapshots/%s.xattrs".printf (id), attr_data);
                FileUtils.rename (partial + ".xattrs", Path.build_filename (cache, "snapshots", id + ".xattrs"));
            }
            FileUtils.rename (partial + ".index", Path.build_filename (cache, "snapshots", id + ".index"));

            var info = new SnapshotInfo ();
            info.id = id;
            info.created = now.to_unix ();
            info.label = plan.label;
            info.host = plan.host;
            info.files = run.index.count;
            info.bytes = run.total_bytes;
            info.added_files = run.added_files;
            info.added_bytes = run.added_bytes;
            info.providers = used;
            string[] w = {};
            foreach (string s in run.warnings) {
                if (w.length >= 200) break;
                w += s;
            }
            info.warnings = w;
            uint8[] manifest = manifest_json (info);
            put_small ("snapshots/%s.manifest".printf (id), manifest);
            FileUtils.set_data (Path.build_filename (cache, "snapshots", id + ".manifest"), manifest);
            mutex.lock ();
            manifests[id] = info;
            mutex.unlock ();

            var doomed = Retention.doomed (list_snapshots (), plan.retention, plan.keep_last,
                                           new DateTime.now_utc ().to_unix (), new TimeZone.local ());
            if (doomed.size > 0) {
                progress (1, "pruning", "");
                foreach (string d in doomed) if (d != id) forget (d);
                collect_objects ();
            }
            return info;
        }

        private void forget (string snapshot) throws Error {
            store.remove (key ("snapshots/%s.manifest".printf (snapshot)));
            store.remove (key ("snapshots/%s.index".printf (snapshot)));
            store.remove (key ("snapshots/%s.xattrs".printf (snapshot)));
            foreach (string ext in new string[] { ".manifest", ".index", ".xattrs" }) {
                FileUtils.unlink (Path.build_filename (cache, "snapshots", snapshot + ext));
            }
            mutex.lock ();
            manifests.remove (snapshot);
            indexes.remove (snapshot);
            touched.remove (snapshot);
            mutex.unlock ();
        }

        private void collect_objects () throws Error {
            var keep = new Gee.HashSet<string> ();
            foreach (var s in list_snapshots ()) {
                var index = index_for (s.id);
                int n = index.size;
                for (int i = 0; i < n; i++) {
                    string d = index.digest_at (i);
                    if (d.length > 2) keep.add (object_name (d));
                }
            }
            var present = remote_objects (null);
            present.foreach ((name, size) => {
                if (keep.contains (name)) return;
                try {
                    store.remove (key ("objects/" + name));
                } catch (Error e) {
                    warning ("Backups: %s", e.message);
                }
            });
            mutex.lock ();
            objects = null;
            mutex.unlock ();
        }

        public void delete_snapshot (string snapshot) throws Error {
            if (read_manifest (snapshot) == null) throw new BackupError.NOT_FOUND (_("The backup %s does not exist"), snapshot);
            forget (snapshot);
            collect_objects ();
        }

        public void prune (int keep_last) throws Error {
            if (keep_last <= 0) return;
            var doomed = Retention.doomed (list_snapshots (), RetentionMode.KEEP_LAST, keep_last, new DateTime.now_utc ().to_unix (), new TimeZone.utc ());
            foreach (string d in doomed) forget (d);
            if (doomed.size > 0) collect_objects ();
        }

        private string? previous_of (string snapshot) throws Error {
            var all = list_snapshots ();
            for (int i = 0; i < all.size; i++) {
                if (all[i].id == snapshot) return i > 0 ? all[i - 1].id : null;
            }
            throw new BackupError.NOT_FOUND (_("The backup %s does not exist"), snapshot);
        }

        private Gee.HashSet<string> changed_dirs (string snapshot, SnapshotIndex current, SnapshotIndex? before) {
            mutex.lock ();
            var cached = touched[snapshot];
            mutex.unlock ();
            if (cached != null) return cached;
            var dirs = new Gee.HashSet<string> ();
            if (before != null) {
                foreach (var e in current) {
                    var old = before.lookup (e.path);
                    if (old == null || !old.same_content (e)) mark_parents (dirs, e.path);
                }
                foreach (var e in before) {
                    if (current.lookup (e.path) == null) mark_parents (dirs, e.path);
                }
            }
            mutex.lock ();
            touched[snapshot] = dirs;
            mutex.unlock ();
            return dirs;
        }

        private static void mark_parents (Gee.HashSet<string> dirs, string path) {
            string p = SnapshotIndex.parent_of (path);
            while (p != "" && dirs.add (p)) p = SnapshotIndex.parent_of (p);
        }

        public Gee.List<Entry> list_directory (string snapshot, string path) throws Error {
            var current = index_for (snapshot);
            if (!current.has_dir (path)) throw new BackupError.NOT_FOUND (_("The folder %s is not in this backup"), path);
            string? prev_id = previous_of (snapshot);
            SnapshotIndex? before = prev_id != null ? index_for (prev_id) : null;
            var dirs = changed_dirs (snapshot, current, before);
            var result = new Gee.ArrayList<Entry> ();
            foreach (var e in current.list (path)) {
                var copy = e.copy ();
                copy.origin = snapshot;
                if (before != null) {
                    var old = before.lookup (e.path);
                    if (old == null) copy.change = Change.ADDED;
                    else if (!old.same_content (e)) copy.change = Change.CHANGED;
                    else if (e.kind == EntryKind.DIRECTORY && dirs.contains (e.path)) copy.change = Change.CONTAINS;
                }
                result.add (copy);
            }
            if (before != null) {
                foreach (var e in before.list (path)) {
                    if (current.lookup (e.path) != null) continue;
                    var gone = e.copy ();
                    gone.change = Change.REMOVED;
                    gone.origin = prev_id;
                    result.add (gone);
                }
            }
            return result;
        }

        public Entry? lookup (string snapshot, string path) throws Error {
            var e = index_for (snapshot).lookup (path);
            if (e == null) return null;
            var copy = e.copy ();
            copy.origin = snapshot;
            return copy;
        }

        public string materialize (string snapshot, string path, Cancellable? cancellable) throws Error {
            if (lookup (snapshot, path) == null) throw new BackupError.NOT_FOUND (_("%s is not in this backup"), path);
            string target = Path.build_filename (cache, "materialized", snapshot, path);
            if (FileUtils.test (target, FileTest.EXISTS) || FileUtils.test (target, FileTest.IS_SYMLINK)) return target;
            DirUtils.create_with_parents (Path.get_dirname (target), 0700);
            restore (snapshot, path, target, false, cancellable);
            return target;
        }

        public void restore (string snapshot, string path, string target, bool merge, Cancellable? cancellable) throws Error {
            var index = index_for (snapshot);
            var top = index.lookup (path);
            if (top == null) throw new BackupError.NOT_FOUND (_("%s is not in this backup"), path);
            var attrs = attrs_for (snapshot);
            if (top.kind != EntryKind.DIRECTORY) {
                restore_entry (top, target, merge, attrs, cancellable);
                return;
            }
            Posix.Stat st;
            bool exists = Posix.lstat (target, out st) == 0;
            if (exists && !(merge && Posix.S_ISDIR (st.st_mode))) throw new BackupError.FAILED (_("%s already exists"), target);
            if (!exists && DirUtils.create_with_parents (target, 0700) != 0) {
                throw new BackupError.FAILED (_("Cannot create %s: %s"), target, strerror (errno));
            }
            string head = path + "/";
            var dirs = new Gee.ArrayList<Entry> ();
            var dir_targets = new Gee.ArrayList<string> ();
            dirs.add (top);
            dir_targets.add (target);
            string[] failures = {};
            foreach (var e in index) {
                if (!e.path.has_prefix (head)) continue;
                check_cancel (cancellable);
                string dest = Path.build_filename (target, e.path.substring (head.length));
                if (e.kind == EntryKind.DIRECTORY) {
                    if (Posix.mkdir (dest, 0700) != 0 && errno != Posix.EEXIST) {
                        failures += e.path;
                        continue;
                    }
                    dirs.add (e);
                    dir_targets.add (dest);
                    continue;
                }
                try {
                    restore_entry (e, dest, merge, attrs, cancellable);
                } catch (BackupError.CANCELLED err) {
                    throw err;
                } catch (BackupError.UNAVAILABLE err) {
                    throw err;
                } catch (Error err) {
                    failures += e.path;
                }
            }
            for (int i = dirs.size - 1; i >= 0; i--) {
                Posix.chmod (dir_targets[i], (Posix.mode_t) dirs[i].mode);
                var a = attrs.lookup (dirs[i].path);
                if (a != null) XattrSet.apply (dir_targets[i], a);
                set_mtime (dir_targets[i], dirs[i].mtime_ns);
            }
            if (failures.length > 0) {
                throw new BackupError.FAILED (ngettext ("%d item could not be restored", "%d items could not be restored",
                                                        failures.length), failures.length);
            }
        }

        private static Posix.timespec mtime_spec (int64 ns) {
            Posix.timespec t = Posix.timespec ();
            t.tv_sec = (time_t) (ns / 1000000000);
            t.tv_nsec = (long) (ns % 1000000000);
            return t;
        }

        private static void set_mtime (string path, int64 ns) {
            Posix.timespec[] times = { mtime_spec (ns), mtime_spec (ns) };
            Posix.utimensat (Posix.AT_FDCWD, path, times, Posix.AT_SYMLINK_NOFOLLOW);
        }

        private void fetch_content (Entry e, string dest, Cancellable? cancellable) throws Error {
            string blob = scratch ("fetch");
            try {
                download ("objects/" + object_name (e.digest), blob, cancellable);
                var sum = new Checksum (ChecksumType.SHA256);
                if (sealing != null) {
                    sealing.open_file (blob, dest, sum, cancellable);
                } else {
                    uint8[] data;
                    FileUtils.get_data (blob, out data);
                    sum.update (data, data.length);
                    FileUtils.rename (blob, dest);
                }
                if (sum.get_string () != e.digest) {
                    FileUtils.unlink (dest);
                    throw new BackupError.CORRUPT (_("%s is damaged in the backup"), e.path);
                }
            } finally {
                FileUtils.unlink (blob);
            }
        }

        private void restore_entry (Entry e, string dest, bool merge, XattrSet attrs, Cancellable? cancellable) throws Error {
            Posix.Stat st;
            bool exists = Posix.lstat (dest, out st) == 0;
            if (exists && !merge) throw new BackupError.FAILED (_("%s already exists"), dest);
            if (exists && Posix.S_ISDIR (st.st_mode)) throw new BackupError.FAILED (_("%s is a folder"), dest);
            string tmp = Path.build_filename (Path.get_dirname (dest), ".%s.restoring".printf (Path.get_basename (dest)));
            FileUtils.unlink (tmp);
            if (e.kind == EntryKind.SYMLINK) {
                if (Posix.symlink (e.target, tmp) != 0) throw new BackupError.FAILED (_("Cannot restore %s: %s"), e.path, strerror (errno));
            } else {
                if (e.size == 0 && e.digest == Checksum.compute_for_data (ChecksumType.SHA256, new uint8[0])) {
                    FileUtils.set_data (tmp, new uint8[0]);
                } else {
                    fetch_content (e, tmp, cancellable);
                }
                Posix.chmod (tmp, (Posix.mode_t) e.mode);
                var a = attrs.lookup (e.path);
                if (a != null) XattrSet.apply (tmp, a);
                set_mtime (tmp, e.mtime_ns);
            }
            if (FileUtils.rename (tmp, dest) != 0) {
                FileUtils.unlink (tmp);
                throw new BackupError.FAILED (_("Cannot restore %s: %s"), e.path, strerror (errno));
            }
        }

        public VerifyResult verify (string snapshot, Cancellable? cancellable, ProgressFunc? progress) throws Error {
            var index = index_for (snapshot);
            var present = remote_objects (cancellable);
            var result = new VerifyResult ();
            string[] damaged = {};
            string[] missing = {};
            var checked_names = new HashTable<string, bool> (str_hash, str_equal);
            uint64 total = 0;
            foreach (var e in index) if (e.kind == EntryKind.FILE) total += e.size;
            uint64 seen = 0;
            foreach (var e in index) {
                check_cancel (cancellable);
                if (e.kind != EntryKind.FILE || e.digest.length <= 2) continue;
                string name = object_name (e.digest);
                result.checked++;
                if (checked_names.contains (name)) {
                    if (!checked_names[name]) damaged += e.path;
                    continue;
                }
                if (!present.contains (name)) {
                    missing += e.path;
                    checked_names[name] = false;
                    continue;
                }
                bool ok = true;
                try {
                    string dest = scratch ("verify");
                    try {
                        fetch_content (e, dest, cancellable);
                    } finally {
                        FileUtils.unlink (dest);
                    }
                } catch (BackupError.CORRUPT err) {
                    ok = false;
                    damaged += e.path;
                    try {
                        store.remove (key ("objects/" + name));
                    } catch (Error ignored) {
                    }
                }
                checked_names[name] = ok;
                seen += e.size;
                if (progress != null) progress (total > 0 ? (double) seen / total : 1, "verifying", e.path);
            }
            result.damaged = damaged;
            result.missing = missing;
            return result;
        }

        public RepoStats stats () throws Error {
            var s = new RepoStats ();
            uint64 used_space, total_space;
            store.space (out used_space, out total_space);
            s.capacity = total_space;
            s.free = total_space > used_space ? total_space - used_space : 0;
            uint64 used = 0;
            Gee.List<RemoteObject>? found = null;
            retrying (() => { found = store.list (prefix, null); }, null);
            foreach (var o in found) used += o.size;
            s.used = used;
            s.links = true;
            s.store = "remote";
            s.encrypted = sealing != null;
            return s;
        }
    }
}
