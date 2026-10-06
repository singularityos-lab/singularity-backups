namespace Singularity.Backups {

    private class Busy : Object {
        public Busy () {
            var app = GLib.Application.get_default ();
            if (app != null) app.hold ();
        }

        ~Busy () {
            var app = GLib.Application.get_default ();
            if (app != null) app.release ();
        }
    }

    [DBus (name = "dev.sinty.backups.Daemon1")]
    public class DaemonService : Object {
        private string _state = "idle";
        public string state { owned get { return _state; } }
        private double _fraction = 0;
        public double fraction { get { return _fraction; } }
        private string _phase = "";
        public string phase { owned get { return _phase; } }
        private string _current_item = "";
        public string current_item { owned get { return _current_item; } }
        private int64 _last_backup = 0;
        public int64 last_backup { get { return _last_backup; } }
        private int64 _next_backup = 0;
        public int64 next_backup { get { return _next_backup; } }
        private string _last_error = "";
        public string last_error { owned get { return _last_error; } }
        private bool _configured = false;
        public bool configured { get { return _configured; } }
        private string _destination_name = "";
        public string destination_name { owned get { return _destination_name; } }

        public signal void progress (double fraction, string phase, string item);
        public signal void finished (string snapshot);
        public signal void failed (string message);
        public signal void snapshots_changed ();

        private GLib.Settings settings;
        private SystemConfig sysconf;
        private Destinations dests = new Destinations ();
        private StateFile store = new StateFile ();
        private Notifier notifier;
        private Backend? backend = null;
        private string backend_repo = "";
        private Cancellable? job = null;
        private uint timer = 0;
        private uint poll = 0;
        private bool first_schedule = true;
        private bool running = false;
        private bool udisks_pending = true;
        private string helper_path;
        private PowerSource power = new PowerSource ();
        private PauseGate? gate = null;
        private bool job_manual = false;
        private bool power_ready = false;

        [DBus (visible = false)]
        public signal void keep_alive (bool needed);

        [DBus (visible = false)]
        public signal void open_app ();

        [DBus (visible = false)]
        public DaemonService (DBusConnection? bus, string[] config_files, string helper_path) {
            this.helper_path = helper_path;
            settings = new GLib.Settings ("dev.sinty.backups");
            sysconf = SystemConfig.load (config_files);
            dests.repository_name = sysconf.repository_name;
            notifier = new Notifier (bus);
            notifier.opened.connect (() => open_app ());
            dests.changed.connect (() => {
                if (state == "waiting") try_waiting ();
            });
            settings.changed.connect ((key) => {
                if (key.has_prefix ("destination-")) {
                    drop_backend ();
                    refresh_configured ();
                }
                if (key == "frequency" || key.has_prefix ("destination-")) reschedule ();
                if (key == "pause-on-battery" || key == "battery-threshold") on_power ();
            });
            power.changed.connect (on_power);
            power.start.begin ((o, r) => {
                power.start.end (r);
                power_ready = true;
            });
            put_last_backup (store.last_success);
            put_last_error (store.last_error);
            refresh_configured ();
            if (bus != null) {
                connection = bus;
                notify.connect (on_notify);
            }
            dests.connect_udisks.begin ((o, r) => {
                dests.connect_udisks.end (r);
                udisks_pending = false;
                reschedule ();
            });
        }

        private DBusConnection? connection = null;
        private HashTable<string, Variant>? pending_changes = null;

        private void on_notify (ParamSpec pspec) {
            string[] exported = { "state", "fraction", "phase", "current-item", "last-backup", "next-backup",
                                  "last-error", "configured", "destination-name" };
            if (!(pspec.name in exported)) return;
            var value = Value (pspec.value_type);
            get_property (pspec.name, ref value);
            Variant v;
            if (pspec.value_type == typeof (string)) v = new Variant.string (value.get_string () ?? "");
            else if (pspec.value_type == typeof (double)) v = new Variant.double (value.get_double ());
            else if (pspec.value_type == typeof (int64)) v = new Variant.int64 (value.get_int64 ());
            else if (pspec.value_type == typeof (bool)) v = new Variant.boolean (value.get_boolean ());
            else return;
            string dbus_name = "";
            foreach (string part in pspec.name.split ("-")) dbus_name += part.substring (0, 1).up () + part.substring (1);
            bool schedule = pending_changes == null;
            if (schedule) pending_changes = new HashTable<string, Variant> (str_hash, str_equal);
            pending_changes[dbus_name] = v;
            if (schedule) Idle.add (flush_changes);
        }

        private bool flush_changes () {
            var changes = pending_changes;
            pending_changes = null;
            if (changes == null || connection == null) return Source.REMOVE;
            var dict = new VariantBuilder (VariantType.VARDICT);
            changes.foreach ((k, v) => dict.add ("{sv}", k, v));
            try {
                connection.emit_signal (null, "/dev/sinty/backups/Daemon", "org.freedesktop.DBus.Properties", "PropertiesChanged",
                    new Variant ("(sa{sv}as)", "dev.sinty.backups.Daemon1", dict, new VariantBuilder (new VariantType ("as"))));
            } catch (Error e) {
                warning ("Backups: %s", e.message);
            }
            return Source.REMOVE;
        }

        private void put_state (string value) {
            if (_state == value) return;
            _state = value;
            notify_property ("state");
        }

        private void put_fraction (double value) {
            if (_fraction == value) return;
            _fraction = value;
            notify_property ("fraction");
        }

        private void put_phase (string value) {
            if (_phase == value) return;
            _phase = value;
            notify_property ("phase");
        }

        private void put_current_item (string value) {
            if (_current_item == value) return;
            _current_item = value;
            notify_property ("current-item");
        }

        private void put_last_backup (int64 value) {
            if (_last_backup == value) return;
            _last_backup = value;
            notify_property ("last-backup");
        }

        private void put_next_backup (int64 value) {
            if (_next_backup == value) return;
            _next_backup = value;
            notify_property ("next-backup");
        }

        private void put_last_error (string value) {
            if (_last_error == value) return;
            _last_error = value;
            notify_property ("last-error");
        }

        private void put_configured (bool value) {
            if (_configured == value) return;
            _configured = value;
            notify_property ("configured");
        }

        private void put_destination_name (string value) {
            if (_destination_name == value) return;
            _destination_name = value;
            notify_property ("destination-name");
        }

        private void refresh_configured () {
            string kind = settings.get_string ("destination-kind");
            if (kind == "plugin") put_configured (settings.get_string ("destination-plugin") != "" && settings.get_string ("destination-target") != "");
            else put_configured (kind == "disk" ? settings.get_string ("destination-id") != ""
                                        : (kind == "folder" || kind == "network" || kind == "cloud") && settings.get_string ("destination-path") != "");
            put_destination_name (settings.get_string ("destination-name"));
            if (!running) {
                if (!configured) put_state ("unconfigured");
                else if (state == "unconfigured") put_state ("idle");
            }
        }

        private Frequency frequency () {
            return Frequency.parse (settings.get_string ("frequency"));
        }

        private void reschedule () {
            if (timer != 0) Source.remove (timer);
            timer = 0;
            if (!configured || running) {
                put_next_backup (0);
                keep_alive (configured && frequency () != Frequency.MANUAL);
                return;
            }
            var freq = frequency ();
            int64 now = new DateTime.now_utc ().to_unix ();
            int64 next = Schedule.next_run (freq, store.last_success, store.last_failure, now);
            if (next == 0) {
                put_next_backup (0);
                keep_alive (false);
                return;
            }
            if (first_schedule && next <= now) next = now + int64.max (0, settings.get_int ("start-delay"));
            first_schedule = false;
            put_next_backup (next);
            keep_alive (true);
            uint wait = (uint) (next - now).clamp (0, 86400);
            timer = Timeout.add_seconds (wait, () => {
                timer = 0;
                int64 t = new DateTime.now_utc ().to_unix ();
                if (t < next_backup) {
                    reschedule ();
                    return Source.REMOVE;
                }
                run_backup.begin (false);
                return Source.REMOVE;
            });
        }

        private void try_waiting () {
            if (running || state != "waiting") return;
            run_backup.begin (false);
        }

        private bool battery_low (bool paused_now) {
            return BatteryPolicy.should_pause (settings.get_boolean ("pause-on-battery"), paused_now, power.on_battery,
                                               power.percent, settings.get_int ("battery-threshold"));
        }

        private void on_power () {
            if (running && gate != null && !job_manual) {
                bool low = battery_low (gate.is_paused);
                if (low && !gate.is_paused) {
                    gate.pause ();
                    put_state ("paused");
                    set_progress (fraction, "battery", "");
                } else if (!low && gate.is_paused) {
                    gate.resume ();
                    put_state ("backing-up");
                }
                return;
            }
            if (!running && state == "paused" && !battery_low (true)) run_backup.begin (false);
        }

        private void start_polling () {
            if (poll != 0) return;
            poll = Timeout.add_seconds (60, () => {
                if (state != "waiting") {
                    poll = 0;
                    return Source.REMOVE;
                }
                try_waiting ();
                return Source.CONTINUE;
            });
        }

        private async string resolve_base () throws Error {
            string kind = settings.get_string ("destination-kind");
            if (kind == "disk") {
                string uuid = settings.get_string ("destination-id");
                string? pass = null;
                var disk = dests.disk_for_uuid (uuid);
                if (disk != null && disk.encrypted && disk.locked) pass = yield Passphrases.lookup (uuid);
                return yield dests.mount_disk (uuid, pass);
            }
            if (kind == "folder" || kind == "network" || kind == "cloud") {
                string path = settings.get_string ("destination-path");
                if (kind == "cloud" && !FileUtils.test (path, FileTest.IS_DIR)) yield Destinations.start_cloud_mount (path);
                if (!FileUtils.test (path, FileTest.IS_DIR)) {
                    string label = settings.get_string ("destination-name");
                    if (label == "") label = Path.get_basename (path);
                    if (kind == "cloud") throw new BackupError.UNAVAILABLE (_("The online account “%s” is not connected"), label);
                    if (kind == "network") throw new BackupError.UNAVAILABLE (_("The network share “%s” is not connected"), label);
                    throw new BackupError.UNAVAILABLE (_("The folder “%s” is not available"), label);
                }
                return path;
            }
            throw new BackupError.UNAVAILABLE (_("Choose where to keep your backups first"));
        }

        private string remote_repository (string repository) {
            string name = repository != "" ? repository : "%s@%s".printf (Environment.get_user_name (), Environment.get_host_name ());
            return sysconf.repository_name + "/" + name;
        }

        private static string passphrase_key (string plugin, string target, string repository) {
            return "remote:%s:%s:%s".printf (plugin, target, repository);
        }

        private DestinationPlugin find_destination_plugin (string plugin) throws Error {
            var m = sysconf.offers_destination (plugin) ? PluginRegistry.find (PluginKind.DESTINATION, plugin) : null;
            if (m == null) throw new BackupError.UNAVAILABLE (_("The backup destination “%s” is not installed"), plugin);
            return new DestinationPlugin (m);
        }

        private string remote_cache () {
            return Path.build_filename (Environment.get_user_cache_dir (), "singularity-backups", "remote");
        }

        private void drop_backend () {
            var remote = backend as RemoteBackend;
            if (remote != null) remote.close ();
            backend = null;
            backend_repo = "";
        }

        private async Backend open_remote (string plugin, string target, string repository, string? passphrase) throws Error {
            var dp = find_destination_plugin (plugin);
            var remote = new RemoteBackend (dp.open_store (target), remote_cache (), passphrase);
            string prefix = remote_repository (repository);
            try {
                yield in_thread (() => remote.open (prefix));
            } catch (Error e) {
                remote.close ();
                throw e;
            }
            return remote;
        }

        private async Backend ensure_backend () throws Error {
            if (settings.get_string ("destination-kind") == "plugin") {
                string plugin = settings.get_string ("destination-plugin");
                string target = settings.get_string ("destination-target");
                string repository = settings.get_string ("destination-repository");
                string id = "%s|%s|%s".printf (plugin, target, repository);
                if (backend != null && backend_repo == id) return backend;
                drop_backend ();
                string? pass = yield Passphrases.lookup (passphrase_key (plugin, target, repository));
                var b = yield open_remote (plugin, target, repository, pass);
                backend = b;
                backend_repo = id;
                return b;
            }
            string base_path = yield resolve_base ();
            string repo = dests.repository_in (base_path);
            if (backend != null && backend_repo == repo && FileUtils.test (repo, FileTest.IS_DIR)) return backend;
            var b = create_backend ();
            yield in_thread (() => {
                if (DirUtils.create_with_parents (repo, 0700) != 0) {
                    throw new BackupError.UNAVAILABLE (_("Cannot write to %s"), base_path);
                }
                b.open (repo);
            });
            backend = b;
            backend_repo = repo;
            return b;
        }

        private Backend create_backend () throws Error {
            var b = BackendRegistry.create (sysconf.backend);
            var local = b as LocalBackend;
            if (local != null) local.requested_store = sysconf.store;
            return b;
        }

        private BackupPlan make_plan (string label) {
            var plan = new BackupPlan ();
            plan.source_home = Environment.get_home_dir ();
            string[] providers = {};
            foreach (string p in settings.get_strv ("providers")) if (sysconf.offers (p)) providers += p;
            plan.providers = providers;
            plan.exclusions = settings.get_user_value ("exclusions") == null ? sysconf.default_exclusions : settings.get_strv ("exclusions");
            plan.deduplicate = settings.get_boolean ("deduplicate");
            plan.keep_last = settings.get_int ("keep-last");
            plan.retention = RetentionMode.parse (settings.get_string ("retention"));
            plan.host = Environment.get_host_name ();
            plan.label = label;
            plan.system_helper = sysconf.system_helper != "" ? sysconf.system_helper : helper_path;
            plan.abroot_command = sysconf.abroot_command;
            string root = Environment.get_variable ("SINGULARITY_BACKUPS_SYSTEM_ROOT");
            if (root != null && root != "") plan.system_root = root;
            return plan;
        }

        private void set_progress (double f, string p, string item) {
            put_fraction (f);
            if (phase != p) put_phase (p);
            put_current_item (item);
            progress (f, p, item);
        }

        private async void run_backup (bool manual) {
            if (running) return;
            for (int i = 0; i < 50 && !power_ready; i++) {
                Timeout.add (100, run_backup.callback);
                yield;
            }
            if (running) return;
            if (!manual && battery_low (false)) {
                if (timer != 0) Source.remove (timer);
                timer = 0;
                put_next_backup (0);
                put_state ("paused");
                set_progress (0, "battery", "");
                keep_alive (true);
                return;
            }
            var busy = new Busy ();
            running = true;
            job_manual = manual;
            gate = new PauseGate ();
            if (timer != 0) Source.remove (timer);
            timer = 0;
            put_next_backup (0);
            put_state ("backing-up");
            set_progress (0, "preparing", "");
            job = new Cancellable ();
            var cancellable = job;
            string staging = Path.build_filename (Environment.get_user_cache_dir (), "singularity-backups", "staging");
            SnapshotInfo? result = null;
            try {
                var b = yield ensure_backend ();
                var plan = make_plan (manual ? "manual" : "automatic");
                plan.gate = gate;
                var roots = new Gee.ArrayList<SourceRoot> ();
                string repo = backend_repo;
                yield in_thread (() => {
                    LocalBackend.remove_tree (staging);
                    DirUtils.create_with_parents (staging, 0700);
                    string[] notes = {};
                    string[] ordered = {};
                    foreach (string id in plan.providers) if (id != "userdata") ordered += id;
                    if ("userdata" in plan.providers) ordered += "userdata";
                    var all = Providers.all ();
                    foreach (string id in ordered) {
                        Provider? provider = null;
                        foreach (var p in all) if (p.id == id) provider = p;
                        if (provider == null || !provider.available (plan)) continue;
                        try {
                            var root = provider.prepare (plan, staging, repo);
                            if (root != null) roots.add (root);
                            foreach (var extra in provider.data_roots (plan)) roots.add (extra);
                            var plugin = provider as PluginProvider;
                            if (plugin != null) {
                                string[] ex = plan.exclusions;
                                foreach (string x in plugin.home_exclusions) ex += x;
                                plan.exclusions = ex;
                                foreach (string w in plugin.warnings) notes += "%s: %s".printf (provider.title, w);
                            }
                        } catch (Error e) {
                            if (id == "userdata") throw e;
                            notes += _("Skipped %s: %s").printf (provider.title, e.message);
                        }
                    }
                    plan.notes = notes;
                    result = b.create_snapshot (plan, roots, cancellable, (f, p, item) => {
                        string ph = p;
                        string it = item;
                        Idle.add (() => {
                            if (running) set_progress (f, ph == "paused" ? "battery" : ph, it);
                            return Source.REMOVE;
                        });
                    });
                    LocalBackend.remove_tree (staging);
                });
                store.last_success = new DateTime.now_utc ().to_unix ();
                store.last_error = "";
                store.last_snapshot = result.id;
                store.save ();
                put_last_backup (store.last_success);
                put_last_error ("");
                running = false;
                gate = null;
                put_state ("idle");
                set_progress (1, "done", "");
                finished (result.id);
                snapshots_changed ();
                if (manual && settings.get_boolean ("notify-completed")) {
                    string body = _("Your files are backed up to %s").printf (destination_name);
                    int n = result.warnings.length;
                    if (n > 0) body = ngettext ("Finished with %d warning. Open Backups for details.", "Finished with %d warnings. Open Backups for details.", n).printf (n);
                    notifier.send (_("Backup Complete"), body, false);
                }
            } catch (Error e) {
                running = false;
                gate = null;
                LocalBackend.remove_tree (staging);
                if (e is BackupError.CANCELLED) {
                    put_state ("idle");
                    set_progress (0, "cancelled", "");
                } else if (e is BackupError.UNAVAILABLE && !manual) {
                    put_state ("waiting");
                    put_last_error (e.message);
                    set_progress (0, "waiting", "");
                    start_polling ();
                    job = null;
                    return;
                } else {
                    store.last_failure = new DateTime.now_utc ().to_unix ();
                    store.last_error = e.message;
                    store.save ();
                    put_last_error (e.message);
                    put_state ("error");
                    set_progress (0, "failed", "");
                    failed (e.message);
                    notifier.send (_("Backup Failed"), e.message, true);
                }
            }
            job = null;
            reschedule ();
        }

        public void back_up_now () throws Error {
            if (!configured) throw new BackupError.UNAVAILABLE (_("Choose where to keep your backups first"));
            if (running) throw new BackupError.BUSY (_("A backup is already running"));
            run_backup.begin (true);
        }

        public void cancel () throws Error {
            if (job != null) job.cancel ();
            if (!running && state == "paused") {
                put_state (configured ? "idle" : "unconfigured");
                set_progress (0, "cancelled", "");
                reschedule ();
            }
        }

        public async HashTable<string, Variant> get_status () throws Error {
            var busy = new Busy ();
            var r = new HashTable<string, Variant> (str_hash, str_equal);
            r["state"] = state;
            r["fraction"] = fraction;
            r["phase"] = phase;
            r["last-backup"] = last_backup;
            r["next-backup"] = next_backup;
            r["last-error"] = last_error;
            r["configured"] = configured;
            r["destination-kind"] = settings.get_string ("destination-kind");
            r["destination-name"] = destination_name;
            r["destination-path"] = settings.get_string ("destination-path");
            r["frequency"] = settings.get_string ("frequency");
            r["keep-last"] = settings.get_int ("keep-last");
            r["retention"] = settings.get_string ("retention");
            r["engine"] = sysconf.backend;
            r["power-backend"] = power.backend;
            r["on-battery"] = power.on_battery;
            r["battery-percent"] = power.percent;
            r["available"] = false;
            r["destination-plugin"] = settings.get_string ("destination-plugin");
            r["destination-repository"] = settings.get_string ("destination-repository");
            if (!configured) return r;
            try {
                var b = yield ensure_backend ();
                RepoStats? stats = null;
                int count = 0;
                yield in_thread (() => {
                    stats = b.stats ();
                    count = b.list_snapshots ().size;
                });
                r["available"] = true;
                r["used"] = stats.used;
                r["free"] = stats.free;
                r["capacity"] = stats.capacity;
                r["incremental"] = stats.links;
                r["store"] = stats.store;
                r["encrypted"] = stats.encrypted;
                r["snapshots"] = count;
                r["repository"] = backend_repo;
            } catch (Error e) {
                r["unavailable-reason"] = e.message;
                r["needs-passphrase"] = e is BackupError.PASSPHRASE;
            }
            return r;
        }

        public async HashTable<string, Variant>[] list_snapshots () throws Error {
            var busy = new Busy ();
            var b = yield ensure_backend ();
            Gee.List<SnapshotInfo>? list = null;
            yield in_thread (() => {
                list = b.list_snapshots ();
            });
            HashTable<string, Variant>[] result = {};
            foreach (var s in list) result += to_table (s.to_variant ());
            return result;
        }

        private static HashTable<string, Variant> to_table (Variant dict) {
            var t = new HashTable<string, Variant> (str_hash, str_equal);
            var iter = dict.iterator ();
            string key;
            Variant value;
            while (iter.next ("{sv}", out key, out value)) t[key] = value;
            return t;
        }

        public async HashTable<string, Variant>[] list_directory (string snapshot, string path) throws Error {
            var busy = new Busy ();
            var b = yield ensure_backend ();
            Gee.List<Entry>? list = null;
            yield in_thread (() => {
                list = b.list_directory (snapshot, Restorer.to_tree (path));
            });
            HashTable<string, Variant>[] result = {};
            foreach (var e in list) {
                var home_entry = e.copy ();
                home_entry.path = Restorer.from_tree (e.path);
                result += to_table (home_entry.to_variant ());
            }
            return result;
        }

        public async string get_file (string snapshot, string path) throws Error {
            var busy = new Busy ();
            var b = yield ensure_backend ();
            string result = "";
            yield in_thread (() => {
                result = b.materialize (snapshot, Restorer.to_tree (path), null);
            });
            return result;
        }

        public async HashTable<string, Variant>[] versions (string path) throws Error {
            var busy = new Busy ();
            var b = yield ensure_backend ();
            var found = new Gee.ArrayList<Variant> ();
            yield in_thread (() => {
                Entry? last = null;
                foreach (var s in b.list_snapshots ()) {
                    var e = b.lookup (s.id, Restorer.to_tree (path));
                    if (e == null) {
                        last = null;
                        continue;
                    }
                    if (last != null && last.same_content (e)) continue;
                    e.change = last == null ? Change.ADDED : Change.CHANGED;
                    e.path = path;
                    last = e;
                    var t = e.to_variant ();
                    var builder = new VariantBuilder (VariantType.VARDICT);
                    var iter = t.iterator ();
                    string k;
                    Variant v;
                    while (iter.next ("{sv}", out k, out v)) builder.add ("{sv}", k, v);
                    builder.add ("{sv}", "snapshot", new Variant.string (s.id));
                    builder.add ("{sv}", "created", new Variant.int64 (s.created));
                    found.add (builder.end ());
                }
            });
            HashTable<string, Variant>[] result = {};
            foreach (var v in found) result += to_table (v);
            return result;
        }

        public async string[] check_restore (string snapshot, string[] paths, string target) throws Error {
            var busy = new Busy ();
            var b = yield ensure_backend ();
            return new Restorer (b, Environment.get_home_dir ()).conflicts (paths, target);
        }

        public async string[] restore (string snapshot, string[] paths, string target, string policy) throws Error {
            var busy = new Busy ();
            if (running) throw new BackupError.BUSY (_("Wait for the current backup to finish"));
            var b = yield ensure_backend ();
            running = true;
            put_state ("restoring");
            set_progress (0, "restoring", "");
            string[] restored = {};
            try {
                yield in_thread (() => {
                    restored = new Restorer (b, Environment.get_home_dir ()).restore (snapshot, paths, target,
                                                                                    ConflictPolicy.parse (policy), null);
                });
            } finally {
                running = false;
                put_state (configured ? "idle" : "unconfigured");
                set_progress (1, "done", "");
                reschedule ();
            }
            return restored;
        }

        public async void restore_all (string snapshot, string[] providers) throws Error {
            var busy = new Busy ();
            if (running) throw new BackupError.BUSY (_("Wait for the current backup to finish"));
            var b = yield ensure_backend ();
            running = true;
            put_state ("restoring");
            set_progress (0, "restoring", "");
            var plan = make_plan ("");
            string[] failures = {};
            try {
                foreach (string id in providers) {
                    var provider = Providers.find (id);
                    if (provider == null) continue;
                    set_progress (0, "restoring", provider.title);
                    try {
                        yield in_thread (() => {
                            provider.restore_all (b, snapshot, plan, null);
                        });
                    } catch (Error e) {
                        failures += e.message;
                    }
                }
            } finally {
                running = false;
                put_state (configured ? "idle" : "unconfigured");
                set_progress (1, "done", "");
                reschedule ();
            }
            if (failures.length > 0) throw new BackupError.FAILED ("%s", string.joinv ("\n", failures));
        }

        public async HashTable<string, Variant> verify (string snapshot) throws Error {
            var busy = new Busy ();
            if (running) throw new BackupError.BUSY (_("Wait for the current backup to finish"));
            var b = yield ensure_backend ();
            running = true;
            put_state ("verifying");
            set_progress (0, "verifying", "");
            VerifyResult? r = null;
            string id = snapshot;
            try {
                yield in_thread (() => {
                    if (id == "") {
                        var all = b.list_snapshots ();
                        if (all.size == 0) throw new BackupError.NOT_FOUND (_("There are no backups yet"));
                        id = all[all.size - 1].id;
                    }
                    r = b.verify (id, null, (f, p, item) => {
                        Idle.add (() => {
                            set_progress (f, "verifying", item);
                            return Source.REMOVE;
                        });
                    });
                });
            } finally {
                running = false;
                put_state (configured ? "idle" : "unconfigured");
                set_progress (1, "done", "");
            }
            var t = new HashTable<string, Variant> (str_hash, str_equal);
            t["snapshot"] = id;
            t["checked"] = r.checked;
            t["damaged"] = new Variant.strv (r.damaged);
            t["missing"] = new Variant.strv (r.missing);
            t["ok"] = r.ok;
            return t;
        }

        public async void delete_snapshot (string snapshot) throws Error {
            var busy = new Busy ();
            if (running) throw new BackupError.BUSY (_("Wait for the current backup to finish"));
            var b = yield ensure_backend ();
            yield in_thread (() => {
                b.delete_snapshot (snapshot);
            });
            snapshots_changed ();
        }

        public async HashTable<string, Variant>[] list_providers () throws Error {
            var busy = new Busy ();
            var plan = make_plan ("");
            string[] enabled = settings.get_strv ("providers");
            var tables = new Gee.ArrayList<HashTable<string, Variant>> ();
            yield in_thread (() => {
                foreach (var p in Providers.all ()) {
                    bool builtin = !(p is PluginProvider);
                    if (builtin && !sysconf.offers (p.id)) continue;
                    if (!builtin && !sysconf.offers (p.id) && !sysconf.offers ("*")) continue;
                    var t = new HashTable<string, Variant> (str_hash, str_equal);
                    t["id"] = p.id;
                    t["title"] = p.title;
                    t["description"] = p.description;
                    t["icon"] = p.icon_name;
                    t["available"] = p.available (plan);
                    t["enabled"] = p.id in enabled;
                    t["plugin"] = !builtin;
                    var plugin = p as PluginProvider;
                    t["reason"] = plugin != null ? plugin.unavailable_reason : "";
                    t["user-installed"] = plugin != null && plugin.manifest.user_installed;
                    tables.add (t);
                }
            });
            HashTable<string, Variant>[] result = {};
            foreach (var t in tables) result += t;
            return result;
        }

        private static HashTable<string, Variant> target_table (PluginManifest m, PluginTarget target) {
            var t = new HashTable<string, Variant> (str_hash, str_equal);
            t["kind"] = "plugin";
            t["plugin"] = m.id;
            t["plugin-name"] = m.name;
            t["id"] = target.id;
            t["name"] = target.name;
            t["detail"] = target.detail;
            t["icon"] = target.icon != "" ? target.icon : (m.icon_name != "" ? m.icon_name : "folder-remote");
            t["available"] = target.available;
            t["reason"] = target.reason;
            t["size"] = target.total;
            t["free"] = target.total > target.used ? target.total - target.used : (uint64) 0;
            t["used"] = target.used;
            t["can-hold-backups"] = target.available;
            t["supports-links"] = false;
            t["remote"] = true;
            return t;
        }

        public async HashTable<string, Variant>[] list_remote_destinations () throws Error {
            var busy = new Busy ();
            var tables = new Gee.ArrayList<HashTable<string, Variant>> ();
            yield in_thread (() => {
                foreach (var m in PluginRegistry.discover (PluginKind.DESTINATION)) {
                    if (!sysconf.offers_destination (m.id)) continue;
                    foreach (var target in new DestinationPlugin (m).targets ()) tables.add (target_table (m, target));
                }
            });
            HashTable<string, Variant>[] result = {};
            foreach (var t in tables) result += t;
            return result;
        }

        public async HashTable<string, Variant> inspect_remote (string plugin, string target) throws Error {
            var busy = new Busy ();
            var dp = find_destination_plugin (plugin);
            var store = dp.open_store (target);
            var r = new HashTable<string, Variant> (str_hash, str_equal);
            string mine = "%s@%s".printf (Environment.get_user_name (), Environment.get_host_name ());
            var names = new Gee.ArrayList<string> ();
            var encrypted = new Gee.ArrayList<bool> ();
            uint64 used = 0;
            uint64 total = 0;
            try {
                yield in_thread (() => {
                    store.space (out used, out total);
                    string head = sysconf.repository_name + "/";
                    foreach (var o in store.list (sysconf.repository_name, null)) {
                        if (!o.key.has_prefix (head) || !o.key.has_suffix ("/repository.json")) continue;
                        string name = o.key.substring (head.length, o.key.length - head.length - "/repository.json".length);
                        if (name.contains ("/")) continue;
                        var info = RemoteBackend.peek (store, head + name);
                        names.add (name);
                        encrypted.add (info != null && info.has_member ("encryption"));
                    }
                });
            } finally {
                store.close ();
            }
            HashTable<string, Variant>[] sets = {};
            for (int i = 0; i < names.size; i++) {
                var t = new HashTable<string, Variant> (str_hash, str_equal);
                t["name"] = names[i];
                t["encrypted"] = encrypted[i];
                t["this-computer"] = names[i] == mine;
                sets += t;
            }
            var list = new VariantBuilder (new VariantType ("aa{sv}"));
            foreach (var t in sets) {
                var d = new VariantBuilder (VariantType.VARDICT);
                t.foreach ((k, v) => d.add ("{sv}", k, v));
                list.add_value (d.end ());
            }
            r["repositories"] = list.end ();
            r["used"] = used;
            r["total"] = total;
            r["free"] = total > used ? total - used : (uint64) 0;
            r["this-computer"] = mine;
            return r;
        }

        public async HashTable<string, Variant> estimate () throws Error {
            var busy = new Busy ();
            var plan = make_plan ("");
            uint64 bytes = 0;
            uint64 files = 0;
            bool complete = true;
            yield in_thread (() => {
                var ex = new Exclusions (plan.exclusions);
                ex.add_path (".local/state/singularity-backups");
                int64 deadline = get_monotonic_time () + 8 * 1000000;
                complete = Estimator.walk (plan.source_home, "", ex, deadline, ref bytes, ref files);
            });
            var r = new HashTable<string, Variant> (str_hash, str_equal);
            r["bytes"] = bytes;
            r["files"] = files;
            r["complete"] = complete;
            return r;
        }

        public async HashTable<string, Variant> set_remote_destination (string plugin, string target, string name, string repository,
                                                                        string passphrase) throws Error {
            var busy = new Busy ();
            if (running) throw new BackupError.BUSY (_("Wait for the current backup to finish"));
            string? pass = passphrase != "" ? passphrase : null;
            if (pass == null) pass = yield Passphrases.lookup (passphrase_key (plugin, target, repository));
            var b = (RemoteBackend) yield open_remote (plugin, target, repository, pass);
            int count = 0;
            RepoStats? stats = null;
            try {
                yield in_thread (() => {
                    count = b.list_snapshots ().size;
                    stats = b.stats ();
                });
            } catch (Error e) {
                b.close ();
                throw e;
            }
            if (b.encrypted && passphrase != "") yield Passphrases.store (passphrase_key (plugin, target, repository), passphrase);
            drop_backend ();
            settings.delay ();
            settings.set_string ("destination-kind", "plugin");
            settings.set_string ("destination-plugin", plugin);
            settings.set_string ("destination-target", target);
            settings.set_string ("destination-repository", repository);
            settings.set_string ("destination-id", "");
            settings.set_string ("destination-path", "");
            settings.set_string ("destination-name", name);
            settings.set_boolean ("destination-encrypted", b.encrypted);
            settings.apply ();
            GLib.Settings.sync ();
            store.reset ();
            if (count > 0) {
                var all = b.list_snapshots ();
                store.last_success = all[all.size - 1].created;
                store.last_snapshot = all[all.size - 1].id;
                store.save ();
            }
            put_last_backup (store.last_success);
            put_last_error ("");
            backend = b;
            backend_repo = "%s|%s|%s".printf (plugin, target, repository);
            first_schedule = false;
            refresh_configured ();
            snapshots_changed ();
            bool other_computer = repository != "" && repository != "%s@%s".printf (Environment.get_user_name (), Environment.get_host_name ());
            if (count == 0 && !other_computer) run_backup.begin (true);
            else reschedule ();
            var t = new HashTable<string, Variant> (str_hash, str_equal);
            t["snapshots"] = count;
            t["incremental"] = true;
            t["store"] = stats.store;
            t["encrypted"] = b.encrypted;
            t["created"] = b.created_now;
            return t;
        }

        public async HashTable<string, Variant>[] list_destinations () throws Error {
            var busy = new Busy ();
            for (int i = 0; i < 60 && udisks_pending; i++) {
                Timeout.add (50, list_destinations.callback);
                yield;
            }
            HashTable<string, Variant>[] result = {};
            foreach (var d in dests.list_disks ()) result += to_table (d.to_variant ());
            bool direct_cloud = sysconf.offers_destination ("cloud") && PluginRegistry.find (PluginKind.DESTINATION, "cloud") != null;
            foreach (var d in direct_cloud ? new Gee.ArrayList<Destination> () : Destinations.list_cloud_drives ()) {
                d.has_backups = FileUtils.test (Path.build_filename (d.mount_point, sysconf.repository_name), FileTest.IS_DIR);
                result += to_table (d.to_variant ());
            }
            foreach (var d in Destinations.list_network_mounts ()) {
                d.has_backups = FileUtils.test (Path.build_filename (d.mount_point, sysconf.repository_name), FileTest.IS_DIR);
                result += to_table (d.to_variant ());
            }
            return result;
        }

        public async HashTable<string, Variant> set_destination (string kind, string target, string name, bool encrypted) throws Error {
            var busy = new Busy ();
            if (running) throw new BackupError.BUSY (_("Wait for the current backup to finish"));
            if (kind != "disk" && kind != "folder" && kind != "network" && kind != "cloud") throw new BackupError.UNSUPPORTED (_("Unknown destination"));
            drop_backend ();
            string base_path;
            if (kind == "disk") {
                string? pass = encrypted ? yield Passphrases.lookup (target) : null;
                base_path = yield dests.mount_disk (target, pass);
            } else {
                base_path = target;
                if (!FileUtils.test (base_path, FileTest.IS_DIR)) throw new BackupError.UNAVAILABLE (_("The folder “%s” is not available"), Path.get_basename (base_path));
            }
            string repo = dests.repository_in (base_path);
            var b = create_backend ();
            int count = 0;
            RepoStats? stats = null;
            yield in_thread (() => {
                if (DirUtils.create_with_parents (repo, 0700) != 0) throw new BackupError.UNAVAILABLE (_("Cannot write to %s"), base_path);
                b.open (repo);
                count = b.list_snapshots ().size;
                stats = b.stats ();
            });
            settings.delay ();
            settings.set_string ("destination-kind", kind);
            settings.set_string ("destination-id", kind == "disk" ? target : "");
            settings.set_string ("destination-path", kind == "disk" ? "" : target);
            settings.set_string ("destination-name", name);
            settings.set_boolean ("destination-encrypted", encrypted);
            settings.set_string ("destination-plugin", "");
            settings.set_string ("destination-target", "");
            settings.set_string ("destination-repository", "");
            settings.apply ();
            GLib.Settings.sync ();
            store.reset ();
            if (count > 0) {
                var all = b.list_snapshots ();
                store.last_success = all[all.size - 1].created;
                store.last_snapshot = all[all.size - 1].id;
                store.save ();
            }
            put_last_backup (store.last_success);
            put_last_error ("");
            backend = b;
            backend_repo = repo;
            first_schedule = false;
            refresh_configured ();
            snapshots_changed ();
            if (count == 0) run_backup.begin (true);
            else reschedule ();
            var t = new HashTable<string, Variant> (str_hash, str_equal);
            t["snapshots"] = count;
            t["incremental"] = stats.links;
            t["store"] = stats.store;
            t["repository"] = repo;
            return t;
        }

        public void forget_destination () throws Error {
            if (running) throw new BackupError.BUSY (_("Wait for the current backup to finish"));
            settings.delay ();
            settings.set_string ("destination-kind", "");
            settings.set_string ("destination-id", "");
            settings.set_string ("destination-path", "");
            settings.set_string ("destination-name", "");
            settings.set_boolean ("destination-encrypted", false);
            settings.set_string ("destination-plugin", "");
            settings.set_string ("destination-target", "");
            settings.set_string ("destination-repository", "");
            settings.apply ();
            GLib.Settings.sync ();
            store.reset ();
            put_last_backup (0);
            put_last_error ("");
            drop_backend ();
            refresh_configured ();
            reschedule ();
        }

        public async string prepare_disk (string object_path, string label, string passphrase) throws Error {
            var busy = new Busy ();
            if (running) throw new BackupError.BUSY (_("Wait for the current backup to finish"));
            string uuid = yield dests.prepare_disk (object_path, label, passphrase != "" ? passphrase : null);
            if (passphrase != "") yield Passphrases.store (uuid, passphrase);
            return uuid;
        }

        public async bool remember_passphrase (string uuid, string passphrase) throws Error {
            var busy = new Busy ();
            return yield Passphrases.store (uuid, passphrase);
        }
    }
}
