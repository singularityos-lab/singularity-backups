namespace Singularity.Backups {

    public enum Frequency {
        HOURLY,
        DAILY,
        WEEKLY,
        MANUAL;

        public static Frequency parse (string text) {
            switch (text) {
                case "daily": return DAILY;
                case "weekly": return WEEKLY;
                case "manual": return MANUAL;
                default: return HOURLY;
            }
        }

        public string to_string () {
            switch (this) {
                case DAILY: return "daily";
                case WEEKLY: return "weekly";
                case MANUAL: return "manual";
                default: return "hourly";
            }
        }

        public int64 interval () {
            switch (this) {
                case DAILY: return 86400;
                case WEEKLY: return 7 * 86400;
                case MANUAL: return 0;
                default: return 3600;
            }
        }
    }

    public class Schedule : Object {
        public const int64 RETRY_DELAY = 15 * 60;
        public const int64 START_DELAY = 5 * 60;

        public static int64 next_run (Frequency frequency, int64 last_success, int64 last_failure, int64 now) {
            if (frequency == Frequency.MANUAL) return 0;
            int64 due = last_success == 0 ? now : last_success + frequency.interval ();
            if (last_failure > last_success) due = int64.max (due, last_failure + RETRY_DELAY);
            return int64.max (due, now);
        }
    }

    public class SystemConfig : Object {
        public string backend { get; set; default = "local"; }
        public string[] providers { get; set; default = { "userdata", "flatpak", "abroot", "*" }; }
        public string[] default_exclusions { get; set; default = Exclusions.DEFAULTS; }
        public string repository_name { get; set; default = "Singularity Backups"; }
        public string system_helper { get; set; default = ""; }
        public string store { get; set; default = "auto"; }
        public string abroot_command { get; set; default = "abroot"; }
        public string[] destinations { get; set; default = { "*" }; }

        public static SystemConfig load (string[] files) {
            var config = new SystemConfig ();
            foreach (string file in files) {
                var kf = new KeyFile ();
                try {
                    kf.load_from_file (file, KeyFileFlags.NONE);
                } catch (Error e) {
                    continue;
                }
                try {
                    if (kf.has_key ("Backups", "Backend")) config.backend = kf.get_string ("Backups", "Backend").strip ();
                    if (kf.has_key ("Backups", "Providers")) config.providers = kf.get_string_list ("Backups", "Providers");
                    if (kf.has_key ("Backups", "DefaultExclusions")) config.default_exclusions = kf.get_string_list ("Backups", "DefaultExclusions");
                    if (kf.has_key ("Backups", "RepositoryName")) config.repository_name = kf.get_string ("Backups", "RepositoryName").strip ();
                    if (kf.has_key ("Backups", "Store")) config.store = kf.get_string ("Backups", "Store").strip ();
                    if (kf.has_key ("Backups", "ABRootCommand")) config.abroot_command = kf.get_string ("Backups", "ABRootCommand").strip ();
                    if (kf.has_key ("Backups", "Destinations")) config.destinations = kf.get_string_list ("Backups", "Destinations");
                    if (kf.has_key ("Backups", "SystemHelper")) config.system_helper = kf.get_string ("Backups", "SystemHelper").strip ();
                } catch (Error e) {
                    warning ("Backups: %s: %s", file, e.message);
                }
            }
            return config;
        }

        public bool offers (string provider) {
            foreach (string p in providers) if (p == provider || p == "*") return true;
            return false;
        }

        public bool offers_destination (string plugin) {
            foreach (string p in destinations) if (p == plugin || p == "*") return true;
            return false;
        }
    }
}
