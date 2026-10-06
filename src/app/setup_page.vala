using Gtk;
using Singularity.Widgets;

namespace Singularity.Backups {

    public class SetupPage : Box {
        private const string[] FREQUENCIES = { "hourly", "daily", "weekly", "manual" };
        private const string[] RETENTIONS = { "smart", "keep-last" };

        public BackupsApp app { get; construct; }
        public bool can_commit { get; private set; default = false; }

        public signal void finished ();
        public signal void exclusions_requested ();

        private string kind = "disk";
        private string target = "";
        private string target_name = "";
        private bool target_encrypted = false;
        private bool target_locked = false;
        private Label heading;
        private Label intro;
        private PreferencesGroup dest_group;
        private Gee.ArrayList<Widget> dest_rows = new Gee.ArrayList<Widget> ();
        private PreferencesGroup what_group;
        private Gee.ArrayList<Widget> what_rows = new Gee.ArrayList<Widget> ();
        private ActionRow exclusions_row;
        private SelectionRow frequency_row;
        private SpinRow keep_row;
        private SelectionRow retention_row;
        private SwitchRow battery_row;
        private SpinRow threshold_row;
        private SwitchRow dedup_row;
        private PasswordRow? passphrase_row = null;
        private Banner problem;
        private string remote_plugin = "";
        private string remote_target = "";
        private string repository = "";
        private bool repo_exists = false;
        private bool repo_encrypted = false;
        private bool inspected = false;
        private uint64 remote_free = 0;
        private uint64 remote_total = 0;
        private uint64 estimate_bytes = 0;
        private bool estimate_done = false;
        private uint inspect_serial = 0;
        private PreferencesGroup sets_group;
        private Gee.ArrayList<Widget> set_rows = new Gee.ArrayList<Widget> ();
        private PreferencesGroup crypt_group;
        private SwitchRow encrypt_row;
        private PasswordRow secret_row;
        private PasswordRow again_row;
        private Banner crypt_warning;
        private PreferencesGroup space_group;
        private ActionRow space_row;
        private uint poll = 0;
        private string fingerprint = "";
        private HashTable<string, Image> checks = new HashTable<string, Image> (str_hash, str_equal);

        public SetupPage (BackupsApp app) {
            Object (app: app, orientation: Orientation.VERTICAL, spacing: 0);
        }

        construct {
            add_css_class ("backups-page");
            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            var content = new Box (Orientation.VERTICAL, 24);
            content.margin_top = 24;
            content.margin_bottom = 32;
            content.margin_start = 24;
            content.margin_end = 24;

            var head = new Box (Orientation.VERTICAL, 6);
            heading = new Label ("");
            heading.add_css_class ("title-1");
            heading.xalign = 0;
            heading.wrap = true;
            head.append (heading);
            intro = new Label ("");
            intro.add_css_class ("dim-label");
            intro.xalign = 0;
            intro.wrap = true;
            head.append (intro);
            content.append (head);

            problem = new Banner ("", BannerStyle.ERROR);
            problem.visible = false;
            content.append (problem);

            dest_group = new PreferencesGroup (_("Disks"));
            content.append (dest_group);

            sets_group = new PreferencesGroup (_("Backups in This Account"),
                _("Continue the backups of this computer, or pick those of another computer to restore them here."));
            sets_group.visible = false;
            content.append (sets_group);

            crypt_group = new PreferencesGroup (_("Encryption"));
            encrypt_row = new SwitchRow (_("Encrypt Backups"),
                _("Files are encrypted on this computer before they are uploaded; the account only stores unreadable data"),
                app.settings.get_boolean ("encrypt-remote"));
            encrypt_row.icon_name = "channel-secure-symbolic";
            encrypt_row.switch_btn.notify["active"].connect (() => sync_encryption ());
            crypt_group.add_row (encrypt_row);
            secret_row = new PasswordRow (_("Passphrase"));
            secret_row.entry_changed.connect (() => update_commit ());
            crypt_group.add_row (secret_row);
            again_row = new PasswordRow (_("Repeat Passphrase"));
            again_row.entry_changed.connect (() => update_commit ());
            crypt_group.add_row (again_row);
            crypt_warning = new Banner (_("Nobody can recover a forgotten passphrase, not even with access to the account. Write it down and keep it somewhere safe; you need it to restore on a new computer."), BannerStyle.WARNING);
            crypt_group.visible = false;
            content.append (crypt_group);
            content.append (crypt_warning);
            crypt_warning.visible = false;

            space_group = new PreferencesGroup (_("Space"));
            space_row = new ActionRow (_("First Backup"), "", "drive-harddisk-symbolic");
            space_group.add_row (space_row);
            space_group.visible = false;
            content.append (space_group);

            what_group = new PreferencesGroup (_("What to Back Up"));
            exclusions_row = new ActionRow (_("Excluded Items"), "");
            exclusions_row.add_suffix (new Image.from_icon_name ("go-next-symbolic"));
            exclusions_row.activatable = true;
            exclusions_row.activated.connect (() => exclusions_requested ());
            content.append (what_group);

            var schedule = new PreferencesGroup (_("Schedule"), _("You can change these later in Settings."));
            string[] labels = { _("Every Hour"), _("Every Day"), _("Every Week"), _("Only When I Ask") };
            frequency_row = new SelectionRow (_("Back Up"), labels, labels[0]);
            frequency_row.selected.connect ((label) => {
                for (int i = 0; i < labels.length; i++) {
                    if (labels[i] == label) app.settings.set_string ("frequency", FREQUENCIES[i]);
                }
            });
            schedule.add_row (frequency_row);
            string[] kept = { _("Hourly, Daily and Weekly"), _("A Fixed Number") };
            retention_row = new SelectionRow (_("Keep"), kept, kept[0]);
            retention_row.subtitle = _("Every hour for a day, every day for a month, every week before that");
            retention_row.selected.connect ((label) => {
                for (int i = 0; i < kept.length; i++) {
                    if (kept[i] == label) app.settings.set_string ("retention", RETENTIONS[i]);
                }
                sync_retention ();
            });
            schedule.add_row (retention_row);
            keep_row = new SpinRow (_("Backups to Keep"), _("The oldest are deleted first, also when the disk gets full"), 1, 1000, 1, 48);
            keep_row.spin_btn.value_changed.connect (() => app.settings.set_int ("keep-last", (int) keep_row.value));
            schedule.add_row (keep_row);
            dedup_row = new SwitchRow (_("Store Identical Files Once"),
                _("Copies of the same file, and files you move or rename, take no extra space"));
            app.settings.bind ("deduplicate", dedup_row, "active", SettingsBindFlags.DEFAULT);
            schedule.add_row (dedup_row);
            content.append (schedule);

            var battery = new PreferencesGroup (_("Battery"));
            battery_row = new SwitchRow (_("Pause on Low Battery"),
                _("Automatic backups wait until the computer is plugged in or charged again"));
            app.settings.bind ("pause-on-battery", battery_row, "active", SettingsBindFlags.DEFAULT);
            battery.add_row (battery_row);
            threshold_row = new SpinRow (_("Low Battery Level"), _("Percent of charge under which automatic backups pause"), 5, 90, 5, 20);
            threshold_row.spin_btn.value_changed.connect (() => app.settings.set_int ("battery-threshold", (int) threshold_row.value));
            battery_row.bind_property ("active", threshold_row, "sensitive", BindingFlags.SYNC_CREATE);
            battery.add_row (threshold_row);
            content.append (battery);

            scroll.child = new Clamp (content, 640);
            append (scroll);

            map.connect (() => start_polling ());
            unmap.connect (() => stop_polling ());
        }

        private void start_polling () {
            if (poll != 0 || kind == "folder" || remote_kind) return;
            poll = Timeout.add_seconds (3, () => {
                refresh_destinations (false);
                return Source.CONTINUE;
            });
        }

        private void stop_polling () {
            if (poll != 0) Source.remove (poll);
            poll = 0;
        }

        public async void begin_setup (string kind) {
            this.kind = kind;
            target = "";
            target_name = "";
            target_encrypted = false;
            target_locked = false;
            fingerprint = "";
            problem.visible = false;
            reset_remote ();
            switch (kind) {
                case "disk":
                    heading.label = _("Choose a Backup Disk");
                    intro.label = _("Backups start whenever the disk is connected. A disk used only for backups works best.");
                    dest_group.title = _("Disks");
                    break;
                case "cloud":
                    heading.label = _("Choose an Online Account");
                    intro.label = _("Accounts with Files switched on in Settings, Online Accounts appear here. Unchanged files are uploaded only once, and an interrupted upload continues where it stopped.");
                    dest_group.title = _("Online Accounts");
                    break;
                case "remote":
                    heading.label = _("Choose a Storage Service");
                    intro.label = _("Services added by installed backup plugins. Unchanged files are uploaded only once.");
                    dest_group.title = _("Services");
                    break;
                case "network":
                    heading.label = _("Choose a Network Share");
                    intro.label = _("Connect to the share in Files first. Backups run while it is connected.");
                    dest_group.title = _("Network Shares");
                    break;
                default:
                    heading.label = _("Choose a Backup Folder");
                    intro.label = _("A folder on another disk keeps your files safe if this one fails.");
                    dest_group.title = _("Folder");
                    break;
            }
            string current = app.settings.get_string ("frequency");
            string[] labels = { _("Every Hour"), _("Every Day"), _("Every Week"), _("Only When I Ask") };
            for (int i = 0; i < FREQUENCIES.length; i++) if (FREQUENCIES[i] == current) frequency_row.current_value = labels[i];
            keep_row.value = app.settings.get_int ("keep-last");
            threshold_row.value = app.settings.get_int ("battery-threshold");
            string[] kept = { _("Hourly, Daily and Weekly"), _("A Fixed Number") };
            string mode = app.settings.get_string ("retention");
            for (int i = 0; i < RETENTIONS.length; i++) if (RETENTIONS[i] == mode) retention_row.current_value = kept[i];
            sync_retention ();
            refresh_destinations (true);
            refresh_providers.begin ();
            refresh_exclusions ();
            update_commit ();
        }

        private bool remote_kind {
            get { return kind == "cloud" || kind == "remote"; }
        }

        private void reset_remote () {
            remote_plugin = "";
            remote_target = "";
            repository = "";
            repo_exists = false;
            repo_encrypted = false;
            inspected = false;
            remote_free = 0;
            remote_total = 0;
            inspect_serial++;
            foreach (var r in set_rows) sets_group.remove_row (r);
            set_rows.clear ();
            sets_group.visible = false;
            crypt_group.visible = false;
            crypt_warning.visible = false;
            space_group.visible = false;
            secret_row.text = "";
            again_row.text = "";
            encrypt_row.active = app.settings.get_boolean ("encrypt-remote");
        }

        private void sync_encryption () {
            bool show = remote_plugin != "" && inspected;
            crypt_group.visible = show;
            if (!show) {
                crypt_warning.visible = false;
                update_commit ();
                return;
            }
            if (repo_exists) {
                encrypt_row.active = repo_encrypted;
                encrypt_row.sensitive = false;
                encrypt_row.subtitle = repo_encrypted ? _("These backups are encrypted. Enter their passphrase to use them.")
                                                      : _("These backups were made without encryption");
                secret_row.title = _("Passphrase of These Backups");
                secret_row.visible = repo_encrypted;
                again_row.visible = false;
                crypt_warning.visible = false;
            } else {
                encrypt_row.sensitive = true;
                encrypt_row.subtitle = _("Files are encrypted on this computer before they are uploaded; the account only stores unreadable data");
                secret_row.title = _("Passphrase");
                secret_row.visible = encrypt_row.active;
                again_row.visible = encrypt_row.active;
                crypt_warning.visible = encrypt_row.active;
            }
            update_commit ();
        }

        private void sync_space () {
            if (remote_plugin == "" || !estimate_done) {
                space_group.visible = false;
                return;
            }
            space_group.visible = true;
            space_row.title = repo_exists ? _("Next Backup") : _("First Backup");
            string need = repo_exists ? _("Only files that changed since the last backup are uploaded")
                                      : _("About %s to upload").printf (GLib.format_size (estimate_bytes));
            if (remote_total > 0) {
                space_row.subtitle = _("%s. %s free of %s in the account.").printf (need, GLib.format_size (remote_free), GLib.format_size (remote_total));
                space_row.icon_name = !repo_exists && estimate_bytes > remote_free ? "dialog-warning-symbolic" : "drive-harddisk-symbolic";
                if (!repo_exists && estimate_bytes > remote_free) {
                    space_row.subtitle = _("About %s to upload, but only %s is free in the account. Exclude large folders or free some space first.")
                        .printf (GLib.format_size (estimate_bytes), GLib.format_size (remote_free));
                }
            } else {
                space_row.subtitle = "%s.".printf (need);
            }
        }

        private async void run_estimate () {
            if (estimate_done || app.daemon == null) return;
            try {
                var e = yield app.daemon.estimate ();
                estimate_bytes = get_u64 (e, "bytes");
                estimate_done = true;
            } catch (Error err) {
                warning ("Backups: %s", error_text (err));
            }
            sync_space ();
        }

        private async void inspect (string plugin, string target_id) {
            uint serial = ++inspect_serial;
            inspected = false;
            foreach (var r in set_rows) sets_group.remove_row (r);
            set_rows.clear ();
            sets_group.visible = false;
            sync_encryption ();
            HashTable<string, Variant>? info = null;
            try {
                info = yield app.daemon.inspect_remote (plugin, target_id);
            } catch (Error e) {
                if (serial != inspect_serial) return;
                problem.title = _("The account cannot be read: %s").printf (error_text (e));
                problem.visible = true;
                return;
            }
            if (serial != inspect_serial) return;
            problem.visible = false;
            remote_total = get_u64 (info, "total");
            remote_free = get_u64 (info, "free");
            string mine = get_str (info, "this-computer");
            var sets = info["repositories"];
            var found = new Gee.ArrayList<HashTable<string, Variant>> ();
            if (sets != null) {
                for (size_t i = 0; i < sets.n_children (); i++) {
                    var t = new HashTable<string, Variant> (str_hash, str_equal);
                    var iter = sets.get_child_value (i).iterator ();
                    string k;
                    Variant v;
                    while (iter.next ("{sv}", out k, out v)) t[k] = v;
                    found.add (t);
                }
            }
            bool mine_exists = false;
            foreach (var t in found) if (get_bool (t, "this-computer")) mine_exists = true;
            var checks_by_name = new HashTable<string, Image> (str_hash, str_equal);
            var encrypted_by_name = new HashTable<string, bool?> (str_hash, str_equal);
            var exists_by_name = new HashTable<string, bool?> (str_hash, str_equal);
            string[] order = { mine };
            encrypted_by_name[mine] = false;
            exists_by_name[mine] = false;
            foreach (var t in found) {
                string name = get_str (t, "name");
                encrypted_by_name[name] = get_bool (t, "encrypted");
                exists_by_name[name] = true;
                if (name != mine) order += name;
            }
            repository = "";
            repo_exists = mine_exists;
            repo_encrypted = encrypted_by_name[mine];
            if (found.size > 0 && !(found.size == 1 && mine_exists)) {
                foreach (string name in order) {
                    bool is_mine = name == mine;
                    string title = is_mine ? _("This Computer") : _("Backups of %s").printf (name);
                    string subtitle = is_mine ? (exists_by_name[name] ? _("Continue the backups of %s").printf (name) : _("Start new backups for %s").printf (name))
                                              : _("Restore them on this computer, then keep backing up into them");
                    if (encrypted_by_name[name]) subtitle += " · " + _("Encrypted");
                    var row = new ActionRow (title, subtitle, is_mine ? "computer-symbolic" : "document-open-recent-symbolic");
                    var check = new Image.from_icon_name ("object-select-symbolic");
                    check.valign = Align.CENTER;
                    check.add_css_class ("accent");
                    check.visible = is_mine;
                    checks_by_name[name] = check;
                    row.add_suffix (check);
                    row.activatable = true;
                    string chosen = name;
                    row.activated.connect (() => {
                        repository = chosen == mine ? "" : chosen;
                        repo_exists = exists_by_name[chosen];
                        repo_encrypted = encrypted_by_name[chosen];
                        checks_by_name.foreach ((n, img) => img.visible = n == chosen);
                        secret_row.text = "";
                        again_row.text = "";
                        sync_encryption ();
                        sync_space ();
                    });
                    sets_group.add_row (row);
                    set_rows.add (row);
                }
                sets_group.visible = true;
            }
            inspected = true;
            sync_encryption ();
            sync_space ();
            run_estimate.begin ();
        }

        private void sync_retention () {
            bool fixed_count = app.settings.get_string ("retention") == "keep-last";
            keep_row.visible = fixed_count;
            retention_row.subtitle = fixed_count ? _("Only the latest backups, up to the number below")
                                                 : _("Every hour for a day, every day for a month, every week before that");
        }

        public void refresh_exclusions () {
            int n = app.settings.get_strv ("exclusions").length;
            exclusions_row.subtitle = n == 0 ? _("Nothing is excluded") : ngettext ("%d rule", "%d rules", n).printf (n);
        }

        private async void refresh_providers () {
            if (app.daemon == null) return;
            HashTable<string, Variant>[] providers = {};
            try {
                providers = yield app.daemon.list_providers ();
            } catch (Error e) {
                warning ("Backups: %s", error_text (e));
            }
            foreach (var r in what_rows) what_group.remove_row (r);
            what_rows.clear ();
            string[] enabled = app.settings.get_strv ("providers");
            foreach (var p in providers) {
                string id = get_str (p, "id");
                bool available = get_bool (p, "available");
                if (!available && !get_bool (p, "plugin")) continue;
                string subtitle = available ? get_str (p, "description") : get_str (p, "reason", _("Not available on this system"));
                var row = new SwitchRow (get_str (p, "title"), subtitle, available && (id == "userdata" || id in enabled));
                row.icon_name = get_str (p, "icon");
                row.sensitive = available;
                if (id == "userdata") {
                    row.switch_btn.sensitive = false;
                } else {
                    row.switch_btn.notify["active"].connect (() => {
                        string[] list = {};
                        foreach (string e in app.settings.get_strv ("providers")) if (e != id) list += e;
                        if (row.switch_btn.active) list += id;
                        app.settings.set_strv ("providers", list);
                    });
                }
                what_group.add_row (row);
                what_rows.add (row);
            }
            what_group.add_row (exclusions_row);
            what_rows.add (exclusions_row);
        }

        private void clear_dest_rows () {
            foreach (var r in dest_rows) dest_group.remove_row (r);
            dest_rows.clear ();
            passphrase_row = null;
            checks.remove_all ();
        }

        private void refresh_destinations (bool force) {
            if (app.daemon == null) return;
            if (kind == "folder") {
                if (!force) return;
                clear_dest_rows ();
                var row = new ActionRow (_("Backup Folder"), target != "" ? target : _("No folder chosen yet"), "folder");
                var choose = new Button.with_label (_("Choose…"));
                choose.valign = Align.CENTER;
                choose.clicked.connect (() => choose_folder.begin ());
                row.add_suffix (choose);
                dest_group.add_row (row);
                dest_rows.add (row);
                return;
            }
            load_destinations.begin (force);
        }

        private async void load_destinations (bool force) {
            HashTable<string, Variant>[] all = {};
            try {
                if (kind != "remote") all = yield app.daemon.list_destinations ();
                if (remote_kind) {
                    foreach (var d in yield app.daemon.list_remote_destinations ()) {
                        bool cloud = get_str (d, "plugin") == "cloud";
                        if (cloud == (kind == "cloud")) all += d;
                    }
                }
            } catch (Error e) {
                warning ("Backups: %s", error_text (e));
            }
            var shown = new Gee.ArrayList<HashTable<string, Variant>> ();
            var key = new StringBuilder ();
            foreach (var d in all) {
                string dk = get_str (d, "kind");
                if (dk != kind && !(dk == "plugin" && remote_kind)) continue;
                shown.add (d);
                key.append ("%s|%s|%s|%s;".printf (get_str (d, "id"), get_str (d, "mount-point"), get_bool (d, "locked").to_string (), get_str (d, "fstype")));
            }
            if (!force && key.str == fingerprint) return;
            fingerprint = key.str;
            clear_dest_rows ();
            if (shown.size == 0) {
                var empty = new StatusPage ();
                empty.compact = true;
                if (kind == "disk") {
                    empty.icon_name = "drive-harddisk-usb";
                    empty.title = _("No Disks Found");
                    empty.description = _("Connect an external disk. It shows up here as soon as it is ready.");
                } else if (kind == "cloud") {
                    empty.icon_name = "folder-cloud";
                    empty.title = _("No Online Accounts With Files");
                    empty.description = _("Add an account in Settings, Online Accounts, and switch on Files.");
                } else if (kind == "remote") {
                    empty.icon_name = "application-x-addon";
                    empty.title = _("No Services Available");
                    empty.description = _("The installed backup plugins have nothing to offer right now.");
                } else {
                    empty.icon_name = "folder-remote";
                    empty.title = _("No Network Shares Connected");
                    empty.description = _("Open the share in Files, or choose its folder below.");
                }
                var holder = new ListBoxRow ();
                holder.activatable = false;
                holder.selectable = false;
                holder.child = empty;
                dest_group.add_row (holder);
                dest_rows.add (holder);
            }
            foreach (var d in shown) add_destination_row (d);
            if (kind == "network") {
                var other = new ActionRow (_("Other Folder"), target != "" && !target_listed (shown) ? target : _("A share mounted somewhere else"), "folder-remote");
                var choose = new Button.with_label (_("Choose…"));
                choose.valign = Align.CENTER;
                choose.clicked.connect (() => choose_folder.begin ());
                other.add_suffix (choose);
                dest_group.add_row (other);
                dest_rows.add (other);
            }
            update_commit ();
        }

        private bool target_listed (Gee.List<HashTable<string, Variant>> shown) {
            foreach (var d in shown) if (get_str (d, "mount-point") == target || get_str (d, "id") == target) return true;
            return false;
        }

        private void add_remote_row (HashTable<string, Variant> d) {
            string name = get_str (d, "name");
            string plugin = get_str (d, "plugin");
            string target_id = get_str (d, "id");
            string id = plugin + "|" + target_id;
            bool usable = get_bool (d, "available", true);
            string[] facts = {};
            if (get_str (d, "detail") != "") facts += get_str (d, "detail");
            uint64 size = get_u64 (d, "size");
            if (size > 0) facts += _("%s free of %s").printf (GLib.format_size (get_u64 (d, "free")), GLib.format_size (size));
            if (!usable && get_str (d, "reason") != "") facts += get_str (d, "reason");
            var row = new ActionRow (name, string.joinv (" · ", facts), get_str (d, "icon", "folder-cloud"));
            if (kind == "remote" && get_str (d, "plugin-name") != "") row.title = "%s, %s".printf (name, get_str (d, "plugin-name"));
            row.sensitive = usable;
            var check = new Image.from_icon_name ("object-select-symbolic");
            check.valign = Align.CENTER;
            check.add_css_class ("accent");
            check.visible = target == id;
            checks[id] = check;
            row.add_suffix (check);
            row.activatable = usable;
            row.activated.connect (() => {
                if (target == id) return;
                target = id;
                target_name = name;
                remote_plugin = plugin;
                remote_target = target_id;
                checks.foreach ((k, img) => img.visible = k == id);
                inspect.begin (plugin, target_id);
                update_commit ();
            });
            dest_group.add_row (row);
            dest_rows.add (row);
        }

        private void add_destination_row (HashTable<string, Variant> d) {
            if (get_str (d, "kind") == "plugin") {
                add_remote_row (d);
                return;
            }
            string name = get_str (d, "name");
            string id = kind == "disk" ? get_str (d, "id") : get_str (d, "mount-point");
            bool encrypted = get_bool (d, "encrypted");
            bool locked = get_bool (d, "locked");
            bool usable = get_bool (d, "can-hold-backups") && (kind != "disk" || id != "");
            string[] facts = {};
            uint64 size = get_u64 (d, "size");
            uint64 free = get_u64 (d, "free");
            if (size > 0) facts += free > 0 ? _("%s, %s free").printf (GLib.format_size (size), GLib.format_size (free)) : GLib.format_size (size);
            if (get_bool (d, "has-backups")) facts += _("Has backups");
            if (encrypted) facts += locked ? _("Encrypted, locked") : _("Encrypted");
            if (!usable) facts += _("Must be erased before it can hold backups");
            else if (!get_bool (d, "supports-links")) facts += _("Files are stored once and shared between backups");
            string icon = kind == "disk" ? (get_bool (d, "removable") ? "drive-harddisk-usb" : "drive-harddisk")
                                         : kind == "cloud" ? "folder-cloud" : "folder-remote";
            var row = new ActionRow (name, string.joinv (" · ", facts), icon);
            if (usable) {
                var check = new Image.from_icon_name ("object-select-symbolic");
                check.valign = Align.CENTER;
                check.add_css_class ("accent");
                check.visible = target == id;
                checks[id] = check;
                row.add_suffix (check);
                row.activatable = true;
                row.activated.connect (() => {
                    reset_remote ();
                    target = id;
                    target_name = name;
                    target_encrypted = encrypted;
                    target_locked = locked;
                    checks.foreach ((k, img) => img.visible = k == id);
                    sync_passphrase ();
                    update_commit ();
                });
            }
            if (kind == "disk" && get_str (d, "object") != "") {
                var erase = new Button.with_label (usable ? _("Erase…") : _("Erase for Backups…"));
                erase.valign = Align.CENTER;
                if (!usable) erase.add_css_class ("suggested-action");
                string object_path = get_str (d, "object");
                erase.clicked.connect (() => confirm_erase (object_path, name));
                row.add_suffix (erase);
            }
            dest_group.add_row (row);
            dest_rows.add (row);
        }

        private void sync_passphrase () {
            if (passphrase_row != null) {
                dest_group.remove_row (passphrase_row);
                dest_rows.remove (passphrase_row);
                passphrase_row = null;
            }
            if (!(kind == "disk" && target_encrypted && target_locked)) return;
            passphrase_row = new PasswordRow (_("Disk Passphrase"));
            passphrase_row.entry_changed.connect (() => update_commit ());
            dest_group.add_row (passphrase_row);
            dest_rows.add (passphrase_row);
        }

        private void update_commit () {
            bool ok = target != "";
            if (passphrase_row != null && passphrase_row.text == "") ok = false;
            if (remote_plugin != "") {
                if (!inspected) ok = false;
                else if (repo_exists && repo_encrypted && secret_row.text == "") ok = false;
                else if (!repo_exists && encrypt_row.active && (secret_row.text.length < 8 || secret_row.text != again_row.text)) ok = false;
            }
            if (remote_plugin != "" && inspected && !repo_exists && encrypt_row.active) {
                again_row.subtitle = secret_row.text != "" && secret_row.text.length < 8 ? _("Use at least 8 characters")
                                   : again_row.text != "" && secret_row.text != again_row.text ? _("The passphrases do not match") : "";
            }
            can_commit = ok;
        }

        private async void choose_folder () {
            var dialog = new FileDialog ();
            dialog.title = kind == "network" ? _("Choose the Network Share") : _("Choose a Backup Folder");
            dialog.modal = true;
            try {
                var folder = yield dialog.select_folder ((Gtk.Window) get_root (), null);
                target = folder.get_path ();
                target_name = folder.get_basename ();
                target_encrypted = false;
                target_locked = false;
                if (kind == "network") refresh_destinations (true);
                else refresh_destinations (true);
                update_commit ();
            } catch (Error e) {
            }
        }

        private void confirm_erase (string object_path, string name) {
            var dialog = new ConfirmDialog (app, _("Erase “%s”?").printf (name), "drive-harddisk-usb",
                _("Everything on the disk is deleted, and it is prepared to hold backups. This cannot be undone."),
                _("Erase"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dialog.transient_for = (Gtk.Window) get_root ();
            var encrypt = new CheckButton.with_label (_("Protect the disk with a passphrase"));
            var pass = new PasswordEntry ();
            pass.show_peek_icon = true;
            pass.placeholder_text = _("Passphrase");
            var again = new PasswordEntry ();
            again.placeholder_text = _("Repeat Passphrase");
            pass.visible = false;
            again.visible = false;
            var hint = new Label (_("Without the passphrase nobody can read the backups, including you."));
            hint.add_css_class ("dim-label");
            hint.add_css_class ("caption");
            hint.wrap = true;
            hint.visible = false;
            encrypt.toggled.connect (() => {
                pass.visible = encrypt.active;
                again.visible = encrypt.active;
                hint.visible = encrypt.active;
            });
            dialog.custom_area.append (encrypt);
            dialog.custom_area.append (pass);
            dialog.custom_area.append (again);
            dialog.custom_area.append (hint);
            pass.changed.connect (() => dialog.primary_sensitive = !encrypt.active || (pass.text != "" && pass.text == again.text));
            again.changed.connect (() => dialog.primary_sensitive = !encrypt.active || (pass.text != "" && pass.text == again.text));
            encrypt.toggled.connect (() => dialog.primary_sensitive = !encrypt.active || (pass.text != "" && pass.text == again.text));
            dialog.response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                erase.begin (object_path, name, encrypt.active ? pass.text : "");
            });
            dialog.present ();
        }

        private async void erase (string object_path, string name, string passphrase) {
            problem.visible = false;
            try {
                string uuid = yield app.daemon.prepare_disk (object_path, _("Backups"), passphrase);
                target = uuid;
                target_name = _("Backups");
                target_encrypted = passphrase != "";
                target_locked = false;
                refresh_destinations (true);
            } catch (Error e) {
                problem.title = _("The disk could not be erased: %s").printf (error_text (e));
                problem.visible = true;
            }
        }

        private async void commit_remote () {
            string pass = "";
            if (repo_exists ? repo_encrypted : encrypt_row.active) pass = secret_row.text;
            try {
                var result = yield app.daemon.set_remote_destination (remote_plugin, remote_target, target_name, repository, pass);
                finished ();
                var root = get_root () as Singularity.Widgets.Window;
                if (root != null && get_bool (result, "created") && get_bool (result, "encrypted")) {
                    root.add_toast (new Toast (_("Backups are encrypted. Keep the passphrase safe: it cannot be recovered.")));
                }
            } catch (Error e) {
                problem.title = error_text (e);
                problem.visible = true;
                update_commit ();
            }
        }

        public async void commit () {
            if (!can_commit || app.daemon == null) return;
            can_commit = false;
            problem.visible = false;
            if (remote_plugin != "") {
                yield commit_remote ();
                return;
            }
            try {
                if (passphrase_row != null && passphrase_row.text != "") {
                    yield app.daemon.remember_passphrase (target, passphrase_row.text);
                }
                var result = yield app.daemon.set_destination (kind, target, target_name != "" ? target_name : target, target_encrypted);
                finished ();
                if (!get_bool (result, "incremental")) {
                    var root = get_root () as Singularity.Widgets.Window;
                    if (root != null) root.add_toast (new Toast (_("This location cannot link unchanged files, so every backup is a full copy")));
                }

            } catch (Error e) {
                problem.title = error_text (e);
                problem.visible = true;
                update_commit ();
            }
        }
    }
}
