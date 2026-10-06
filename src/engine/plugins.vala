namespace Singularity.Backups {

    public enum PluginKind {
        SOURCE,
        DESTINATION;

        public string group () {
            return this == SOURCE ? "Backup Source" : "Backup Destination";
        }

        public string folder () {
            return this == SOURCE ? "sources" : "destinations";
        }

        public string extension () {
            return this == SOURCE ? ".backup-source" : ".backup-destination";
        }
    }

    public class PluginManifest : Object {
        public const int PROTOCOL = 1;

        public PluginKind kind { get; set; }
        public string id { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string description { get; set; default = ""; }
        public string icon_name { get; set; default = ""; }
        public string exec { get; set; default = ""; }
        public string try_exec { get; set; default = ""; }
        public string file { get; set; default = ""; }
        public bool user_installed { get; set; default = false; }

        public static PluginManifest load (string file, PluginKind kind) throws Error {
            var kf = new KeyFile ();
            kf.load_from_file (file, KeyFileFlags.NONE);
            string group = kind.group ();
            var m = new PluginManifest ();
            m.kind = kind;
            m.file = file;
            string base_name = Path.get_basename (file);
            m.id = kf.has_key (group, "Id") ? kf.get_string (group, "Id").strip () : base_name.substring (0, base_name.length - kind.extension ().length);
            m.name = kf.get_locale_string (group, "Name", null);
            m.description = kf.has_key (group, "Description") ? kf.get_locale_string (group, "Description", null) : "";
            m.icon_name = kf.has_key (group, "Icon") ? kf.get_string (group, "Icon").strip () : "";
            m.try_exec = kf.has_key (group, "TryExec") ? kf.get_string (group, "TryExec").strip () : "";
            int protocol = kf.has_key (group, "Protocol") ? kf.get_integer (group, "Protocol") : 1;
            if (protocol != PROTOCOL) throw new BackupError.UNSUPPORTED ("%s: protocol %d is not supported", file, protocol);
            string exec = kf.get_string (group, "Exec").strip ();
            if (exec.has_prefix ("./")) exec = exec.substring (2);
            if (!Path.is_absolute (exec) && exec.contains ("/")) exec = Path.build_filename (Path.get_dirname (file), exec);
            else if (!Path.is_absolute (exec) && FileUtils.test (Path.build_filename (Path.get_dirname (file), exec), FileTest.IS_REGULAR)) exec = Path.build_filename (Path.get_dirname (file), exec);
            else if (!Path.is_absolute (exec)) exec = Environment.find_program_in_path (exec) ?? exec;
            m.exec = exec;
            if (m.id == "" || m.name == "" || m.exec == "") throw new BackupError.FAILED ("%s: Id, Name and Exec are required", file);
            if (!Regex.match_simple ("^[a-z0-9][a-z0-9_.-]*$", m.id)) throw new BackupError.FAILED ("%s: invalid Id %s", file, m.id);
            return m;
        }

        public bool runnable {
            get {
                if (try_exec != "" && Environment.find_program_in_path (try_exec) == null) return false;
                Posix.Stat st;
                if (Posix.stat (exec, out st) != 0 || !Posix.S_ISREG (st.st_mode)) return false;
                if ((st.st_mode & Posix.S_IWOTH) != 0) return false;
                if (st.st_uid != 0 && st.st_uid != Posix.getuid ()) return false;
                return (st.st_mode & 0111) != 0;
            }
        }
    }

    public class PluginRunner : Object {
        public static string[] base_environment () {
            string[] env = Environ.get ();
            env = Environ.set_variable (env, "SINGULARITY_BACKUPS_PROTOCOL", PluginManifest.PROTOCOL.to_string (), true);
            return env;
        }

        public static string run (string[] argv, uint seconds, string[]? env, Cancellable? cancellable) throws Error {
            var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            launcher.set_environ (env ?? base_environment ());
            var process = launcher.spawnv (argv);
            var watchdog = new Cancellable ();
            ulong link = 0;
            if (cancellable != null) link = cancellable.connect (() => watchdog.cancel ());
            bool done = false;
            var guard = new Thread<void> ("backups-plugin", () => {
                int64 deadline = get_monotonic_time () + (int64) seconds * 1000000;
                while (!done) {
                    Thread.usleep (100000);
                    if (get_monotonic_time () > deadline) {
                        watchdog.cancel ();
                        break;
                    }
                }
            });
            string? output = null;
            string? errors = null;
            try {
                process.communicate_utf8 (null, watchdog, out output, out errors);
            } catch (IOError.CANCELLED e) {
                process.force_exit ();
                if (cancellable != null && cancellable.is_cancelled ()) throw new BackupError.CANCELLED (_("Cancelled"));
                throw new BackupError.FAILED (_("%s did not answer in time"), Path.get_basename (argv[0]));
            } finally {
                done = true;
                guard.join ();
                if (link != 0) cancellable.disconnect (link);
            }
            if (!process.get_if_exited () || process.get_exit_status () != 0) {
                string reason = errors != null ? errors.strip () : "";
                if (reason.contains ("\n")) reason = reason.substring (reason.last_index_of_char ('\n') + 1);
                throw new BackupError.FAILED ("%s", reason != "" ? reason : _("%s failed").printf (Path.get_basename (argv[0])));
            }
            return output ?? "";
        }

        public static Json.Node? parse (string output) {
            string text = output.strip ();
            if (text == "") return null;
            var parser = new Json.Parser ();
            try {
                parser.load_from_data (text);
            } catch (Error e) {
                return null;
            }
            return parser.get_root ();
        }
    }

    public class PluginRegistry : Object {
        public static string[] search_dirs (PluginKind kind) {
            string? user = Environment.get_variable ("XDG_DATA_HOME");
            if (user == null || !Path.is_absolute (user)) user = Environment.get_user_data_dir ();
            string[] dirs = { Path.build_filename (user, "singularity", "backups", kind.folder ()) };
            foreach (string d in Environment.get_system_data_dirs ()) dirs += Path.build_filename (d, "singularity", "backups", kind.folder ());
            return dirs;
        }

        public static Gee.List<PluginManifest> discover (PluginKind kind) {
            var seen = new Gee.HashSet<string> ();
            var list = new Gee.ArrayList<PluginManifest> ();
            string user_dir = search_dirs (kind)[0];
            foreach (string dir in search_dirs (kind)) {
                Dir handle;
                try {
                    handle = Dir.open (dir);
                } catch (FileError e) {
                    continue;
                }
                var names = new Gee.ArrayList<string> ();
                string? name;
                while ((name = handle.read_name ()) != null) if (name.has_suffix (kind.extension ())) names.add (name);
                names.sort ((a, b) => strcmp (a, b));
                foreach (string n in names) {
                    try {
                        var m = PluginManifest.load (Path.build_filename (dir, n), kind);
                        if (seen.contains (m.id)) continue;
                        seen.add (m.id);
                        m.user_installed = dir == user_dir;
                        list.add (m);
                    } catch (Error e) {
                        message ("Backups: skipped plugin: %s", e.message);
                    }
                }
            }
            return list;
        }

        public static PluginManifest? find (PluginKind kind, string id) {
            foreach (var m in discover (kind)) if (m.id == id) return m;
            return null;
        }
    }

    public class PluginRoot : Object {
        public string name { get; set; default = ""; }
        public string path { get; set; default = ""; }
        public string home_path { get; set; default = ""; }
        public string[] exclude { get; set; default = {}; }
    }

    public class PluginProvider : Object, Provider {
        public const string ROOTS_FILE = ".backup-roots.json";

        public PluginManifest manifest { get; construct; }
        private Gee.ArrayList<PluginRoot> roots = new Gee.ArrayList<PluginRoot> ();
        private static HashTable<string, CheckResult>? checks = null;
        private static Mutex checks_lock = Mutex ();

        private class CheckResult {
            public bool available;
            public string reason;
            public int64 time;
        }

        public string id { get { return manifest.id; } }
        public string title { get { return manifest.name; } }
        public string description { get { return manifest.description; } }
        public string icon_name { get { return manifest.icon_name != "" ? manifest.icon_name : "application-x-addon"; } }
        public string unavailable_reason { get; private set; default = ""; }
        public string[] home_exclusions { get; private set; default = {}; }
        public string[] warnings { get; private set; default = {}; }

        public PluginProvider (PluginManifest manifest) {
            Object (manifest: manifest);
        }

        public static void forget_checks () {
            checks_lock.lock ();
            checks = null;
            checks_lock.unlock ();
        }

        public bool available (BackupPlan plan) {
            if (!manifest.runnable) {
                unavailable_reason = _("The plugin cannot run on this system");
                return false;
            }
            checks_lock.lock ();
            if (checks == null) checks = new HashTable<string, CheckResult> (str_hash, str_equal);
            var cached = checks[manifest.exec];
            checks_lock.unlock ();
            if (cached != null && get_monotonic_time () - cached.time < 60 * 1000000) {
                unavailable_reason = cached.reason;
                return cached.available;
            }
            var r = new CheckResult ();
            r.time = get_monotonic_time ();
            r.available = false;
            r.reason = "";
            try {
                var node = PluginRunner.parse (PluginRunner.run ({ manifest.exec, "check" }, 20, environment (plan), null));
                if (node != null && node.get_node_type () == Json.NodeType.OBJECT) {
                    var o = node.get_object ();
                    r.available = o.get_boolean_member_with_default ("available", false);
                    r.reason = o.get_string_member_with_default ("reason", "");
                } else {
                    r.available = true;
                }
            } catch (Error e) {
                r.reason = e.message;
            }
            checks_lock.lock ();
            checks[manifest.exec] = r;
            checks_lock.unlock ();
            unavailable_reason = r.reason;
            return r.available;
        }

        private string[] environment (BackupPlan plan) {
            string[] env = PluginRunner.base_environment ();
            if (plan.source_home != "") env = Environ.set_variable (env, "SINGULARITY_BACKUPS_HOME", plan.source_home, true);
            return env;
        }

        private static string[] strings (Json.Object o, string member) {
            string[] result = {};
            if (!o.has_member (member) || o.get_member (member).get_node_type () != Json.NodeType.ARRAY) return result;
            foreach (var n in o.get_array_member (member).get_elements ()) {
                if (n.get_value_type () == typeof (string)) result += n.get_string ();
            }
            return result;
        }

        public SourceRoot? prepare (BackupPlan plan, string staging, string? repository) throws Error {
            roots.clear ();
            warnings = {};
            home_exclusions = {};
            string dir = Path.build_filename (staging, id);
            DirUtils.create_with_parents (dir, 0700);
            string output = PluginRunner.run ({ manifest.exec, "backup", dir }, 1800, environment (plan), null);
            var node = PluginRunner.parse (output);
            string home = plan.source_home.has_suffix ("/") ? plan.source_home : plan.source_home + "/";
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("roots");
            b.begin_array ();
            if (node != null && node.get_node_type () == Json.NodeType.OBJECT) {
                var o = node.get_object ();
                home_exclusions = strings (o, "home-exclusions");
                string[] notes = strings (o, "warnings");
                if (o.has_member ("roots")) {
                    foreach (var n in o.get_array_member ("roots").get_elements ()) {
                        var r = n.get_object ();
                        var root = new PluginRoot ();
                        root.name = r.get_string_member_with_default ("name", "");
                        root.path = r.get_string_member_with_default ("path", "");
                        root.exclude = strings (r, "exclude");
                        if (!Regex.match_simple ("^[A-Za-z0-9_.-]+$", root.name) || root.name.has_prefix (".") ||
                            !Path.is_absolute (root.path) || FileUtils.test (Path.build_filename (dir, root.name), FileTest.EXISTS)) {
                            notes += _("Skipped a folder the plugin named incorrectly: %s").printf (root.name);
                            continue;
                        }
                        if (!FileUtils.test (root.path, FileTest.IS_DIR)) continue;
                        root.home_path = root.path.has_prefix (home) ? root.path.substring (home.length) : "";
                        roots.add (root);
                        b.begin_object ();
                        b.set_member_name ("name");
                        b.add_string_value (root.name);
                        b.set_member_name ("path");
                        b.add_string_value (root.path);
                        b.set_member_name ("home-path");
                        b.add_string_value (root.home_path);
                        b.end_object ();
                    }
                }
                warnings = notes;
            }
            b.end_array ();
            b.end_object ();
            var g = new Json.Generator ();
            g.pretty = true;
            g.root = b.get_root ();
            FileUtils.set_contents (Path.build_filename (dir, ROOTS_FILE), g.to_data (null));
            return new SourceRoot (dir, id, null);
        }

        public Gee.List<SourceRoot> data_roots (BackupPlan plan) {
            var list = new Gee.ArrayList<SourceRoot> ();
            foreach (var r in roots) list.add (new SourceRoot (r.path, id + "/" + r.name, r.exclude.length > 0 ? new Exclusions (r.exclude) : null));
            return list;
        }

        public void restore_all (Backend backend, string snapshot, BackupPlan plan, Cancellable? cancellable) throws Error {
            if (backend.lookup (snapshot, id) == null) return;
            var names = new Gee.HashSet<string> ();
            var targets = new Gee.ArrayList<string> ();
            var sources = new Gee.ArrayList<string> ();
            if (backend.lookup (snapshot, id + "/" + ROOTS_FILE) != null) {
                string file = backend.materialize (snapshot, id + "/" + ROOTS_FILE, cancellable);
                var parser = new Json.Parser ();
                parser.load_from_file (file);
                var node = parser.get_root ();
                if (node != null && node.get_node_type () == Json.NodeType.OBJECT && node.get_object ().has_member ("roots")) {
                    foreach (var n in node.get_object ().get_array_member ("roots").get_elements ()) {
                        var r = n.get_object ();
                        string name = r.get_string_member_with_default ("name", "");
                        string home_path = r.get_string_member_with_default ("home-path", "");
                        string path = home_path != "" ? Path.build_filename (plan.source_home, home_path) : r.get_string_member_with_default ("path", "");
                        if (name == "" || path == "") continue;
                        names.add (name);
                        sources.add (id + "/" + name);
                        targets.add (path);
                    }
                }
            }
            string work = Path.build_filename (Environment.get_user_cache_dir (), "singularity-backups", "plugin-restore", "%s-%s".printf (id, Uuid.string_random ()));
            DirUtils.create_with_parents (work, 0700);
            try {
                foreach (var e in backend.list_directory (snapshot, id)) {
                    if (e.change == Change.REMOVED || names.contains (e.name)) continue;
                    backend.restore (snapshot, e.path, Path.build_filename (work, e.name), false, cancellable);
                }
                string[] failed = {};
                for (int i = 0; i < sources.size; i++) {
                    if (backend.lookup (snapshot, sources[i]) == null) continue;
                    DirUtils.create_with_parents (targets[i], 0700);
                    try {
                        backend.restore (snapshot, sources[i], targets[i], true, cancellable);
                    } catch (BackupError.CANCELLED e) {
                        throw e;
                    } catch (Error e) {
                        failed += "%s: %s".printf (targets[i], e.message);
                    }
                }
                string output = PluginRunner.run ({ manifest.exec, "restore", work }, 3600, environment (plan), cancellable);
                var node = PluginRunner.parse (output);
                if (node != null && node.get_node_type () == Json.NodeType.OBJECT) {
                    foreach (string f in strings (node.get_object (), "failed")) failed += f;
                }
                if (failed.length > 0) throw new BackupError.FAILED (_("%s: some items could not be restored: %s"), title, string.joinv (", ", failed));
            } finally {
                LocalBackend.remove_tree (work);
            }
        }
    }

    public class PluginTarget : Object {
        public string plugin { get; set; default = ""; }
        public string id { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string detail { get; set; default = ""; }
        public string icon { get; set; default = ""; }
        public bool available { get; set; default = true; }
        public string reason { get; set; default = ""; }
        public uint64 used { get; set; default = 0; }
        public uint64 total { get; set; default = 0; }
    }

    public class DestinationPlugin : Object {
        public PluginManifest manifest { get; construct; }

        public DestinationPlugin (PluginManifest manifest) {
            Object (manifest: manifest);
        }

        public Gee.List<PluginTarget> targets () {
            var list = new Gee.ArrayList<PluginTarget> ();
            if (!manifest.runnable) return list;
            Json.Node? node = null;
            try {
                node = PluginRunner.parse (PluginRunner.run ({ manifest.exec, "targets" }, 20, null, null));
            } catch (Error e) {
                warning ("Backups: %s: %s", manifest.id, e.message);
                return list;
            }
            if (node == null || node.get_node_type () != Json.NodeType.ARRAY) return list;
            foreach (var n in node.get_array ().get_elements ()) {
                if (n.get_node_type () != Json.NodeType.OBJECT) continue;
                var o = n.get_object ();
                var d = new PluginTarget ();
                d.plugin = manifest.id;
                d.id = o.get_string_member_with_default ("id", "");
                d.name = o.get_string_member_with_default ("name", d.id);
                d.detail = o.get_string_member_with_default ("detail", "");
                d.icon = o.get_string_member_with_default ("icon", manifest.icon_name);
                d.available = o.get_boolean_member_with_default ("available", true);
                d.reason = o.get_string_member_with_default ("reason", "");
                d.total = (uint64) o.get_int_member_with_default ("total", 0);
                d.used = (uint64) o.get_int_member_with_default ("used", 0);
                if (d.id != "") list.add (d);
            }
            return list;
        }

        public RemoteStore open_store (string target) {
            return new ExecStore (manifest.exec, target);
        }
    }
}
