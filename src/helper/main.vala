namespace Singularity.Backups {

    public class SystemHelper : Object {
        private static int fail (string message) {
            printerr ("%s\n", message);
            return 1;
        }

        private static void copy_tree (string source, string target) throws Error {
            Posix.Stat st;
            if (Posix.lstat (source, out st) != 0) throw new IOError.NOT_FOUND ("%s: %s", source, strerror (errno));
            if (Posix.S_ISDIR (st.st_mode)) {
                if (Posix.mkdir (target, (Posix.mode_t) (st.st_mode & 07777)) != 0 && errno != Posix.EEXIST) {
                    throw new IOError.FAILED ("%s: %s", target, strerror (errno));
                }
                var dir = Dir.open (source);
                string? name;
                while ((name = dir.read_name ()) != null) {
                    copy_tree (Path.build_filename (source, name), Path.build_filename (target, name));
                }
                Posix.chmod (target, (Posix.mode_t) (st.st_mode & 07777));
                return;
            }
            if (Posix.S_ISLNK (st.st_mode)) {
                string link = FileUtils.read_link (source);
                string tmp = target + ".restoring";
                FileUtils.unlink (tmp);
                if (Posix.symlink (link, tmp) != 0 || FileUtils.rename (tmp, target) != 0) {
                    throw new IOError.FAILED ("%s: %s", target, strerror (errno));
                }
                return;
            }
            if (!Posix.S_ISREG (st.st_mode)) return;
            uint8[] data;
            FileUtils.get_data (source, out data);
            string tmp = target + ".restoring";
            FileUtils.set_data (tmp, data);
            Posix.chmod (tmp, (Posix.mode_t) (st.st_mode & 07777));
            if (FileUtils.rename (tmp, target) != 0) {
                FileUtils.unlink (tmp);
                throw new IOError.FAILED ("%s: %s", target, strerror (errno));
            }
        }

        public static int main (string[] args) {
            if (args.length != 3 || args[1] != "restore-abroot") return fail ("usage: singularity-backups-system-helper restore-abroot SNAPSHOT/tree/abroot");
            string? real = Posix.realpath (args[2]);
            if (real == null || !real.has_suffix ("/tree/abroot")) return fail ("not a backup of the ABRoot configuration: " + args[2]);
            string snapshot = Path.get_dirname (Path.get_dirname (real));
            string manifest;
            try {
                FileUtils.get_contents (Path.build_filename (snapshot, "manifest.json"), out manifest);
            } catch (Error e) {
                return fail ("the backup has no manifest: " + e.message);
            }
            if (!manifest.contains ("\"complete\" : true") && !manifest.contains ("\"complete\": true")) return fail ("the backup is incomplete");
            if (!FileUtils.test (Path.build_filename (snapshot, "index"), FileTest.EXISTS)) return fail ("the backup has no index");
            string root = Environment.get_variable ("SINGULARITY_BACKUPS_SYSTEM_ROOT") ?? "/";
            if (root == "") root = "/";
            string target = Path.build_filename (root, "etc", "abroot");
            try {
                DirUtils.create_with_parents (Path.get_dirname (target), 0755);
                copy_tree (real, target);
            } catch (Error e) {
                return fail ("restore failed: " + e.message);
            }
            if (root == "/" && Environment.find_program_in_path ("abroot") != null) {
                int status;
                try {
                    Process.spawn_sync (null, { "abroot", "pkg", "sync" }, null, SpawnFlags.SEARCH_PATH, null, null, null, out status);
                } catch (Error e) {
                    return fail ("abroot pkg sync failed: " + e.message);
                }
                if (status != 0) return fail ("abroot pkg sync failed");
            }
            return 0;
        }
    }
}
