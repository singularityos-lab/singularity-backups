namespace Singularity.Backups {

    public const string DAEMON_NAME = "dev.sinty.backups.Daemon";
    public const string DAEMON_PATH = "/dev/sinty/backups/Daemon";

    [DBus (name = "dev.sinty.backups.Daemon1")]
    public interface DaemonProxy : Object {
        public abstract string state { owned get; }
        public abstract double fraction { get; }
        public abstract string phase { owned get; }
        public abstract string current_item { owned get; }
        public abstract int64 last_backup { get; }
        public abstract int64 next_backup { get; }
        public abstract string last_error { owned get; }
        public abstract bool configured { get; }
        public abstract string destination_name { owned get; }

        public signal void progress (double fraction, string phase, string item);
        public signal void finished (string snapshot);
        public signal void failed (string message);
        public signal void snapshots_changed ();

        public abstract void back_up_now () throws Error;
        public abstract void cancel () throws Error;
        public abstract async HashTable<string, Variant> get_status () throws Error;
        public abstract async HashTable<string, Variant>[] list_snapshots () throws Error;
        public abstract async HashTable<string, Variant>[] list_directory (string snapshot, string path) throws Error;
        public abstract async string get_file (string snapshot, string path) throws Error;
        public abstract async HashTable<string, Variant>[] versions (string path) throws Error;
        public abstract async string[] check_restore (string snapshot, string[] paths, string target) throws Error;
        public abstract async string[] restore (string snapshot, string[] paths, string target, string policy) throws Error;
        public abstract async void restore_all (string snapshot, string[] providers) throws Error;
        public abstract async HashTable<string, Variant> verify (string snapshot) throws Error;
        public abstract async void delete_snapshot (string snapshot) throws Error;
        public abstract async HashTable<string, Variant>[] list_providers () throws Error;
        public abstract async HashTable<string, Variant>[] list_remote_destinations () throws Error;
        public abstract async HashTable<string, Variant> inspect_remote (string plugin, string target) throws Error;
        public abstract async HashTable<string, Variant> estimate () throws Error;
        public abstract async HashTable<string, Variant> set_remote_destination (string plugin, string target, string name, string repository,
                                                                                 string passphrase) throws Error;
        public abstract async HashTable<string, Variant>[] list_destinations () throws Error;
        public abstract async HashTable<string, Variant> set_destination (string kind, string target, string name, bool encrypted) throws Error;
        public abstract void forget_destination () throws Error;
        public abstract async string prepare_disk (string object_path, string label, string passphrase) throws Error;
        public abstract async bool remember_passphrase (string uuid, string passphrase) throws Error;
    }

    public static string error_text (Error e) {
        string m = e.message;
        if (e is DBusError || e is IOError) {
            string? remote = DBusError.get_remote_error (e);
            if (remote != null) DBusError.strip_remote_error (e);
            m = e.message;
            int colon = m.index_of (": ");
            if (m.has_prefix ("GDBus.Error:") && colon > 0) m = m.substring (colon + 2);
        }
        if (m.has_prefix ("GDBus.Error:")) {
            int colon = m.index_of (": ");
            if (colon > 0) m = m.substring (colon + 2);
        }
        return m;
    }

    public static string get_str (HashTable<string, Variant> t, string key, string fallback = "") {
        var v = t[key];
        if (v == null) return fallback;
        if (v.is_of_type (VariantType.STRING)) return v.get_string ();
        if (v.is_of_type (VariantType.BYTESTRING)) return v.get_bytestring ();
        return fallback;
    }

    public static int64 get_int (HashTable<string, Variant> t, string key, int64 fallback = 0) {
        var v = t[key];
        if (v == null) return fallback;
        if (v.is_of_type (VariantType.INT64)) return v.get_int64 ();
        if (v.is_of_type (VariantType.INT32)) return v.get_int32 ();
        if (v.is_of_type (VariantType.UINT32)) return v.get_uint32 ();
        return fallback;
    }

    public static uint64 get_u64 (HashTable<string, Variant> t, string key) {
        var v = t[key];
        if (v == null) return 0;
        if (v.is_of_type (VariantType.UINT64)) return v.get_uint64 ();
        if (v.is_of_type (VariantType.INT64)) return (uint64) v.get_int64 ();
        return 0;
    }

    public static bool get_bool (HashTable<string, Variant> t, string key, bool fallback = false) {
        var v = t[key];
        if (v == null || !v.is_of_type (VariantType.BOOLEAN)) return fallback;
        return v.get_boolean ();
    }

    public static string[] get_strv (HashTable<string, Variant> t, string key) {
        var v = t[key];
        if (v == null || !v.is_of_type (VariantType.STRING_ARRAY)) return {};
        return v.dup_strv ();
    }

    public static string relative_time (int64 when) {
        if (when <= 0) return _("Never");
        var then = new DateTime.from_unix_local (when);
        var now = new DateTime.now_local ();
        int64 diff = now.to_unix () - when;
        string time = then.format ("%H:%M");
        if (diff >= 0 && diff < 60) return _("Just now");
        if (diff >= 0 && diff < 3600) {
            int m = (int) (diff / 60);
            return ngettext ("%d minute ago", "%d minutes ago", m).printf (m);
        }
        if (diff < 0 && diff > -3600) {
            int m = (int) ((-diff + 59) / 60);
            return ngettext ("In %d minute", "In %d minutes", m).printf (m);
        }
        int day_diff = now.get_day_of_year () - then.get_day_of_year () + (now.get_year () - then.get_year ()) * 365;
        if (day_diff == 0) return _("Today, %s").printf (time);
        if (day_diff == 1) return _("Yesterday, %s").printf (time);
        if (day_diff == -1) return _("Tomorrow, %s").printf (time);
        if (day_diff > 1 && day_diff < 7) return "%s, %s".printf (then.format ("%A"), time);
        if (now.get_year () == then.get_year ()) return "%s, %s".printf (then.format ("%e %B").strip (), time);
        return "%s, %s".printf (then.format ("%e %B %Y").strip (), time);
    }
}
