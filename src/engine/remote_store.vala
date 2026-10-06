namespace Singularity.Backups {

    public class RemoteObject : Object {
        public string key { get; set; default = ""; }
        public uint64 size { get; set; default = 0; }

        public RemoteObject (string key, uint64 size) {
            this.key = key;
            this.size = size;
        }
    }

    public interface RemoteStore : Object {
        public abstract string identity { owned get; }
        public abstract void put (string key, string file, Cancellable? cancellable, SealStep? step) throws Error;
        public abstract void fetch (string key, string file, Cancellable? cancellable) throws Error;
        public abstract Gee.List<RemoteObject> list (string prefix, Cancellable? cancellable) throws Error;
        public abstract void remove (string key) throws Error;
        public abstract void space (out uint64 used, out uint64 total) throws Error;

        public virtual void close () {
        }
    }

    public class FolderStore : Object, RemoteStore {
        private string root;

        public string identity { owned get { return "folder:" + root; } }

        public FolderStore (string root) {
            this.root = root;
        }

        private string path_of (string key) throws Error {
            if (key.has_prefix ("/") || key.contains ("..")) throw new BackupError.FAILED (_("Invalid name %s"), key);
            return Path.build_filename (root, key);
        }

        public void put (string key, string file, Cancellable? cancellable, SealStep? step) throws Error {
            string target = path_of (key);
            DirUtils.create_with_parents (Path.get_dirname (target), 0700);
            string tmp = target + ".part";
            var src = File.new_for_path (file);
            src.copy (File.new_for_path (tmp), FileCopyFlags.OVERWRITE, cancellable, null);
            if (FileUtils.rename (tmp, target) != 0) {
                FileUtils.unlink (tmp);
                throw new BackupError.FAILED (_("Cannot write %s: %s"), key, strerror (errno));
            }
            if (step != null) step (src.query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE).get_size ());
        }

        public void fetch (string key, string file, Cancellable? cancellable) throws Error {
            string source = path_of (key);
            if (!FileUtils.test (source, FileTest.IS_REGULAR)) throw new BackupError.NOT_FOUND (_("%s is missing from the backups"), key);
            File.new_for_path (source).copy (File.new_for_path (file), FileCopyFlags.OVERWRITE, cancellable, null);
        }

        public Gee.List<RemoteObject> list (string prefix, Cancellable? cancellable) throws Error {
            var result = new Gee.ArrayList<RemoteObject> ();
            string dir = path_of (prefix);
            collect (dir, prefix, result);
            return result;
        }

        private static void collect (string dir, string key, Gee.List<RemoteObject> result) {
            Dir handle;
            try {
                handle = Dir.open (dir);
            } catch (FileError e) {
                return;
            }
            string? name;
            while ((name = handle.read_name ()) != null) {
                if (name.has_suffix (".part")) continue;
                string full = Path.build_filename (dir, name);
                string child = key == "" ? name : key + "/" + name;
                Posix.Stat st;
                if (Posix.lstat (full, out st) != 0) continue;
                if (Posix.S_ISDIR (st.st_mode)) collect (full, child, result);
                else if (Posix.S_ISREG (st.st_mode)) result.add (new RemoteObject (child, (uint64) st.st_size));
            }
        }

        public void remove (string key) throws Error {
            FileUtils.unlink (path_of (key));
        }

        public void space (out uint64 used, out uint64 total) throws Error {
            used = 0;
            total = 0;
            Posix.statvfs v;
            if (Posix.statvfs_exec (root, out v) == 0) {
                total = (uint64) v.f_blocks * v.f_frsize;
                used = total - (uint64) v.f_bavail * v.f_frsize;
            }
        }
    }

    public class ExecStore : Object, RemoteStore {
        public const int PROTOCOL = 1;

        private string program;
        private string target;
        private Subprocess? process = null;
        private DataInputStream? reader = null;
        private OutputStream? writer = null;
        private Mutex mutex = Mutex ();
        public uint idle_timeout { get; set; default = 120; }

        public string identity { owned get { return "exec:%s:%s".printf (program, target); } }

        public ExecStore (string program, string target) {
            this.program = program;
            this.target = target;
        }

        private void start () throws Error {
            if (process != null) return;
            var launcher = new SubprocessLauncher (SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE);
            process = launcher.spawnv ({ program, "serve", target });
            reader = new DataInputStream (process.get_stdout_pipe ());
            writer = process.get_stdin_pipe ();
            var hello = new Json.Object ();
            hello.set_string_member ("op", "hello");
            hello.set_int_member ("protocol", PROTOCOL);
            var reply = exchange (hello, null, null);
            if (reply.get_int_member_with_default ("protocol", 0) != PROTOCOL) {
                stop ();
                throw new BackupError.UNSUPPORTED (_("The backup destination plugin speaks a different protocol"));
            }
        }

        private void stop () {
            if (process != null) process.force_exit ();
            process = null;
            reader = null;
            writer = null;
        }

        public void close () {
            mutex.lock ();
            if (process != null) {
                try {
                    writer.close ();
                } catch (Error e) {
                }
                stop ();
            }
            mutex.unlock ();
        }

        private static Error map_error (Json.Object o) {
            string code = o.get_string_member_with_default ("error", "failed");
            string message = o.get_string_member_with_default ("message", "");
            switch (code) {
                case "offline":
                    return new BackupError.UNAVAILABLE (message != "" ? message : _("The destination cannot be reached"));
                case "not-found":
                    return new BackupError.NOT_FOUND (message != "" ? message : _("Not found"));
                case "no-space":
                    return new BackupError.NO_SPACE (message != "" ? message : _("The destination is full"));
                case "auth":
                    return new BackupError.FAILED (message != "" ? message : _("Sign in to the account again"));
                case "unsupported":
                    return new BackupError.UNSUPPORTED (message != "" ? message : _("Not supported by the destination"));
                default:
                    return new BackupError.FAILED (message != "" ? message : _("The destination reported an error"));
            }
        }

        private Json.Object exchange (Json.Object request, Cancellable? cancellable, SealStep? step) throws Error {
            var gen = new Json.Generator ();
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (request);
            gen.root = node;
            string line = gen.to_data (null) + "\n";
            var watchdog = new Cancellable ();
            ulong link = 0;
            if (cancellable != null) link = cancellable.connect (() => watchdog.cancel ());
            int64 deadline = get_monotonic_time () + (int64) idle_timeout * 1000000;
            var ticking = true;
            var guard = new Thread<void> ("backups-watchdog", () => {
                while (ticking) {
                    Thread.usleep (200000);
                    if (deadline < get_monotonic_time ()) {
                        watchdog.cancel ();
                        break;
                    }
                }
            });
            try {
                writer.write_all (line.data, null, watchdog);
                writer.flush (watchdog);
                while (true) {
                    size_t length;
                    string? answer = reader.read_line_utf8 (out length, watchdog);
                    if (answer == null) throw new BackupError.UNAVAILABLE (_("The backup destination plugin stopped"));
                    deadline = get_monotonic_time () + (int64) idle_timeout * 1000000;
                    var parser = new Json.Parser ();
                    parser.load_from_data (answer);
                    var o = parser.get_root ().get_object ();
                    if (o.has_member ("progress")) {
                        if (step != null) step ((uint64) o.get_int_member ("progress"));
                        continue;
                    }
                    if (!o.get_boolean_member_with_default ("ok", false)) throw map_error (o);
                    return o;
                }
            } catch (IOError.CANCELLED e) {
                stop ();
                if (cancellable != null && cancellable.is_cancelled ()) throw new BackupError.CANCELLED (_("The backup was cancelled"));
                throw new BackupError.UNAVAILABLE (_("The backup destination stopped answering"));
            } catch (BackupError e) {
                throw e;
            } catch (Error e) {
                stop ();
                throw new BackupError.UNAVAILABLE (_("The backup destination plugin failed: %s"), e.message);
            } finally {
                ticking = false;
                guard.join ();
                if (link != 0) cancellable.disconnect (link);
            }
        }

        private Json.Object call (Json.Object request, Cancellable? cancellable, SealStep? step) throws Error {
            mutex.lock ();
            try {
                start ();
                return exchange (request, cancellable, step);
            } finally {
                mutex.unlock ();
            }
        }

        public void put (string key, string file, Cancellable? cancellable, SealStep? step) throws Error {
            var r = new Json.Object ();
            r.set_string_member ("op", "put");
            r.set_string_member ("key", key);
            r.set_string_member ("file", file);
            uint64 last = 0;
            call (r, cancellable, (sent) => {
                if (step != null && sent > last) step (sent - last);
                last = sent;
            });
        }

        public void fetch (string key, string file, Cancellable? cancellable) throws Error {
            var r = new Json.Object ();
            r.set_string_member ("op", "get");
            r.set_string_member ("key", key);
            r.set_string_member ("file", file);
            call (r, cancellable, null);
        }

        public Gee.List<RemoteObject> list (string prefix, Cancellable? cancellable) throws Error {
            var r = new Json.Object ();
            r.set_string_member ("op", "list");
            r.set_string_member ("prefix", prefix);
            var o = call (r, cancellable, null);
            var result = new Gee.ArrayList<RemoteObject> ();
            if (!o.has_member ("entries")) return result;
            foreach (var n in o.get_array_member ("entries").get_elements ()) {
                var e = n.get_object ();
                result.add (new RemoteObject (e.get_string_member_with_default ("key", ""), (uint64) e.get_int_member_with_default ("size", 0)));
            }
            return result;
        }

        public void remove (string key) throws Error {
            var r = new Json.Object ();
            r.set_string_member ("op", "delete");
            r.set_string_member ("key", key);
            try {
                call (r, null, null);
            } catch (BackupError.NOT_FOUND e) {
            }
        }

        public void space (out uint64 used, out uint64 total) throws Error {
            var r = new Json.Object ();
            r.set_string_member ("op", "space");
            var o = call (r, null, null);
            used = (uint64) o.get_int_member_with_default ("used", 0);
            total = (uint64) o.get_int_member_with_default ("total", 0);
        }
    }
}
