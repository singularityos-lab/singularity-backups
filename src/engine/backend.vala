namespace Singularity.Backups {

    public class SourceRoot : Object {
        public string path { get; construct; }
        public string prefix { get; construct; }
        public Exclusions? exclusions { get; construct; }

        public SourceRoot (string path, string prefix, Exclusions? exclusions) {
            Object (path: path, prefix: prefix, exclusions: exclusions);
        }
    }

    public interface Backend : Object {
        public abstract string id { owned get; }
        public abstract string location { owned get; }
        public abstract bool supports_dedup { get; }

        public abstract void open (string location) throws Error;
        public abstract Gee.List<SnapshotInfo> list_snapshots () throws Error;
        public abstract SnapshotInfo create_snapshot (BackupPlan plan, Gee.List<SourceRoot> roots,
                                                      Cancellable? cancellable, ProgressFunc progress) throws Error;
        public abstract Gee.List<Entry> list_directory (string snapshot, string path) throws Error;
        public abstract Entry? lookup (string snapshot, string path) throws Error;
        public abstract string materialize (string snapshot, string path, Cancellable? cancellable) throws Error;
        public abstract void restore (string snapshot, string path, string target, bool merge,
                                      Cancellable? cancellable) throws Error;
        public abstract void delete_snapshot (string snapshot) throws Error;
        public abstract VerifyResult verify (string snapshot, Cancellable? cancellable, ProgressFunc? progress) throws Error;
        public abstract RepoStats stats () throws Error;

        public virtual void prune (int keep_last) throws Error {
            if (keep_last <= 0) return;
            var all = list_snapshots ();
            for (int i = 0; i < all.size - keep_last; i++) delete_snapshot (all[i].id);
        }
    }

    public delegate Backend BackendFactory (string argument);

    public class BackendRegistry : Object {
        private static HashTable<string, BackendFactoryBox>? factories = null;

        private class BackendFactoryBox {
            public BackendFactory factory;

            public BackendFactoryBox (owned BackendFactory factory) {
                this.factory = (owned) factory;
            }
        }

        private static void ensure () {
            if (factories != null) return;
            factories = new HashTable<string, BackendFactoryBox> (str_hash, str_equal);
            register ("local", (arg) => new LocalBackend ());
            register ("exec", (arg) => new ExecBackend (arg));
        }

        public static void register (string name, owned BackendFactory factory) {
            ensure ();
            factories[name] = new BackendFactoryBox ((owned) factory);
        }

        public static Backend create (string spec) throws Error {
            ensure ();
            string name = spec.strip ();
            string argument = "";
            int colon = name.index_of_char (':');
            if (colon > 0) {
                argument = name.substring (colon + 1);
                name = name.substring (0, colon);
            }
            if (name == "") name = "local";
            var box = factories[name];
            if (box == null) throw new BackupError.UNSUPPORTED (_("The backup engine %s is not available on this system"), name);
            return box.factory (argument);
        }
    }
}
