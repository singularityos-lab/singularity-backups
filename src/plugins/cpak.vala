namespace Singularity.Backups {

    public class CpakSource : Object {
        private string home;
        private string? cpak;

        public CpakSource () {
            home = Environment.get_variable ("SINGULARITY_BACKUPS_HOME") ?? Environment.get_home_dir ();
            cpak = Environment.get_variable ("SINGULARITY_BACKUPS_CPAK");
            if (cpak == null || cpak == "") cpak = Environment.find_program_in_path ("cpak");
            if (cpak == null) {
                string local = Path.build_filename (home, ".local", "bin", "cpak");
                if (FileUtils.test (local, FileTest.IS_EXECUTABLE)) cpak = local;
            }
        }

        private string installation () {
            string? root = Environment.get_variable ("CPAK_INSTALLATION_PATH");
            return root != null && root != "" ? root : Path.build_filename (home, ".local", "share", "cpak");
        }

        private string store_path () {
            string? store = Environment.get_variable ("CPAK_STORE_PATH");
            return store != null && store != "" ? store : Path.build_filename (installation (), "store");
        }

        private string run_cpak (string[] args, int seconds) throws Error {
            string[] argv = { "timeout", seconds.to_string (), cpak };
            foreach (string a in args) argv += a;
            string output;
            string errors;
            int status;
            Process.spawn_sync (null, argv, null, SpawnFlags.SEARCH_PATH, null, out output, out errors, out status);
            if (status != 0) {
                string reason = errors.strip ();
                throw new IOError.FAILED ("%s", reason != "" ? reason : "cpak %s failed".printf (args[0]));
            }
            return output;
        }

        private Json.Array list_apps () throws Error {
            var parser = new Json.Parser ();
            string text = run_cpak ({ "list", "--json" }, 60).strip ();
            if (text == "" || text == "null") return new Json.Array ();
            parser.load_from_data (text);
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.ARRAY) throw new IOError.FAILED ("cpak list did not return a list");
            return root.get_array ();
        }

        private static string member (Json.Object o, string name) {
            if (!o.has_member (name) || o.get_member (name).get_value_type () != typeof (string)) return "";
            return o.get_string_member (name);
        }

        private static string identity (Json.Object o) {
            return "%s|%s|%s|%s".printf (member (o, "origin"), member (o, "branch"), member (o, "release"), member (o, "commit"));
        }

        private static void print_json (Json.Node node) {
            var g = new Json.Generator ();
            g.pretty = true;
            g.root = node;
            stdout.printf ("%s\n", g.to_data (null));
        }

        private int check () {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("available");
            if (cpak == null) {
                b.add_boolean_value (false);
                b.set_member_name ("reason");
                b.add_string_value (_("cpak is not installed"));
            } else {
                try {
                    list_apps ();
                    b.add_boolean_value (true);
                } catch (Error e) {
                    b.add_boolean_value (false);
                    b.set_member_name ("reason");
                    b.add_string_value (e.message);
                }
            }
            b.end_object ();
            print_json (b.get_root ());
            return 0;
        }

        private int backup (string dir) {
            if (cpak == null) {
                stderr.printf ("%s\n", _("cpak is not installed"));
                return 1;
            }
            Json.Array apps;
            try {
                apps = list_apps ();
            } catch (Error e) {
                stderr.printf ("%s\n", e.message);
                return 1;
            }
            var kept = new Json.Builder ();
            kept.begin_array ();
            foreach (var n in apps.get_elements ()) {
                if (n.get_node_type () != Json.NodeType.OBJECT) continue;
                var o = n.get_object ();
                if (o.get_boolean_member_with_default ("pulled_in", false) || member (o, "origin") == "") continue;
                kept.begin_object ();
                foreach (string f in new string[] { "name", "origin", "branch", "release", "commit", "version", "cpak_id" }) {
                    kept.set_member_name (f);
                    kept.add_string_value (member (o, f));
                }
                kept.end_object ();
            }
            kept.end_array ();
            var g = new Json.Generator ();
            g.pretty = true;
            g.root = kept.get_root ();
            try {
                FileUtils.set_contents (Path.build_filename (dir, "apps.json"), g.to_data (null));
            } catch (Error e) {
                stderr.printf ("%s\n", e.message);
                return 1;
            }
            string[] warnings = {};
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (run_cpak ({ "ps", "--json" }, 30));
                var root = parser.get_root ();
                uint running = root != null && root.get_node_type () == Json.NodeType.ARRAY ? root.get_array ().get_length () : 0;
                if (running > 0) warnings += ngettext ("%u app was running, its data may be saved in the middle of a change",
                                                       "%u apps were running, their data may be saved in the middle of a change", running).printf (running);
            } catch (Error e) {
            }
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("roots");
            b.begin_array ();
            string store = store_path ();
            string config = Path.build_filename (home, ".config", "cpak");
            string[,] roots = {
                { "application-data", Path.build_filename (store, "application-data") },
                { "identities", Path.build_filename (store, "identities") },
                { "grants", Path.build_filename (store, "grants") },
                { "config", Path.build_filename (store, "config") },
                { "services", Path.build_filename (store, "services") },
                { "overrides", Path.build_filename (config, "overrides") },
                { "addons", Path.build_filename (config, "addons") }
            };
            for (int i = 0; i < roots.length[0]; i++) {
                if (!FileUtils.test (roots[i, 1], FileTest.IS_DIR)) continue;
                b.begin_object ();
                b.set_member_name ("name");
                b.add_string_value (roots[i, 0]);
                b.set_member_name ("path");
                b.add_string_value (roots[i, 1]);
                b.end_object ();
            }
            b.end_array ();
            b.set_member_name ("home-exclusions");
            b.begin_array ();
            string prefix = home.has_suffix ("/") ? home : home + "/";
            string root = installation ();
            if (root.has_prefix (prefix)) b.add_string_value ("/" + root.substring (prefix.length));
            b.end_array ();
            b.set_member_name ("warnings");
            b.begin_array ();
            foreach (string w in warnings) b.add_string_value (w);
            b.end_array ();
            b.end_object ();
            print_json (b.get_root ());
            return 0;
        }

        private int restore (string dir) {
            if (cpak == null) {
                stderr.printf ("%s\n", _("cpak is not installed, so the apps cannot be reinstalled"));
                return 1;
            }
            Json.Array saved;
            try {
                var parser = new Json.Parser ();
                parser.load_from_file (Path.build_filename (dir, "apps.json"));
                saved = parser.get_root ().get_array ();
            } catch (Error e) {
                stderr.printf ("%s\n", e.message);
                return 1;
            }
            var present = new Gee.HashSet<string> ();
            try {
                foreach (var n in list_apps ().get_elements ()) present.add (identity (n.get_object ()));
            } catch (Error e) {
                stderr.printf ("%s\n", e.message);
                return 1;
            }
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("installed");
            b.begin_array ();
            string[] failed = {};
            foreach (var n in saved.get_elements ()) {
                var o = n.get_object ();
                if (present.contains (identity (o))) continue;
                string[] args = { "install", "-y", member (o, "origin") };
                if (member (o, "release") != "") {
                    args += "--release";
                    args += member (o, "release");
                } else if (member (o, "commit") != "") {
                    args += "--commit";
                    args += member (o, "commit");
                } else if (member (o, "branch") != "") {
                    args += "--branch";
                    args += member (o, "branch");
                }
                try {
                    run_cpak (args, 3600);
                    b.add_string_value (member (o, "name"));
                } catch (Error e) {
                    failed += "%s (%s)".printf (member (o, "name"), e.message);
                }
            }
            b.end_array ();
            b.set_member_name ("failed");
            b.begin_array ();
            foreach (string f in failed) b.add_string_value (f);
            b.end_array ();
            b.end_object ();
            print_json (b.get_root ());
            return 0;
        }

        public static int main (string[] args) {
            Intl.setlocale (LocaleCategory.ALL, "");
            var source = new CpakSource ();
            if (args.length == 2 && args[1] == "check") return source.check ();
            if (args.length == 3 && args[1] == "backup") return source.backup (args[2]);
            if (args.length == 3 && args[1] == "restore") return source.restore (args[2]);
            stderr.printf ("usage: %s check | backup DIR | restore DIR\n", args[0]);
            return 2;
        }
    }
}
