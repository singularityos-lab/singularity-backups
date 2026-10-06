namespace Singularity.Backups {

    public class ExecBackend : Object, Backend {
        private string adapter;
        private string root = "";
        private string cache_dir;

        public string id { owned get { return "exec:" + Path.get_basename (adapter); } }
        public string location { owned get { return root; } }
        public bool supports_dedup { get { return false; } }

        public ExecBackend (string adapter) {
            this.adapter = adapter;
            cache_dir = Path.build_filename (Environment.get_user_cache_dir (), "singularity-backups", "extract");
        }

        private string run (string[] args, Cancellable? cancellable = null) throws Error {
            if (adapter == "" || !FileUtils.test (adapter, FileTest.IS_EXECUTABLE)) {
                throw new BackupError.UNAVAILABLE (_("The backup engine %s is not installed"), adapter);
            }
            string[] argv = { adapter };
            foreach (string a in args) argv += a;
            var proc = new Subprocess.newv (argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            string? output;
            string? err;
            proc.communicate_utf8 (null, cancellable, out output, out err);
            if (!proc.get_successful ()) {
                if (proc.get_if_exited () && proc.get_exit_status () == 2) {
                    throw new BackupError.NOT_FOUND ("%s", (err ?? "").strip ());
                }
                throw new BackupError.FAILED ("%s", (err ?? "").strip () != "" ? err.strip () : _("The backup engine failed"));
            }
            return output ?? "";
        }

        private static Json.Node parse (string text) throws Error {
            var parser = new Json.Parser ();
            parser.load_from_data (text);
            var node = parser.get_root ();
            if (node == null) throw new BackupError.CORRUPT (_("The backup engine returned no data"));
            return node;
        }

        private static Entry entry_from (Json.Object o) {
            var e = new Entry ();
            e.path = o.get_string_member_with_default ("path", "");
            e.kind = EntryKind.parse (o.get_string_member_with_default ("kind", "file"));
            e.mode = (uint32) o.get_int_member_with_default ("mode", e.kind == EntryKind.DIRECTORY ? 0755 : 0644);
            e.size = (uint64) o.get_int_member_with_default ("size", 0);
            e.mtime_ns = o.get_int_member_with_default ("mtime", 0) * 1000000000;
            e.digest = o.get_string_member_with_default ("digest", "");
            e.target = o.get_string_member_with_default ("target", "");
            return e;
        }

        private static SnapshotInfo info_from (Json.Object o) {
            var s = new SnapshotInfo ();
            s.id = o.get_string_member_with_default ("id", "");
            s.created = o.get_int_member_with_default ("created", parse_snapshot_id (s.id));
            s.label = o.get_string_member_with_default ("label", "");
            s.files = (uint64) o.get_int_member_with_default ("files", 0);
            s.bytes = (uint64) o.get_int_member_with_default ("bytes", 0);
            s.added_bytes = (uint64) o.get_int_member_with_default ("added-bytes", 0);
            s.host = o.get_string_member_with_default ("host", "");
            return s;
        }

        public void open (string location) throws Error {
            root = location;
            run ({ "open", location });
        }

        public Gee.List<SnapshotInfo> list_snapshots () throws Error {
            var list = new Gee.ArrayList<SnapshotInfo> ();
            var node = parse (run ({ "snapshots", root }));
            foreach (var n in node.get_array ().get_elements ()) list.add (info_from (n.get_object ()));
            list.sort ((a, b) => a.created < b.created ? -1 : (a.created > b.created ? 1 : strcmp (a.id, b.id)));
            return list;
        }

        public SnapshotInfo create_snapshot (BackupPlan plan, Gee.List<SourceRoot> roots,
                                             Cancellable? cancellable, ProgressFunc progress) throws Error {
            var b = new Json.Builder ();
            b.begin_array ();
            foreach (var r in roots) {
                b.begin_object ();
                b.set_member_name ("path");
                b.add_string_value (r.path);
                b.set_member_name ("prefix");
                b.add_string_value (r.prefix);
                b.set_member_name ("exclude");
                b.begin_array ();
                if (r.exclusions != null) foreach (string p in r.exclusions.patterns) b.add_string_value (p);
                b.end_array ();
                b.end_object ();
            }
            b.end_array ();
            var g = new Json.Generator ();
            g.root = b.get_root ();
            FileIOStream io;
            var tmp = File.new_tmp ("singularity-backups-XXXXXX.json", out io);
            io.output_stream.write_all (g.to_data (null).data, null);
            io.close ();
            try {
                var proc = new Subprocess.newv ({ adapter, "backup", root, tmp.get_path (), plan.label },
                                                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
                var lines = new DataInputStream (proc.get_stdout_pipe ());
                SnapshotInfo? result = null;
                string? line;
                while ((line = lines.read_line_utf8 (null, cancellable)) != null) {
                    if (line.has_prefix ("progress ")) {
                        string[] parts = line.substring (9).split (" ", 2);
                        progress (double.parse (parts[0]).clamp (0, 1), "copying", parts.length > 1 ? parts[1] : "");
                    } else if (line.has_prefix ("snapshot ")) {
                        result = info_from (parse (line.substring (9)).get_object ());
                    }
                }
                if (cancellable != null && cancellable.is_cancelled ()) {
                    proc.force_exit ();
                    throw new BackupError.CANCELLED (_("The backup was cancelled"));
                }
                proc.wait (null);
                if (!proc.get_successful () || result == null) {
                    var err = new DataInputStream (proc.get_stderr_pipe ()).read_upto ("\0", 1, null);
                    throw new BackupError.FAILED ("%s", err != null && err.strip () != "" ? err.strip () : _("The backup engine failed"));
                }
                foreach (string d in Retention.doomed (list_snapshots (), plan.retention, plan.keep_last,
                                                       new DateTime.now_utc ().to_unix (), new TimeZone.local ())) {
                    if (d != result.id) delete_snapshot (d);
                }
                return result;
            } finally {
                FileUtils.unlink (tmp.get_path ());
            }
        }

        private Gee.List<Entry> raw_list (string snapshot, string path) throws Error {
            var list = new Gee.ArrayList<Entry> ();
            var node = parse (run ({ "ls", root, snapshot, path }));
            foreach (var n in node.get_array ().get_elements ()) list.add (entry_from (n.get_object ()));
            return list;
        }

        public Gee.List<Entry> list_directory (string snapshot, string path) throws Error {
            var current = raw_list (snapshot, path);
            string? prev_id = null;
            var all = list_snapshots ();
            for (int i = 0; i < all.size; i++) if (all[i].id == snapshot && i > 0) prev_id = all[i - 1].id;
            var before = new HashTable<string, Entry> (str_hash, str_equal);
            if (prev_id != null) {
                try {
                    foreach (var e in raw_list (prev_id, path)) before[e.path] = e;
                } catch (BackupError.NOT_FOUND e) {
                }
            }
            var seen = new Gee.HashSet<string> ();
            foreach (var e in current) {
                e.origin = snapshot;
                seen.add (e.path);
                if (prev_id == null) continue;
                var old = before[e.path];
                if (old == null) e.change = Change.ADDED;
                else if (!old.same_content (e)) e.change = Change.CHANGED;
            }
            if (prev_id != null) {
                before.foreach ((k, e) => {
                    if (seen.contains (k)) return;
                    e.change = Change.REMOVED;
                    e.origin = prev_id;
                    current.add (e);
                });
            }
            return current;
        }

        public Entry? lookup (string snapshot, string path) throws Error {
            try {
                var e = entry_from (parse (run ({ "stat", root, snapshot, path })).get_object ());
                e.origin = snapshot;
                return e;
            } catch (BackupError.NOT_FOUND e) {
                return null;
            }
        }

        public string materialize (string snapshot, string path, Cancellable? cancellable) throws Error {
            string dest = Path.build_filename (cache_dir, snapshot, path);
            if (FileUtils.test (dest, FileTest.EXISTS)) return dest;
            DirUtils.create_with_parents (Path.get_dirname (dest), 0700);
            run ({ "extract", root, snapshot, path, dest }, cancellable);
            return dest;
        }

        public void restore (string snapshot, string path, string target, bool merge, Cancellable? cancellable) throws Error {
            run ({ "restore", root, snapshot, path, target, merge ? "merge" : "new" }, cancellable);
        }

        public void delete_snapshot (string snapshot) throws Error {
            run ({ "forget", root, snapshot });
        }

        public VerifyResult verify (string snapshot, Cancellable? cancellable, ProgressFunc? progress) throws Error {
            var o = parse (run ({ "check", root, snapshot }, cancellable)).get_object ();
            var r = new VerifyResult ();
            r.checked = (uint64) o.get_int_member_with_default ("checked", 0);
            string[] damaged = {};
            string[] missing = {};
            if (o.has_member ("damaged")) foreach (var n in o.get_array_member ("damaged").get_elements ()) damaged += n.get_string ();
            if (o.has_member ("missing")) foreach (var n in o.get_array_member ("missing").get_elements ()) missing += n.get_string ();
            r.damaged = damaged;
            r.missing = missing;
            return r;
        }

        public RepoStats stats () throws Error {
            var o = parse (run ({ "stats", root })).get_object ();
            var s = new RepoStats ();
            s.used = (uint64) o.get_int_member_with_default ("used", 0);
            s.free = (uint64) o.get_int_member_with_default ("free", 0);
            s.capacity = (uint64) o.get_int_member_with_default ("capacity", 0);
            s.links = false;
            return s;
        }
    }
}
