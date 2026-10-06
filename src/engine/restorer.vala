namespace Singularity.Backups {

    public enum ConflictPolicy {
        REPLACE,
        KEEP_BOTH,
        SKIP;

        public static ConflictPolicy parse (string text) {
            if (text == "replace") return REPLACE;
            if (text == "skip") return SKIP;
            return KEEP_BOTH;
        }
    }

    public class Restorer : Object {
        public const string HOME_PREFIX = "userdata";

        private Backend backend;
        private string home;

        public Restorer (Backend backend, string home) {
            this.backend = backend;
            this.home = home;
        }

        public static string to_tree (string home_relative) {
            string p = home_relative;
            while (p.has_prefix ("/")) p = p.substring (1);
            while (p.has_suffix ("/")) p = p.substring (0, p.length - 1);
            return p == "" ? HOME_PREFIX : HOME_PREFIX + "/" + p;
        }

        public static string from_tree (string tree_path) {
            if (tree_path == HOME_PREFIX) return "";
            if (tree_path.has_prefix (HOME_PREFIX + "/")) return tree_path.substring (HOME_PREFIX.length + 1);
            return tree_path;
        }

        public string destination_for (string home_relative, string target_dir) {
            if (target_dir != "") return Path.build_filename (target_dir, Path.get_basename (home_relative));
            return home_relative == "" ? home : Path.build_filename (home, home_relative);
        }

        public string[] conflicts (string[] paths, string target_dir) {
            string[] found = {};
            foreach (string p in paths) {
                string dest = destination_for (p, target_dir);
                if (FileUtils.test (dest, FileTest.EXISTS) || FileUtils.test (dest, FileTest.IS_SYMLINK)) found += dest;
            }
            return found;
        }

        public static string unique_name (string dest) {
            string dir = Path.get_dirname (dest);
            string name = Path.get_basename (dest);
            string stem = name;
            string ext = "";
            int dot = name.last_index_of_char ('.');
            if (dot > 0 && name.length - dot <= 8) {
                stem = name.substring (0, dot);
                ext = name.substring (dot);
            }
            for (int i = 1; i < 1000; i++) {
                string candidate = i == 1 ? "%s (%s)%s".printf (stem, _("restored"), ext)
                                          : "%s (%s %d)%s".printf (stem, _("restored"), i, ext);
                string full = Path.build_filename (dir, candidate);
                if (!FileUtils.test (full, FileTest.EXISTS) && !FileUtils.test (full, FileTest.IS_SYMLINK)) return full;
            }
            return Path.build_filename (dir, "%s.%s%s".printf (stem, Uuid.string_random (), ext));
        }

        private static void move_aside (string dest) throws Error {
            var file = File.new_for_path (dest);
            try {
                file.trash (null);
                return;
            } catch (Error e) {
            }
            string aside = unique_name (dest).replace (_("restored"), _("replaced"));
            if (FileUtils.rename (dest, aside) != 0) {
                throw new BackupError.FAILED (_("Cannot move %s out of the way"), dest);
            }
        }

        public string[] restore (string snapshot, string[] paths, string target_dir, ConflictPolicy policy,
                                 Cancellable? cancellable) throws Error {
            string[] restored = {};
            string[] failed = {};
            foreach (string p in paths) {
                string tree = to_tree (p);
                if (backend.lookup (snapshot, tree) == null) {
                    failed += p;
                    continue;
                }
                string dest = destination_for (p, target_dir);
                bool exists = FileUtils.test (dest, FileTest.EXISTS) || FileUtils.test (dest, FileTest.IS_SYMLINK);
                if (exists) {
                    if (policy == ConflictPolicy.SKIP) continue;
                    if (policy == ConflictPolicy.REPLACE) move_aside (dest);
                    else dest = unique_name (dest);
                }
                DirUtils.create_with_parents (Path.get_dirname (dest), 0755);
                try {
                    backend.restore (snapshot, tree, dest, false, cancellable);
                    restored += dest;
                } catch (BackupError.CANCELLED e) {
                    throw e;
                } catch (Error e) {
                    failed += p;
                }
            }
            if (failed.length > 0 && restored.length == 0) {
                throw new BackupError.FAILED (ngettext ("%d item could not be restored", "%d items could not be restored",
                                                        failed.length), failed.length);
            }
            return restored;
        }
    }
}
