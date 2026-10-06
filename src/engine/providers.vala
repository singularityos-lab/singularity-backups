namespace Singularity.Backups {

    public interface Provider : Object {
        public abstract string id { get; }
        public abstract string title { get; }
        public abstract string description { get; }
        public abstract string icon_name { get; }

        public abstract bool available (BackupPlan plan);
        public abstract SourceRoot? prepare (BackupPlan plan, string staging, string? repository) throws Error;
        public abstract void restore_all (Backend backend, string snapshot, BackupPlan plan,
                                          Cancellable? cancellable) throws Error;

        public virtual Gee.List<SourceRoot> data_roots (BackupPlan plan) {
            return new Gee.ArrayList<SourceRoot> ();
        }
    }

    public class UserDataProvider : Object, Provider {
        public string id { get { return "userdata"; } }
        public string title { get { return _("Personal Files"); } }
        public string description { get { return _("Your home folder, with documents, pictures, settings and app data"); } }
        public string icon_name { get { return "user-home"; } }

        public bool available (BackupPlan plan) {
            return plan.source_home != "" && FileUtils.test (plan.source_home, FileTest.IS_DIR);
        }

        public SourceRoot? prepare (BackupPlan plan, string staging, string? repository) throws Error {
            var ex = new Exclusions (plan.exclusions);
            if (repository != null) {
                string home = plan.source_home.has_suffix ("/") ? plan.source_home : plan.source_home + "/";
                if (repository.has_prefix (home)) ex.add_path (repository.substring (home.length));
            }
            ex.add_path (".local/state/singularity-backups");
            return new SourceRoot (plan.source_home, id, ex);
        }

        public void restore_all (Backend backend, string snapshot, BackupPlan plan, Cancellable? cancellable) throws Error {
            if (backend.lookup (snapshot, id) == null) return;
            backend.restore (snapshot, id, plan.source_home, true, cancellable);
        }
    }

    public class FlatpakApp : Object {
        public string app_id { get; set; default = ""; }
        public string origin { get; set; default = ""; }
        public string branch { get; set; default = ""; }
        public string installation { get; set; default = "user"; }
    }

    public class FlatpakProvider : Object, Provider {
        public string id { get { return "flatpak"; } }
        public string title { get { return _("Flatpak Apps"); } }
        public string description { get { return _("Installed apps and their data, reinstalled when you restore"); } }
        public string icon_name { get { return "package-x-generic"; } }

        public bool available (BackupPlan plan) {
            return Environment.find_program_in_path ("flatpak") != null;
        }

        public static Gee.List<FlatpakApp> parse_list (string output) {
            var apps = new Gee.ArrayList<FlatpakApp> ();
            foreach (string line in output.split ("\n")) {
                if (line.strip () == "") continue;
                string[] f = line.split ("\t");
                if (f.length < 3) continue;
                var app = new FlatpakApp ();
                app.app_id = f[0].strip ();
                app.origin = f[1].strip ();
                app.branch = f[2].strip ();
                app.installation = f.length > 3 && f[3].strip () != "" ? f[3].strip () : "user";
                if (app.app_id != "") apps.add (app);
            }
            return apps;
        }

        public static string to_json (Gee.List<FlatpakApp> apps) {
            var b = new Json.Builder ();
            b.begin_array ();
            foreach (var a in apps) {
                b.begin_object ();
                b.set_member_name ("id");
                b.add_string_value (a.app_id);
                b.set_member_name ("origin");
                b.add_string_value (a.origin);
                b.set_member_name ("branch");
                b.add_string_value (a.branch);
                b.set_member_name ("installation");
                b.add_string_value (a.installation);
                b.end_object ();
            }
            b.end_array ();
            var g = new Json.Generator ();
            g.pretty = true;
            g.root = b.get_root ();
            return g.to_data (null);
        }

        public static Gee.List<FlatpakApp> from_json (string data) throws Error {
            var parser = new Json.Parser ();
            parser.load_from_data (data);
            var apps = new Gee.ArrayList<FlatpakApp> ();
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.ARRAY) return apps;
            foreach (var node in root.get_array ().get_elements ()) {
                var o = node.get_object ();
                var app = new FlatpakApp ();
                app.app_id = o.get_string_member_with_default ("id", "");
                app.origin = o.get_string_member_with_default ("origin", "");
                app.branch = o.get_string_member_with_default ("branch", "");
                app.installation = o.get_string_member_with_default ("installation", "user");
                if (app.app_id != "") apps.add (app);
            }
            return apps;
        }

        public SourceRoot? prepare (BackupPlan plan, string staging, string? repository) throws Error {
            string dir = Path.build_filename (staging, id);
            DirUtils.create_with_parents (dir, 0700);
            string output;
            int status;
            Process.spawn_sync (null, { "flatpak", "list", "--app", "--columns=application,origin,branch,installation" },
                                null, SpawnFlags.SEARCH_PATH, null, out output, null, out status);
            if (status != 0) throw new BackupError.FAILED (_("Cannot list the installed Flatpak apps"));
            FileUtils.set_contents (Path.build_filename (dir, "apps.json"), to_json (parse_list (output)));
            return new SourceRoot (dir, id, null);
        }

        private static string data_folder (BackupPlan plan) {
            return Path.build_filename (plan.source_home, ".var", "app");
        }

        public Gee.List<SourceRoot> data_roots (BackupPlan plan) {
            var list = new Gee.ArrayList<SourceRoot> ();
            if ("userdata" in plan.providers || plan.source_home == "") return list;
            string data = data_folder (plan);
            if (FileUtils.test (data, FileTest.IS_DIR)) list.add (new SourceRoot (data, id + "/data", new Exclusions ({ "/*/cache", "/*/.cache" })));
            return list;
        }

        private static bool installed (FlatpakApp app) {
            int status;
            try {
                Process.spawn_sync (null, { "flatpak", "info", "--" + app.installation, app.app_id },
                                    null, SpawnFlags.SEARCH_PATH | SpawnFlags.STDOUT_TO_DEV_NULL | SpawnFlags.STDERR_TO_DEV_NULL,
                                    null, null, null, out status);
                return status == 0;
            } catch (Error e) {
                return false;
            }
        }

        public void restore_all (Backend backend, string snapshot, BackupPlan plan, Cancellable? cancellable) throws Error {
            if (backend.lookup (snapshot, id + "/data") != null) {
                string data = data_folder (plan);
                DirUtils.create_with_parents (data, 0700);
                backend.restore (snapshot, id + "/data", data, true, cancellable);
            }
            if (backend.lookup (snapshot, id + "/apps.json") == null) return;
            string file = backend.materialize (snapshot, id + "/apps.json", cancellable);
            string data;
            FileUtils.get_contents (file, out data);
            string[] failed = {};
            foreach (var app in from_json (data)) {
                if (cancellable != null && cancellable.is_cancelled ()) throw new BackupError.CANCELLED (_("Cancelled"));
                if (installed (app)) continue;
                string installation = app.installation == "system" ? "--system" : "--user";
                string refname = app.branch != "" ? "%s//%s".printf (app.app_id, app.branch) : app.app_id;
                int status;
                Process.spawn_sync (null, { "flatpak", "install", installation, "--noninteractive", "-y", app.origin, refname },
                                    null, SpawnFlags.SEARCH_PATH | SpawnFlags.STDOUT_TO_DEV_NULL | SpawnFlags.STDERR_TO_DEV_NULL,
                                    null, null, null, out status);
                if (status != 0) failed += app.app_id;
            }
            if (failed.length > 0) throw new BackupError.FAILED (_("Some apps could not be reinstalled: %s"), string.joinv (", ", failed));
        }
    }

    public class ABRootProvider : Object, Provider {
        public string id { get { return "abroot"; } }
        public string title { get { return _("ABRoot Configuration"); } }
        public string description { get { return _("The system packages and settings managed by ABRoot"); } }
        public string icon_name { get { return "drive-harddisk-system"; } }

        private static string root_path (BackupPlan plan) {
            return Path.build_filename (plan.system_root, "etc", "abroot");
        }

        private static HashTable<string, int64?>? usable = null;
        private static Mutex usable_lock = Mutex ();

        private static bool has_config (BackupPlan plan) {
            if (!FileUtils.test (root_path (plan), FileTest.IS_DIR)) return false;
            return FileUtils.test (Path.build_filename (root_path (plan), "abroot.json"), FileTest.IS_REGULAR) ||
                   FileUtils.test (Path.build_filename (plan.system_root, "usr", "share", "abroot", "abroot.json"), FileTest.IS_REGULAR);
        }

        public static string? command (BackupPlan plan) {
            string cmd = plan.abroot_command;
            if (cmd == "") return null;
            if (Path.is_absolute (cmd)) return FileUtils.test (cmd, FileTest.IS_EXECUTABLE) ? cmd : null;
            return Environment.find_program_in_path (cmd);
        }

        public bool available (BackupPlan plan) {
            if (!has_config (plan)) return false;
            string? cmd = command (plan);
            if (cmd == null) return false;
            string cache_key = cmd + "\n" + plan.system_root;
            int64 now = get_monotonic_time ();
            usable_lock.lock ();
            if (usable == null) usable = new HashTable<string, int64?> (str_hash, str_equal);
            int64? known = usable[cache_key];
            usable_lock.unlock ();
            if (known != null) {
                int64 k = known;
                if (now - (k < 0 ? -k : k) < 300 * (int64) 1000000) return k > 0;
            }
            bool ok = false;
            try {
                string[] env = Environ.get ();
                if (plan.system_root != "/") env = Environ.set_variable (env, "SINGULARITY_BACKUPS_SYSTEM_ROOT", plan.system_root, true);
                PluginRunner.run ({ cmd, "status", "--json" }, 15, env, null);
                ok = true;
            } catch (Error e) {
                ok = false;
            }
            usable_lock.lock ();
            usable[cache_key] = ok ? now : -now;
            usable_lock.unlock ();
            return ok;
        }

        public SourceRoot? prepare (BackupPlan plan, string staging, string? repository) throws Error {
            return new SourceRoot (root_path (plan), id, null);
        }

        public void restore_all (Backend backend, string snapshot, BackupPlan plan, Cancellable? cancellable) throws Error {
            if (backend.lookup (snapshot, id) == null) return;
            string source = backend.materialize (snapshot, id, cancellable);
            string helper = plan.system_helper;
            if (helper == "" || !FileUtils.test (helper, FileTest.IS_EXECUTABLE)) {
                throw new BackupError.UNSUPPORTED (_("Restoring the system configuration is not available on this system"));
            }
            string[] argv = plan.system_root == "/" ? new string[] { "pkexec", helper, "restore-abroot", source }
                                                     : new string[] { helper, "restore-abroot", source };
            string[] env = Environ.get ();
            if (plan.system_root != "/") env = Environ.set_variable (env, "SINGULARITY_BACKUPS_SYSTEM_ROOT", plan.system_root, true);
            int status;
            string err;
            Process.spawn_sync (null, argv, env, SpawnFlags.SEARCH_PATH | SpawnFlags.STDOUT_TO_DEV_NULL, null, null, out err, out status);
            if (status != 0) throw new BackupError.FAILED (_("The system configuration was not restored: %s"), err.strip ());
        }
    }

    public class Providers : Object {
        public static Gee.List<Provider> all () {
            var list = new Gee.ArrayList<Provider> ();
            list.add (new UserDataProvider ());
            list.add (new FlatpakProvider ());
            list.add (new ABRootProvider ());
            var builtin = new Gee.HashSet<string> ();
            foreach (var p in list) builtin.add (p.id);
            foreach (var m in PluginRegistry.discover (PluginKind.SOURCE)) {
                if (!builtin.contains (m.id)) list.add (new PluginProvider (m));
            }
            return list;
        }

        public static Provider? find (string id) {
            foreach (var p in all ()) if (p.id == id) return p;
            return null;
        }
    }
}
