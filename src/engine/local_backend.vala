namespace Singularity.Backups {

    [CCode (cname = "flock", cheader_filename = "sys/file.h")]
    private extern int c_flock (int fd, int operation);

    private const int LOCK_EXCLUSIVE = 2;
    private const int LOCK_NONBLOCK = 4;
    private const int LOCK_RELEASE = 8;

    public class LocalBackend : Object, Backend {
        public const int FORMAT = 1;
        private const size_t BUFFER = 1024 * 1024;
        private const uint64 SPACE_MARGIN = 64 * 1024 * 1024;

        private string root = "";
        private string snapshots_dir = "";
        private string partial_dir = "";
        private string objects_dir = "";
        private bool links = true;
        private string store = "tree";
        private int lock_fd = -1;
        private HashTable<string, SnapshotIndex> indexes = new HashTable<string, SnapshotIndex> (str_hash, str_equal);
        private Gee.ArrayList<string> index_order = new Gee.ArrayList<string> ();
        private HashTable<string, SnapshotInfo> manifests = new HashTable<string, SnapshotInfo> (str_hash, str_equal);
        private HashTable<string, Gee.HashSet<string>> touched = new HashTable<string, Gee.HashSet<string>> (str_hash, str_equal);
        private Mutex mutex = Mutex ();

        public string id { owned get { return "local"; } }
        public string location { owned get { return root; } }
        public bool supports_dedup { get { return links || objects_mode; } }
        public string requested_store { get; set; default = "auto"; }
        public string store_mode { get { return store; } }

        private bool objects_mode {
            get { return store == "objects"; }
        }

        private class WorkItem {
            public string source;
            public string rel;
            public EntryKind kind;
            public uint32 mode;
            public uint64 size;
            public int64 mtime_ns;
            public string target = "";
            public string link_from = "";
            public string digest = "";
            public bool reuse = false;
            public Variant? xattrs = null;
        }

        public void open (string location) throws Error {
            root = location;
            snapshots_dir = Path.build_filename (root, "snapshots");
            partial_dir = Path.build_filename (snapshots_dir, ".partial");
            objects_dir = Path.build_filename (root, "objects");
            if (DirUtils.create_with_parents (partial_dir, 0700) != 0 || DirUtils.create_with_parents (objects_dir, 0700) != 0) {
                throw new BackupError.UNAVAILABLE (_("Cannot write to %s"), root);
            }
            string info = Path.build_filename (root, "repository.json");
            if (FileUtils.test (info, FileTest.EXISTS)) {
                var parser = new Json.Parser ();
                parser.load_from_file (info);
                var o = parser.get_root ().get_object ();
                if (o.get_int_member_with_default ("format", 1) > FORMAT) {
                    throw new BackupError.UNSUPPORTED (_("These backups were made by a newer version of Backups"));
                }
                links = o.get_boolean_member_with_default ("links", true);
                store = o.get_string_member_with_default ("store", "tree");
                if (store != "objects") store = "tree";
            } else {
                links = probe_links ();
                store = requested_store == "objects" || !links ? "objects" : "tree";
                var b = new Json.Builder ();
                b.begin_object ();
                b.set_member_name ("format");
                b.add_int_value (FORMAT);
                b.set_member_name ("engine");
                b.add_string_value ("singularity-backups");
                b.set_member_name ("created");
                b.add_int_value (new DateTime.now_utc ().to_unix ());
                b.set_member_name ("links");
                b.add_boolean_value (links);
                b.set_member_name ("store");
                b.add_string_value (store);
                b.set_member_name ("uuid");
                b.add_string_value (Uuid.string_random ());
                b.end_object ();
                write_json (info, b.get_root ());
            }
        }

        private bool probe_links () {
            string a = Path.build_filename (root, ".probe-%s".printf (Uuid.string_random ()));
            string b = a + ".link";
            bool ok = false;
            try {
                FileUtils.set_contents (a, "probe");
                ok = Posix.link (a, b) == 0;
            } catch (Error e) {
            }
            FileUtils.unlink (b);
            FileUtils.unlink (a);
            return ok;
        }

        private static void write_json (string file, Json.Node node) throws Error {
            var g = new Json.Generator ();
            g.pretty = true;
            g.root = node;
            string tmp = file + ".part";
            FileUtils.set_contents (tmp, g.to_data (null));
            if (FileUtils.rename (tmp, file) != 0) throw new BackupError.FAILED (_("Cannot write %s"), file);
        }

        private void acquire () throws Error {
            string file = Path.build_filename (root, ".lock");
            lock_fd = Posix.open (file, Posix.O_RDWR | Posix.O_CREAT | Posix.O_CLOEXEC, 0600);
            if (lock_fd < 0) throw new BackupError.UNAVAILABLE (_("Cannot write to %s"), root);
            if (c_flock (lock_fd, LOCK_EXCLUSIVE | LOCK_NONBLOCK) != 0) {
                if (errno != Posix.EWOULDBLOCK && errno != Posix.EAGAIN) return;
                Posix.close (lock_fd);
                lock_fd = -1;
                throw new BackupError.BUSY (_("Another backup is using this disk"));
            }
        }

        private void release () {
            if (lock_fd < 0) return;
            c_flock (lock_fd, LOCK_RELEASE);
            Posix.close (lock_fd);
            lock_fd = -1;
        }

        private string snapshot_path (string snapshot) {
            return Path.build_filename (snapshots_dir, snapshot);
        }

        private string object_path (string digest) {
            return Path.build_filename (objects_dir, digest.substring (0, 2), digest);
        }

        private string content_path (string snapshot, Entry e) {
            if (objects_mode && e.kind == EntryKind.FILE && e.digest.length > 2) return object_path (e.digest);
            return tree_path (snapshot, e.path);
        }

        private string tree_path (string snapshot, string path) {
            return path == "" ? Path.build_filename (snapshot_path (snapshot), "tree")
                              : Path.build_filename (snapshot_path (snapshot), "tree", path);
        }

        public Gee.List<SnapshotInfo> list_snapshots () throws Error {
            var list = new Gee.ArrayList<SnapshotInfo> ();
            Dir dir;
            try {
                dir = Dir.open (snapshots_dir);
            } catch (FileError e) {
                throw new BackupError.UNAVAILABLE (_("The backups at %s cannot be read"), root);
            }
            string? name;
            while ((name = dir.read_name ()) != null) {
                if (name.has_prefix (".")) continue;
                var info = read_manifest (name);
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
            string file = Path.build_filename (snapshot_path (snapshot), "manifest.json");
            var parser = new Json.Parser ();
            try {
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
            info.providers = string_array (o, "providers");
            info.warnings = string_array (o, "warnings");
            mutex.lock ();
            manifests[snapshot] = info;
            mutex.unlock ();
            return info;
        }

        private static string[] string_array (Json.Object o, string member) {
            string[] result = {};
            if (!o.has_member (member)) return result;
            foreach (var n in o.get_array_member (member).get_elements ()) result += n.get_string ();
            return result;
        }

        private void write_manifest (string dir, SnapshotInfo info) throws Error {
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
            write_json (Path.build_filename (dir, "manifest.json"), b.get_root ());
        }

        public SnapshotIndex index_for (string snapshot) throws Error {
            mutex.lock ();
            var cached = indexes[snapshot];
            mutex.unlock ();
            if (cached != null) return cached;
            string file = Path.build_filename (snapshot_path (snapshot), "index");
            if (!FileUtils.test (file, FileTest.EXISTS)) throw new BackupError.NOT_FOUND (_("The backup %s does not exist"), snapshot);
            var index = SnapshotIndex.load (file);
            mutex.lock ();
            indexes[snapshot] = index;
            index_order.add (snapshot);
            while (index_order.size > 6) {
                indexes.remove (index_order[0]);
                touched.remove (index_order[0]);
                index_order.remove_at (0);
            }
            mutex.unlock ();
            return index;
        }

        private static int64 mtime_of (Posix.Stat st) {
            return (int64) st.st_mtim.tv_sec * 1000000000 + (int64) st.st_mtim.tv_nsec;
        }

        private class Run {
            public BackupPlan plan;
            public Cancellable? cancellable;
            public unowned ProgressFunc progress;
            public SnapshotIndex? previous_index = null;
            public string previous_id = "";
            public Gee.HashSet<string> damaged = new Gee.HashSet<string> ();
            public Gee.ArrayList<string> warnings = new Gee.ArrayList<string> ();
            public HashTable<string, string> anchors = new HashTable<string, string> (str_hash, str_equal);
            public IndexWriter index;
            public XattrSet attrs = new XattrSet ();
            public string tree = "";
            public string incoming = "";
            public uint8[] buffer = new uint8[BUFFER];
            public uint64 to_copy = 0;
            public uint64 total_bytes = 0;
            public uint64 copied = 0;
            public uint64 streamed = 0;
            public uint64 added_files = 0;
            public uint64 anchor_copies = 0;
            public int total_items = 0;
            public int done = 0;
            public int64 last_report = 0;

            public void report (string item) {
                int64 t = get_monotonic_time ();
                if (t - last_report <= 100000) return;
                last_report = t;
                uint64 moved = copied > streamed ? copied : streamed;
                double f = to_copy > 0 ? (double) moved / to_copy : (double) done / int.max (total_items, 1);
                progress (f.clamp (0, 1), "copying", item);
            }
        }

        public uint64 last_anchor_copies { get; private set; default = 0; }
        public uint link_limit { get; set; default = 0; }

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

        private Entry? reusable (Run run, string rel, Posix.Stat st) {
            if (!(links || objects_mode) || run.previous_index == null || run.damaged.contains (rel)) return null;
            var old = run.previous_index.lookup (rel);
            if (old == null || old.kind != EntryKind.FILE || old.size != (uint64) st.st_size ||
                old.mtime_ns != mtime_of (st) || old.mode != (uint32) (st.st_mode & 07777)) return null;
            if (objects_mode && old.digest.length <= 2) return null;
            return old;
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
                if (Posix.S_ISDIR (st.st_mode)) {
                    run.total_items++;
                    measure (source, full, child_rel, run);
                } else if (Posix.S_ISREG (st.st_mode)) {
                    run.total_items++;
                    if (reusable (run, source.prefix + "/" + child_rel, st) == null) run.to_copy += (uint64) st.st_size;
                } else if (Posix.S_ISLNK (st.st_mode)) {
                    run.total_items++;
                }
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
                var item = new WorkItem ();
                item.source = full;
                item.rel = source.prefix + "/" + child_rel;
                item.mode = (uint32) (st.st_mode & 07777);
                item.mtime_ns = mtime_of (st);
                if (Posix.S_ISDIR (st.st_mode) || Posix.S_ISREG (st.st_mode)) item.xattrs = XattrSet.read (full);
                if (Posix.S_ISDIR (st.st_mode)) {
                    item.kind = EntryKind.DIRECTORY;
                    process (run, item);
                    walk (source, full, child_rel, run);
                    finish_dir (run, item);
                } else if (Posix.S_ISREG (st.st_mode)) {
                    item.kind = EntryKind.FILE;
                    item.size = (uint64) st.st_size;
                    var old = reusable (run, item.rel, st);
                    if (old != null) {
                        if (!objects_mode) item.link_from = tree_path (run.previous_id, item.rel);
                        item.reuse = true;
                        item.digest = old.digest;
                    }
                    process (run, item);
                } else if (Posix.S_ISLNK (st.st_mode)) {
                    item.kind = EntryKind.SYMLINK;
                    try {
                        item.target = FileUtils.read_link (full);
                    } catch (FileError e) {
                        run.warnings.add (_("Skipped %s: %s").printf (child_rel, e.message));
                        continue;
                    }
                    process (run, item);
                }
            }
        }

        private void finish_dir (Run run, WorkItem item) {
            if (objects_mode) return;
            string dest = Path.build_filename (run.tree, item.rel);
            Posix.chmod (dest, (Posix.mode_t) (item.mode | 0700));
            set_mtime (dest, item.mtime_ns);
        }

        private void record (Run run, WorkItem item) {
            if (item.xattrs != null) run.attrs.add (item.rel, item.xattrs);
            run.index.add_fields (item.rel, item.kind, item.mode, item.size, item.mtime_ns, item.digest, item.target);
            if (item.kind == EntryKind.FILE) run.total_bytes += item.size;
            run.report (item.rel);
        }

        private void process (Run run, WorkItem item) throws Error {
            check_cancel (run.cancellable);
            var gate = run.plan.gate;
            if (gate != null && gate.is_paused) {
                uint64 moved = objects_mode ? run.streamed : run.copied;
                run.progress (run.to_copy > 0 ? ((double) moved / run.to_copy).clamp (0, 1) : 0, "paused", item.rel);
                gate.wait (run.cancellable);
                check_cancel (run.cancellable);
            }
            run.done++;
            if (objects_mode) {
                if (item.kind == EntryKind.FILE) {
                    int r = store_object (item, run.incoming, run.buffer, run.cancellable, ref run.added_files, ref run.copied, (bytes) => {
                        run.streamed += bytes;
                        run.report (item.rel);
                    });
                    if (r == 1) throw new BackupError.CANCELLED (_("The backup was cancelled"));
                    if (r != 0) {
                        run.warnings.add (_("Skipped %s: %s").printf (item.rel, strerror (r)));
                        return;
                    }
                }
                record (run, item);
                return;
            }
            string dest = Path.build_filename (run.tree, item.rel);
            switch (item.kind) {
                case EntryKind.DIRECTORY:
                    if (Posix.mkdir (dest, 0700) != 0 && errno != Posix.EEXIST) {
                        throw new BackupError.FAILED (_("Cannot create %s: %s"), item.rel, strerror (errno));
                    }
                    break;
                case EntryKind.SYMLINK:
                    if (Posix.symlink (item.target, dest) != 0) {
                        run.warnings.add (_("Skipped %s: %s").printf (item.rel, strerror (errno)));
                        return;
                    }
                    break;
                default:
                    int link_error = item.link_from != "" ? make_link (item.link_from, dest) : -1;
                    bool linked = link_error == 0;
                    bool anchor = link_error == Posix.EMLINK && item.digest.length > 2;
                    if (anchor) linked = link_shared (run, item.digest, dest);
                    if (!linked) {
                        string digest;
                        int result = copy_in (item, dest, run.buffer, run.cancellable, out digest, (bytes) => {
                            if (anchor) return;
                            run.copied += bytes;
                            run.report (item.rel);
                        });
                        if (result == 1) throw new BackupError.CANCELLED (_("The backup was cancelled"));
                        if (result != 0) {
                            run.warnings.add (_("Skipped %s: %s").printf (item.rel, strerror (result)));
                            return;
                        }
                        if (anchor && digest == item.digest) {
                            adopt_anchor (run, digest, dest);
                            run.anchor_copies++;
                        } else {
                            item.digest = digest;
                            run.added_files++;
                            if (run.plan.deduplicate && links) deduplicate (run, dest, digest);
                        }
                    }
                    break;
            }
            record (run, item);
        }

        public SnapshotInfo create_snapshot (BackupPlan plan, Gee.List<SourceRoot> roots,
                                             Cancellable? cancellable, ProgressFunc progress) throws Error {
            acquire ();
            try {
                return run_backup (plan, roots, cancellable, progress);
            } finally {
                release ();
            }
        }

        private SnapshotInfo run_backup (BackupPlan plan, Gee.List<SourceRoot> roots,
                                         Cancellable? cancellable, ProgressFunc progress) throws Error {
            progress (0, "scanning", "");
            var run = new Run ();
            run.plan = plan;
            run.cancellable = cancellable;
            run.progress = progress;
            var existing = list_snapshots ();
            SnapshotInfo? previous = existing.size > 0 ? existing[existing.size - 1] : null;
            if (previous != null) {
                try {
                    run.previous_index = index_for (previous.id);
                    run.previous_id = previous.id;
                } catch (Error e) {
                    run.previous_index = null;
                }
            }

            var now = new DateTime.now_utc ();
            string id = snapshot_id_for (now);
            int suffix = 2;
            while (FileUtils.test (snapshot_path (id), FileTest.EXISTS)) id = "%s-%d".printf (snapshot_id_for (now), suffix++);

            string partial = Path.build_filename (partial_dir, id);
            if (FileUtils.test (partial, FileTest.EXISTS)) remove_tree (partial);
            clear_partial ();
            run.tree = Path.build_filename (partial, "tree");
            if (DirUtils.create_with_parents (objects_mode ? partial : run.tree, 0700) != 0) throw new BackupError.UNAVAILABLE (_("Cannot write to %s"), root);

            foreach (string note in plan.notes) run.warnings.add (note);
            if (previous != null) {
                string list;
                try {
                    FileUtils.get_contents (Path.build_filename (snapshot_path (previous.id), "damaged"), out list);
                    foreach (string line in list.split ("\n")) if (line != "") run.damaged.add (line);
                } catch (Error e) {
                }
            }

            var sources = new Gee.ArrayList<SourceRoot> ();
            var tops = new Gee.ArrayList<WorkItem> ();
            string[] used_providers = {};
            try {
                foreach (var source in roots) {
                    Posix.Stat st;
                    if (Posix.lstat (source.path, out st) != 0 || !Posix.S_ISDIR (st.st_mode)) {
                        run.warnings.add (_("Skipped %s: the folder is missing").printf (source.prefix));
                        continue;
                    }
                    var top = new WorkItem ();
                    top.source = source.path;
                    top.rel = source.prefix;
                    top.kind = EntryKind.DIRECTORY;
                    top.mode = (uint32) (st.st_mode & 07777);
                    top.mtime_ns = mtime_of (st);
                    sources.add (source);
                    tops.add (top);
                    used_providers += source.prefix;
                    run.total_items++;
                    measure (source, source.path, "", run);
                }
            } catch (Error e) {
                remove_tree (partial);
                throw e;
            }

            ensure_space (run.to_copy, previous != null ? previous.id : null, progress);

            run.index = new IndexWriter (Path.build_filename (partial, "index"));
            run.incoming = Path.build_filename (objects_dir, ".incoming");
            if (objects_mode) expire_resume_parts ();
            if (objects_mode) {
                remove_tree (run.incoming);
                DirUtils.create_with_parents (run.incoming, 0700);
            }
            try {
                for (int i = 0; i < sources.size; i++) {
                    var top = tops[i];
                    top.xattrs = XattrSet.read (top.source);
                    process (run, top);
                    walk (sources[i], sources[i].path, "", run);
                    finish_dir (run, top);
                }
            } catch (Error e) {
                run.index.abandon ();
                if (objects_mode) remove_tree (run.incoming);
                remove_tree (partial);
                throw e;
            }

            progress (1, "finishing", "");
            if (objects_mode) remove_tree (run.incoming);
            run.index.finish ();
            last_anchor_copies = run.anchor_copies;
            if (run.attrs.size > 0) run.attrs.save (Path.build_filename (partial, "xattrs"));
            var info = new SnapshotInfo ();
            info.id = id;
            info.created = now.to_unix ();
            info.label = plan.label;
            info.host = plan.host;
            info.files = run.index.count;
            info.bytes = run.total_bytes;
            info.added_files = run.added_files;
            info.added_bytes = run.copied;
            info.providers = used_providers;
            string[] w = {};
            foreach (string s in run.warnings) {
                if (w.length >= 200) break;
                w += s;
            }
            info.warnings = w;
            write_manifest (partial, info);

            if (FileUtils.rename (partial, snapshot_path (id)) != 0) {
                throw new BackupError.FAILED (_("Cannot finish the backup: %s"), strerror (errno));
            }
            update_latest (id);

            var doomed = Retention.doomed (list_snapshots (), plan.retention, plan.keep_last,
                                           new DateTime.now_utc ().to_unix (), new TimeZone.local ());
            if (doomed.size > 0) {
                progress (1, "pruning", "");
                foreach (string d in doomed) if (d != id) remove_snapshot (d);
                collect_objects ();
            }
            measure_usage ();
            return info;
        }
        private delegate void CopyStep (uint64 bytes);

        private int store_object (WorkItem item, string incoming, uint8[] buffer, Cancellable? cancellable,
                                  ref uint64 added_files, ref uint64 added_bytes, CopyStep report) {
            if (item.reuse && item.digest.length > 2 && FileUtils.test (object_path (item.digest), FileTest.EXISTS)) return 0;
            string tmp = resume_path (item) ?? Path.build_filename (incoming, Uuid.string_random ());
            string digest;
            int result = copy_in (item, tmp, buffer, cancellable, out digest, (bytes) => report (bytes));
            if (result != 0) return result;
            item.digest = digest;
            string bucket = Path.build_filename (objects_dir, digest.substring (0, 2));
            string target = Path.build_filename (bucket, digest);
            if (FileUtils.test (target, FileTest.EXISTS)) {
                FileUtils.unlink (tmp);
                return 0;
            }
            DirUtils.create (bucket, 0700);
            if (FileUtils.rename (tmp, target) != 0) {
                int err = errno;
                FileUtils.unlink (tmp);
                return err;
            }
            added_files++;
            added_bytes += item.size;
            return 0;
        }

        public const int64 RESUME_THRESHOLD = 64 * 1024 * 1024;
        private const int64 RESUME_MAX_AGE = 7 * TimeSpan.DAY;

        private string? resume_path (WorkItem item) {
            if ((int64) item.size < RESUME_THRESHOLD) return null;
            string dir = Path.build_filename (objects_dir, ".resume");
            if (DirUtils.create_with_parents (dir, 0700) != 0) return null;
            string key = "%s\n%s\n%s".printf (item.source, item.size.to_string (), item.mtime_ns.to_string ());
            return Path.build_filename (dir, Checksum.compute_for_string (ChecksumType.SHA256, key) + ".part");
        }

        private void expire_resume_parts () {
            string dir = Path.build_filename (objects_dir, ".resume");
            try {
                var d = Dir.open (dir);
                string? name;
                int64 now = get_real_time ();
                while ((name = d.read_name ()) != null) {
                    string path = Path.build_filename (dir, name);
                    Posix.Stat st;
                    if (Posix.stat (path, out st) == 0 && now - (int64) st.st_mtime * TimeSpan.SECOND > RESUME_MAX_AGE) FileUtils.unlink (path);
                }
            } catch (FileError e) {
            }
        }

        private int copy_in (WorkItem item, string dest, uint8[] buffer, Cancellable? cancellable,
                             out string digest, CopyStep step) {
            digest = "";
            bool resumable = dest.has_suffix (".part");
            int input = Posix.open (item.source, Posix.O_RDONLY | Posix.O_NOFOLLOW | Posix.O_CLOEXEC);
            if (input < 0) return errno;
            var sum = new Checksum (ChecksumType.SHA256);
            int output = -1;
            if (resumable && FileUtils.test (dest, FileTest.EXISTS)) {
                int done = Posix.open (dest, Posix.O_RDWR | Posix.O_CLOEXEC);
                int64 have = 0;
                if (done >= 0) {
                    while (true) {
                        ssize_t n = Posix.read (done, buffer, buffer.length);
                        if (n < 0 && errno == Posix.EINTR) continue;
                        if (n <= 0) break;
                        sum.update (buffer, (size_t) n);
                        have += n;
                    }
                }
                if (done >= 0 && have <= (int64) item.size && Posix.lseek (input, (Posix.off_t) have, Posix.SEEK_SET) == (Posix.off_t) have) {
                    output = done;
                    step ((uint64) have);
                } else {
                    if (done >= 0) Posix.close (done);
                    FileUtils.unlink (dest);
                    sum = new Checksum (ChecksumType.SHA256);
                    Posix.lseek (input, 0, Posix.SEEK_SET);
                }
            }
            if (output < 0) output = Posix.open (dest, Posix.O_WRONLY | Posix.O_CREAT | Posix.O_EXCL | Posix.O_CLOEXEC, 0600);
            if (output < 0) {
                int err = errno;
                Posix.close (input);
                return err;
            }
            int result = 0;
            while (true) {
                if (cancellable != null && cancellable.is_cancelled ()) {
                    result = 1;
                    break;
                }
                ssize_t n = Posix.read (input, buffer, buffer.length);
                if (n < 0) {
                    if (errno == Posix.EINTR) continue;
                    result = errno;
                    break;
                }
                if (n == 0) break;
                sum.update (buffer, (size_t) n);
                if (!write_all (output, buffer, (size_t) n)) {
                    result = errno;
                    break;
                }
                step ((uint64) n);
            }
            Posix.close (input);
            if (result == 0) {
                Posix.fchmod (output, (Posix.mode_t) ((item.mode | 0400) & 07555));
                Posix.timespec[] times = { mtime_spec (item.mtime_ns), mtime_spec (item.mtime_ns) };
                Posix.futimens (output, times);
            }
            Posix.close (output);
            if (result != 0) {
                if (!resumable) FileUtils.unlink (dest);
                return result;
            }
            digest = sum.get_string ();
            return 0;
        }

        private static bool write_all (int fd, uint8[] buffer, size_t length) {
            size_t offset = 0;
            while (offset < length) {
                ssize_t n = Posix.write (fd, (void*) ((uint8*) buffer + offset), length - offset);
                if (n < 0) {
                    if (errno == Posix.EINTR) continue;
                    return false;
                }
                offset += (size_t) n;
            }
            return true;
        }

        private static Posix.timespec mtime_spec (int64 ns) {
            Posix.timespec t = Posix.timespec ();
            t.tv_sec = (time_t) (ns / 1000000000);
            t.tv_nsec = (long) (ns % 1000000000);
            return t;
        }

        private static void set_mtime (string path, int64 ns) {
            Posix.timespec[] times = { mtime_spec (ns), mtime_spec (ns) };
            Posix.utimensat (Posix.AT_FDCWD, path, times, 0);
        }

        private int make_link (string from, string to) {
            if (link_limit > 0) {
                Posix.Stat st;
                if (Posix.lstat (from, out st) == 0 && st.st_nlink >= link_limit) return Posix.EMLINK;
            }
            return Posix.link (from, to) == 0 ? 0 : errno;
        }

        private bool link_shared (Run run, string digest, string dest) {
            string? anchor = run.anchors[digest];
            if (anchor != null && make_link (anchor, dest) == 0) return true;
            string object = object_path (digest);
            return anchor != object && FileUtils.test (object, FileTest.EXISTS) && make_link (object, dest) == 0;
        }

        private void adopt_anchor (Run run, string digest, string dest) {
            run.anchors[digest] = dest;
            string object = object_path (digest);
            DirUtils.create (Path.get_dirname (object), 0700);
            string next = object + ".next";
            FileUtils.unlink (next);
            if (make_link (dest, next) == 0 && FileUtils.rename (next, object) != 0) FileUtils.unlink (next);
        }

        private void deduplicate (Run run, string dest, string digest) {
            if (digest.length < 3) return;
            string tmp = dest + ".dedup";
            if (link_shared (run, digest, tmp)) {
                if (FileUtils.rename (tmp, dest) != 0) FileUtils.unlink (tmp);
                return;
            }
            string object = object_path (digest);
            if (FileUtils.test (object, FileTest.EXISTS)) {
                adopt_anchor (run, digest, dest);
                return;
            }
            DirUtils.create (Path.get_dirname (object), 0700);
            make_link (dest, object);
        }
        private void update_latest (string id) {
            string link = Path.build_filename (root, "latest");
            string tmp = link + ".part";
            FileUtils.unlink (tmp);
            if (Posix.symlink (Path.build_filename ("snapshots", id), tmp) == 0) FileUtils.rename (tmp, link);
        }

        private void ensure_space (uint64 needed, string? keep, ProgressFunc progress) throws Error {
            if (needed == 0) return;
            while (true) {
                var s = filesystem_stats ();
                if (s.free >= needed + SPACE_MARGIN) return;
                var all = list_snapshots ();
                SnapshotInfo? oldest = null;
                foreach (var info in all) {
                    if (info.id != keep) {
                        oldest = info;
                        break;
                    }
                }
                if (oldest == null) {
                    throw new BackupError.NO_SPACE (_("There is not enough space for this backup: %s needed, %s free"),
                                                   format_bytes (needed), format_bytes (s.free));
                }
                progress (0, "pruning", oldest.id);
                remove_snapshot (oldest.id);
                collect_objects ();
            }
        }

        private void clear_partial () {
            Dir dir;
            try {
                dir = Dir.open (partial_dir);
            } catch (FileError e) {
                return;
            }
            string? name;
            var stale = new Gee.ArrayList<string> ();
            while ((name = dir.read_name ()) != null) stale.add (Path.build_filename (partial_dir, name));
            foreach (string path in stale) remove_tree (path);
        }

        public static void remove_tree (string path) {
            Posix.Stat st;
            if (Posix.lstat (path, out st) != 0) return;
            if (Posix.S_ISDIR (st.st_mode)) {
                Posix.chmod (path, (Posix.mode_t) ((st.st_mode & 07777) | 0700));
                Dir dir;
                try {
                    dir = Dir.open (path);
                } catch (FileError e) {
                    return;
                }
                var names = new Gee.ArrayList<string> ();
                string? name;
                while ((name = dir.read_name ()) != null) names.add (name);
                foreach (string n in names) remove_tree (Path.build_filename (path, n));
                DirUtils.remove (path);
            } else {
                FileUtils.unlink (path);
            }
        }

        private void remove_snapshot (string snapshot) {
            string final_path = snapshot_path (snapshot);
            string doomed = Path.build_filename (partial_dir, "deleting-" + snapshot);
            if (FileUtils.rename (final_path, doomed) == 0) remove_tree (doomed);
            else remove_tree (final_path);
            mutex.lock ();
            manifests.remove (snapshot);
            indexes.remove (snapshot);
            touched.remove (snapshot);
            index_order.remove (snapshot);
            mutex.unlock ();
        }

        public int reference_chunk { get; set; default = 32768; }

        private ReferenceSet? referenced_digests () {
            var refs = new ReferenceSet (partial_dir, reference_chunk);
            try {
                Dir dir = Dir.open (snapshots_dir);
                string? name;
                while ((name = dir.read_name ()) != null) {
                    if (name.has_prefix (".")) continue;
                    string file = Path.build_filename (snapshots_dir, name, "index");
                    if (!FileUtils.test (file, FileTest.EXISTS)) continue;
                    refs.add_index (file);
                }
                refs.finish ();
            } catch (Error e) {
                refs.close ();
                return null;
            }
            return refs;
        }

        private void collect_objects () {
            ReferenceSet? refs = null;
            if (objects_mode) {
                refs = referenced_digests ();
                if (refs == null) return;
            }
            try {
                sweep_objects (refs);
            } finally {
                if (refs != null) refs.close ();
            }
        }

        private void sweep_objects (ReferenceSet? refs) {
            var buckets = new Gee.ArrayList<string> ();
            try {
                Dir top = Dir.open (objects_dir);
                string? b;
                while ((b = top.read_name ()) != null) {
                    if (!b.has_prefix (".")) buckets.add (b);
                }
            } catch (FileError e) {
                return;
            }
            buckets.sort ((x, y) => GLib.strcmp (x, y));
            foreach (string b in buckets) {
                string bucket = Path.build_filename (objects_dir, b);
                Dir dir;
                try {
                    dir = Dir.open (bucket);
                } catch (FileError e) {
                    continue;
                }
                string? name;
                var names = new Gee.ArrayList<string> ();
                while ((name = dir.read_name ()) != null) names.add (name);
                if (refs != null) names.sort ((x, y) => GLib.strcmp (x, y));
                foreach (string n in names) {
                    string file = Path.build_filename (bucket, n);
                    Posix.Stat st;
                    if (refs != null) {
                        if (!refs.contains_next (n)) FileUtils.unlink (file);
                    } else if (Posix.lstat (file, out st) == 0 && st.st_nlink <= 1) {
                        FileUtils.unlink (file);
                    }
                }
            }
        }

        public void delete_snapshot (string snapshot) throws Error {
            if (!FileUtils.test (snapshot_path (snapshot), FileTest.IS_DIR)) {
                throw new BackupError.NOT_FOUND (_("The backup %s does not exist"), snapshot);
            }
            acquire ();
            try {
                remove_snapshot (snapshot);
                collect_objects ();
                var all = list_snapshots ();
                string link = Path.build_filename (root, "latest");
                if (all.size > 0) update_latest (all[all.size - 1].id);
                else FileUtils.unlink (link);
                measure_usage ();
            } finally {
                release ();
            }
        }

        public void prune (int keep_last) throws Error {
            if (keep_last <= 0) return;
            apply_retention (RetentionMode.KEEP_LAST, keep_last, new DateTime.now_utc ().to_unix (), new TimeZone.utc ());
        }

        public Gee.List<string> apply_retention (RetentionMode mode, int keep_last, int64 now, TimeZone zone) throws Error {
            acquire ();
            try {
                var doomed = Retention.doomed (list_snapshots (), mode, keep_last, now, zone);
                foreach (string d in doomed) remove_snapshot (d);
                if (doomed.size > 0) {
                    collect_objects ();
                    var all = list_snapshots ();
                    if (all.size > 0) update_latest (all[all.size - 1].id);
                }
                measure_usage ();
                return doomed;
            } finally {
                release ();
            }
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
            if (!objects_mode) return tree_path (snapshot, path);
            string cache = Path.build_filename (Environment.get_user_cache_dir (), "singularity-backups", "materialized",
                                                Checksum.compute_for_string (ChecksumType.SHA1, root), snapshot);
            string target = Path.build_filename (cache, path);
            if (FileUtils.test (target, FileTest.EXISTS) || FileUtils.test (target, FileTest.IS_SYMLINK)) return target;
            DirUtils.create_with_parents (Path.get_dirname (target), 0700);
            restore (snapshot, path, target, false, cancellable);
            return target;
        }

        public void restore (string snapshot, string path, string target, bool merge, Cancellable? cancellable) throws Error {
            var index = index_for (snapshot);
            var top = index.lookup (path);
            if (top == null) throw new BackupError.NOT_FOUND (_("%s is not in this backup"), path);
            uint8[] buffer = new uint8[BUFFER];
            var attrs = XattrSet.load (Path.build_filename (snapshot_path (snapshot), "xattrs"));
            if (top.kind != EntryKind.DIRECTORY) {
                restore_entry (snapshot, top, target, merge, buffer, attrs);
                return;
            }
            Posix.Stat st;
            bool exists = Posix.lstat (target, out st) == 0;
            if (exists && !(merge && Posix.S_ISDIR (st.st_mode))) {
                throw new BackupError.FAILED (_("%s already exists"), target);
            }
            if (!exists && DirUtils.create_with_parents (target, 0700) != 0) {
                throw new BackupError.FAILED (_("Cannot create %s: %s"), target, strerror (errno));
            }
            string prefix = path + "/";
            var dirs = new Gee.ArrayList<Entry> ();
            dirs.add (top);
            var dir_targets = new Gee.ArrayList<string> ();
            dir_targets.add (target);
            string[] failures = {};
            foreach (var e in index) {
                if (!e.path.has_prefix (prefix)) continue;
                if (cancellable != null && cancellable.is_cancelled ()) throw new BackupError.CANCELLED (_("Cancelled"));
                string dest = Path.build_filename (target, e.path.substring (prefix.length));
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
                    restore_entry (snapshot, e, dest, merge, buffer, attrs);
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

        private void restore_entry (string snapshot, Entry e, string dest, bool merge, uint8[] buffer, XattrSet attrs) throws Error {
            Posix.Stat st;
            bool exists = Posix.lstat (dest, out st) == 0;
            if (exists && !merge) throw new BackupError.FAILED (_("%s already exists"), dest);
            if (exists && Posix.S_ISDIR (st.st_mode)) throw new BackupError.FAILED (_("%s is a folder"), dest);
            string tmp = Path.build_filename (Path.get_dirname (dest), ".%s.restoring".printf (Path.get_basename (dest)));
            FileUtils.unlink (tmp);
            if (e.kind == EntryKind.SYMLINK) {
                if (Posix.symlink (e.target, tmp) != 0) throw new BackupError.FAILED (_("Cannot restore %s: %s"), e.path, strerror (errno));
            } else {
                string source = content_path (snapshot, e);
                int input = Posix.open (source, Posix.O_RDONLY | Posix.O_CLOEXEC);
                if (input < 0) throw new BackupError.FAILED (_("Cannot read %s from the backup: %s"), e.path, strerror (errno));
                int output = Posix.open (tmp, Posix.O_WRONLY | Posix.O_CREAT | Posix.O_EXCL | Posix.O_CLOEXEC, 0600);
                if (output < 0) {
                    int err = errno;
                    Posix.close (input);
                    throw new BackupError.FAILED (_("Cannot restore %s: %s"), e.path, strerror (err));
                }
                bool ok = true;
                while (true) {
                    ssize_t n = Posix.read (input, buffer, buffer.length);
                    if (n < 0 && errno == Posix.EINTR) continue;
                    if (n < 0) {
                        ok = false;
                        break;
                    }
                    if (n == 0) break;
                    if (!write_all (output, buffer, (size_t) n)) {
                        ok = false;
                        break;
                    }
                }
                Posix.close (input);
                if (ok) {
                    Posix.fchmod (output, (Posix.mode_t) e.mode);
                    var a = attrs.lookup (e.path);
                    if (a != null) XattrSet.apply (tmp, a);
                    Posix.timespec[] times = { mtime_spec (e.mtime_ns), mtime_spec (e.mtime_ns) };
                    Posix.futimens (output, times);
                    ok = Posix.fsync (output) == 0;
                }
                Posix.close (output);
                if (!ok) {
                    FileUtils.unlink (tmp);
                    throw new BackupError.FAILED (_("Cannot restore %s"), e.path);
                }
            }
            if (FileUtils.rename (tmp, dest) != 0) {
                FileUtils.unlink (tmp);
                throw new BackupError.FAILED (_("Cannot restore %s: %s"), e.path, strerror (errno));
            }
        }

        public VerifyResult verify (string snapshot, Cancellable? cancellable, ProgressFunc? progress) throws Error {
            var index = index_for (snapshot);
            var result = new VerifyResult ();
            string[] damaged = {};
            string[] missing = {};
            uint64 total = 0;
            foreach (var e in index) if (e.kind == EntryKind.FILE) total += e.size;
            uint64 seen = 0;
            uint8[] buffer = new uint8[BUFFER];
            int64 last = 0;
            foreach (var e in index) {
                if (cancellable != null && cancellable.is_cancelled ()) throw new BackupError.CANCELLED (_("Cancelled"));
                if (objects_mode && e.kind != EntryKind.FILE) continue;
                string file = content_path (snapshot, e);
                Posix.Stat st;
                if (Posix.lstat (file, out st) != 0) {
                    missing += e.path;
                    continue;
                }
                if (e.kind != EntryKind.FILE) continue;
                result.checked++;
                if ((uint64) st.st_size != e.size) {
                    damaged += e.path;
                    if (e.digest.length > 2) FileUtils.unlink (Path.build_filename (objects_dir, e.digest.substring (0, 2), e.digest));
                    continue;
                }
                int fd = Posix.open (file, Posix.O_RDONLY | Posix.O_CLOEXEC);
                if (fd < 0) {
                    damaged += e.path;
                    continue;
                }
                var sum = new Checksum (ChecksumType.SHA256);
                ssize_t n;
                while ((n = Posix.read (fd, buffer, buffer.length)) > 0) {
                    sum.update (buffer, (size_t) n);
                    seen += (uint64) n;
                    int64 t = get_monotonic_time ();
                    if (progress != null && t - last > 100000) {
                        last = t;
                        progress (total > 0 ? (double) seen / total : 1, "verifying", e.path);
                    }
                }
                Posix.close (fd);
                if (e.digest != "" && sum.get_string () != e.digest) {
                    damaged += e.path;
                    if (e.digest.length > 2) FileUtils.unlink (Path.build_filename (objects_dir, e.digest.substring (0, 2), e.digest));
                }
            }
            result.damaged = damaged;
            result.missing = missing;
            string marker = Path.build_filename (snapshot_path (snapshot), "damaged");
            if (!result.ok) {
                var b = new StringBuilder ();
                foreach (string d in damaged) b.append (d + "\n");
                foreach (string m in missing) b.append (m + "\n");
                try {
                    FileUtils.set_contents (marker, b.str);
                } catch (Error e) {
                }
            } else {
                FileUtils.unlink (marker);
            }
            return result;
        }

        private RepoStats filesystem_stats () {
            var s = new RepoStats ();
            Posix.statvfs v;
            if (Posix.statvfs_exec (root, out v) == 0) {
                s.free = (uint64) v.f_bavail * v.f_frsize;
                s.capacity = (uint64) v.f_blocks * v.f_frsize;
            }
            s.links = links || objects_mode;
            s.store = store;
            return s;
        }

        private void measure_usage () {
            double total = 0;
            measure_dir (snapshots_dir, ref total);
            measure_dir (objects_dir, ref total);
            try {
                FileUtils.set_contents (Path.build_filename (root, "usage"), ((uint64) (total + 0.5)).to_string ());
            } catch (Error e) {
            }
        }

        private static void measure_dir (string path, ref double total) {
            Dir dir;
            try {
                dir = Dir.open (path);
            } catch (FileError e) {
                return;
            }
            string? name;
            while ((name = dir.read_name ()) != null) {
                string child = Path.build_filename (path, name);
                Posix.Stat st;
                if (Posix.lstat (child, out st) != 0) continue;
                if (Posix.S_ISDIR (st.st_mode)) {
                    measure_dir (child, ref total);
                } else {
                    total += (double) st.st_blocks * 512 / uint.max ((uint) st.st_nlink, 1);
                }
            }
        }

        public RepoStats stats () throws Error {
            var s = filesystem_stats ();
            string file = Path.build_filename (root, "usage");
            string text;
            if (!FileUtils.test (file, FileTest.EXISTS)) measure_usage ();
            try {
                FileUtils.get_contents (file, out text);
                s.used = uint64.parse (text.strip ());
            } catch (Error e) {
                s.used = 0;
            }
            return s;
        }
    }
}
