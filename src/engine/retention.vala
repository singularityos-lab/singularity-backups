namespace Singularity.Backups {

    public enum RetentionMode {
        SMART,
        KEEP_LAST;

        public static RetentionMode parse (string text) {
            return text == "keep-last" ? KEEP_LAST : SMART;
        }

        public string to_string () {
            return this == KEEP_LAST ? "keep-last" : "smart";
        }
    }

    public class Retention : Object {
        public const int64 HOURLY_SPAN = 24 * 3600;
        public const int64 DAILY_SPAN = 30 * 86400;

        public static Gee.Set<string> keep_smart (Gee.List<SnapshotInfo> snapshots, int64 now, TimeZone zone) {
            var kept = new Gee.HashSet<string> ();
            if (snapshots.size == 0) return kept;
            var sorted = new Gee.ArrayList<SnapshotInfo> ();
            sorted.add_all (snapshots);
            sorted.sort ((a, b) => {
                if (a.created != b.created) return a.created < b.created ? -1 : 1;
                return strcmp (a.id, b.id);
            });
            kept.add (sorted[sorted.size - 1].id);
            var buckets = new Gee.HashSet<string> ();
            foreach (var s in sorted) {
                string? bucket = bucket_for (s.created, now, zone);
                if (bucket == null) {
                    kept.add (s.id);
                    continue;
                }
                if (buckets.add (bucket)) kept.add (s.id);
            }
            return kept;
        }

        public static string? bucket_for (int64 created, int64 now, TimeZone zone) {
            int64 age = now - created;
            if (age < 0) return null;
            var t = new DateTime.from_unix_utc (created).to_timezone (zone);
            if (age < HOURLY_SPAN) return t.format ("h%Y%m%d%H");
            if (age < DAILY_SPAN) return t.format ("d%Y%m%d");
            return "w%04d%02d".printf (t.get_week_numbering_year (), t.get_week_of_year ());
        }

        public static Gee.List<string> doomed (Gee.List<SnapshotInfo> snapshots, RetentionMode mode, int keep_last,
                                               int64 now, TimeZone zone) {
            var result = new Gee.ArrayList<string> ();
            if (mode == RetentionMode.KEEP_LAST) {
                if (keep_last <= 0) return result;
                for (int i = 0; i < snapshots.size - keep_last; i++) result.add (snapshots[i].id);
                return result;
            }
            var kept = keep_smart (snapshots, now, zone);
            foreach (var s in snapshots) if (!kept.contains (s.id)) result.add (s.id);
            return result;
        }
    }

    public class PauseGate : Object {
        private Mutex mutex = Mutex ();
        private Cond cond = Cond ();
        private bool paused = false;

        public bool is_paused {
            get {
                mutex.lock ();
                bool p = paused;
                mutex.unlock ();
                return p;
            }
        }

        public void pause () {
            mutex.lock ();
            paused = true;
            mutex.unlock ();
        }

        public void resume () {
            mutex.lock ();
            paused = false;
            cond.broadcast ();
            mutex.unlock ();
        }

        public bool wait (Cancellable? cancellable) {
            bool waited = false;
            mutex.lock ();
            while (paused && (cancellable == null || !cancellable.is_cancelled ())) {
                waited = true;
                cond.wait_until (mutex, get_monotonic_time () + 200000);
            }
            mutex.unlock ();
            return waited;
        }
    }

    public class BatteryPolicy : Object {
        public const int HYSTERESIS = 5;

        public static bool should_pause (bool enabled, bool paused_now, bool on_battery, double percent, int threshold) {
            if (!enabled || !on_battery || percent < 0) return false;
            if (paused_now) return percent < threshold + HYSTERESIS;
            return percent < threshold;
        }
    }
}
