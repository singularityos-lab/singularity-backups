namespace Singularity.Backups {

    public delegate void WorkFunc () throws Error;

    public async void in_thread (owned WorkFunc func) throws Error {
        Error? failure = null;
        SourceFunc resume = in_thread.callback;
        new Thread<void> ("backups-worker", () => {
            try {
                func ();
            } catch (Error e) {
                failure = e;
            }
            Idle.add ((owned) resume);
        });
        yield;
        if (failure != null) throw failure;
    }

    public class StateFile : Object {
        public int64 last_success { get; set; default = 0; }
        public int64 last_failure { get; set; default = 0; }
        public string last_error { get; set; default = ""; }
        public string last_snapshot { get; set; default = ""; }

        private string file;

        public StateFile () {
            file = Path.build_filename (Environment.get_user_state_dir (), "singularity-backups", "state");
            var kf = new KeyFile ();
            try {
                kf.load_from_file (file, KeyFileFlags.NONE);
                last_success = kf.get_int64 ("State", "LastSuccess");
                last_failure = kf.get_int64 ("State", "LastFailure");
                last_error = kf.get_string ("State", "LastError");
                last_snapshot = kf.get_string ("State", "LastSnapshot");
            } catch (Error e) {
            }
        }

        public void save () {
            var kf = new KeyFile ();
            kf.set_int64 ("State", "LastSuccess", last_success);
            kf.set_int64 ("State", "LastFailure", last_failure);
            kf.set_string ("State", "LastError", last_error);
            kf.set_string ("State", "LastSnapshot", last_snapshot);
            try {
                DirUtils.create_with_parents (Path.get_dirname (file), 0700);
                FileUtils.set_contents (file, kf.to_data ());
            } catch (Error e) {
                warning ("Backups: cannot save state: %s", e.message);
            }
        }

        public void reset () {
            last_success = 0;
            last_failure = 0;
            last_error = "";
            last_snapshot = "";
            save ();
        }
    }

    public class Passphrases : Object {
        private static Secret.Schema schema () {
            return new Secret.Schema ("dev.sinty.backups.Disk", Secret.SchemaFlags.NONE,
                                      "uuid", Secret.SchemaAttributeType.STRING);
        }

        private static HashTable<string, string>? session = null;

        public static async bool store (string uuid, string passphrase) {
            if (session == null) session = new HashTable<string, string> (str_hash, str_equal);
            session[uuid] = passphrase;
            try {
                return yield Secret.password_store (schema (), Secret.COLLECTION_DEFAULT, _("Backup disk passphrase"), passphrase, null,
                                                    "uuid", uuid);
            } catch (Error e) {
                warning ("Backups: the passphrase is kept only until you log out: %s", e.message);
                return false;
            }
        }

        public static async string? lookup (string uuid) {
            if (session != null && session.contains (uuid)) return session[uuid];
            try {
                return yield Secret.password_lookup (schema (), null, "uuid", uuid);
            } catch (Error e) {
                return null;
            }
        }
    }

    public class Notifier : Object {
        private DBusConnection? bus;
        private uint32 last_id = 0;

        public signal void opened ();

        public Notifier (DBusConnection? bus) {
            this.bus = bus;
            if (bus == null) return;
            bus.signal_subscribe (null, "org.freedesktop.Notifications", "ActionInvoked", "/org/freedesktop/Notifications",
                null, DBusSignalFlags.NONE, (c, sender, path, iface, name, parameters) => {
                    uint32 id;
                    string action;
                    parameters.get ("(us)", out id, out action);
                    if (id == last_id && id != 0) opened ();
                });
        }

        public void send (string summary, string body, bool urgent) {
            if (bus == null) return;
            var hints = new VariantBuilder (new VariantType ("a{sv}"));
            hints.add ("{sv}", "desktop-entry", new Variant.string ("dev.sinty.backups"));
            hints.add ("{sv}", "urgency", new Variant.byte (urgent ? 2 : 1));
            string[] actions = { "default", _("Open Backups") };
            bus.call.begin ("org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications",
                "Notify", new Variant ("(susss@as@a{sv}i)", _("Backups"), last_id, "dev.sinty.backups", summary, body,
                                       new Variant.strv (actions), hints.end (), -1),
                new VariantType ("(u)"), DBusCallFlags.NONE, 5000, null, (o, res) => {
                    try {
                        var reply = bus.call.end (res);
                        reply.get ("(u)", out last_id);
                    } catch (Error e) {
                        debug ("Backups: notification not shown: %s", e.message);
                    }
                });
        }
    }

    public class Estimator : Object {
        public static bool walk (string dir, string rel, Exclusions ex, int64 deadline, ref uint64 bytes, ref uint64 files) {
            Dir handle;
            try {
                handle = Dir.open (dir);
            } catch (FileError e) {
                return true;
            }
            string? name;
            while ((name = handle.read_name ()) != null) {
                if (get_monotonic_time () > deadline) return false;
                string child = rel == "" ? name : rel + "/" + name;
                if (ex.excluded (child)) continue;
                string full = Path.build_filename (dir, name);
                Posix.Stat st;
                if (Posix.lstat (full, out st) != 0) continue;
                if (Posix.S_ISDIR (st.st_mode)) {
                    if (!walk (full, child, ex, deadline, ref bytes, ref files)) return false;
                } else if (Posix.S_ISREG (st.st_mode)) {
                    bytes += (uint64) st.st_size;
                    files++;
                }
            }
            return true;
        }
    }
}
