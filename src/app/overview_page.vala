using Gtk;
using Singularity.Widgets;

namespace Singularity.Backups {

    public class OverviewPage : Box {
        public BackupsApp app { get; construct; }

        public signal void browse_requested ();
        public signal void exclusions_requested ();
        public signal void change_destination ();
        public signal void toast (Toast toast);

        private CircularProgress ring;
        private Image hero_icon;
        private Label state_label;
        private Label last_label;
        private Label next_label;
        private Label item_label;
        private Banner error_banner;
        private Banner waiting_banner;
        private Banner warnings_banner;
        private string[] last_warnings = {};
        private ActionRow dest_row;
        private Label usage_label;
        private LevelBar usage_bar;
        private ActionRow browse_row;
        private ActionRow verify_row;
        private Button verify_button;
        private PreferencesGroup contents;
        private Gee.ArrayList<Widget> source_rows = new Gee.ArrayList<Widget> ();
        private ActionRow exclusions_row;
        private ActionRow schedule_row;
        private uint clock_tick = 0;
        private bool reloading = false;

        public OverviewPage (BackupsApp app) {
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

            var hero = new Box (Orientation.HORIZONTAL, 24);
            hero.add_css_class ("backups-hero");
            var dial = new Overlay ();
            ring = new CircularProgress (120);
            ring.fraction = 1;
            ring.label = "";
            dial.child = ring;
            hero_icon = new Image.from_icon_name ("dev.sinty.backups");
            hero_icon.pixel_size = 64;
            hero_icon.halign = Align.CENTER;
            hero_icon.valign = Align.CENTER;
            dial.add_overlay (hero_icon);
            dial.valign = Align.CENTER;
            hero.append (dial);
            var text = new Box (Orientation.VERTICAL, 4);
            text.valign = Align.CENTER;
            text.hexpand = true;
            state_label = new Label ("");
            state_label.add_css_class ("title-1");
            state_label.xalign = 0;
            state_label.wrap = true;
            text.append (state_label);
            last_label = new Label ("");
            last_label.xalign = 0;
            last_label.wrap = true;
            text.append (last_label);
            next_label = new Label ("");
            next_label.xalign = 0;
            next_label.add_css_class ("dim-label");
            next_label.wrap = true;
            text.append (next_label);
            item_label = new Label ("");
            item_label.xalign = 0;
            item_label.add_css_class ("dim-label");
            item_label.add_css_class ("caption");
            item_label.ellipsize = Pango.EllipsizeMode.MIDDLE;
            item_label.max_width_chars = 48;
            text.append (item_label);
            hero.append (text);
            content.append (hero);

            error_banner = new Banner ("", BannerStyle.ERROR);
            error_banner.button_label = _("Try Again");
            error_banner.button_clicked.connect (() => app.activate_action ("back-up-now", null));
            error_banner.visible = false;
            content.append (error_banner);
            waiting_banner = new Banner ("", BannerStyle.INFO);
            waiting_banner.visible = false;
            content.append (waiting_banner);
            warnings_banner = new Banner ("", BannerStyle.WARNING);
            warnings_banner.button_label = _("Details");
            warnings_banner.button_clicked.connect (() => show_warnings ());
            warnings_banner.visible = false;
            content.append (warnings_banner);

            var dest = new PreferencesGroup (_("Destination"));
            dest_row = new ActionRow ("", "", "drive-harddisk-usb");
            var change = new Button.with_label (_("Change…"));
            change.valign = Align.CENTER;
            change.clicked.connect (() => change_destination ());
            dest_row.add_suffix (change);
            dest.add_row (dest_row);
            var usage = new ListBoxRow ();
            usage.activatable = false;
            usage.selectable = false;
            var usage_box = new Box (Orientation.VERTICAL, 8);
            usage_box.add_css_class ("backups-usage");
            usage_bar = new LevelBar ();
            usage_bar.min_value = 0;
            usage_bar.max_value = 1;
            usage_bar.add_css_class ("disk-usage-bar");
            usage_label = new Label ("");
            usage_label.xalign = 0;
            usage_label.add_css_class ("dim-label");
            usage_label.wrap = true;
            usage_box.append (usage_bar);
            usage_box.append (usage_label);
            usage.child = usage_box;
            dest.add_row (usage);
            content.append (dest);

            var history = new PreferencesGroup (_("Backups"));
            browse_row = new ActionRow (_("Browse Backups"), "", "document-open-recent-symbolic");
            browse_row.add_suffix (new Image.from_icon_name ("go-next-symbolic"));
            browse_row.activatable = true;
            browse_row.activated.connect (() => browse_requested ());
            history.add_row (browse_row);
            verify_row = new ActionRow (_("Verify Backups"), _("Read every file of the latest backup and compare it with its checksum"), "emblem-ok-symbolic");
            verify_button = new Button.with_label (_("Verify"));
            verify_button.valign = Align.CENTER;
            verify_button.clicked.connect (() => verify.begin ());
            verify_row.add_suffix (verify_button);
            history.add_row (verify_row);
            content.append (history);

            contents = new PreferencesGroup (_("What to Back Up"));
            exclusions_row = new ActionRow (_("Excluded Items"), "");
            exclusions_row.add_suffix (new Image.from_icon_name ("go-next-symbolic"));
            exclusions_row.activatable = true;
            exclusions_row.activated.connect (() => exclusions_requested ());
            contents.add_row (exclusions_row);
            content.append (contents);

            var schedule = new PreferencesGroup (_("Schedule"));
            schedule_row = new ActionRow ("", "", "alarm-symbolic");
            var settings_button = new Button.with_label (_("Open Settings"));
            settings_button.valign = Align.CENTER;
            settings_button.clicked.connect (() => app.open_settings ());
            schedule_row.add_suffix (settings_button);
            schedule.add_row (schedule_row);
            content.append (schedule);

            scroll.child = new Clamp (content, 680);
            append (scroll);

            app.settings.changed.connect (() => refresh_settings ());
            map.connect (() => {
                if (clock_tick == 0) clock_tick = Timeout.add_seconds (30, () => {
                    refresh_state ();
                    return Source.CONTINUE;
                });
            });
            unmap.connect (() => {
                if (clock_tick != 0) Source.remove (clock_tick);
                clock_tick = 0;
            });
        }

        private static string frequency_label (string f) {
            switch (f) {
                case "daily": return _("Every day");
                case "weekly": return _("Every week");
                case "manual": return _("Only when you ask");
                default: return _("Every hour");
            }
        }

        private string destination_icon () {
            switch (app.settings.get_string ("destination-kind")) {
                case "folder": return "folder";
                case "network": return "folder-remote";
                case "cloud": return "folder-cloud";
                case "plugin": return app.settings.get_string ("destination-plugin") == "cloud" ? "folder-cloud" : "application-x-addon";
                default: return "drive-harddisk-usb";
            }
        }

        private void refresh_settings () {
            string kind = app.settings.get_string ("destination-kind");
            dest_row.title = app.settings.get_string ("destination-name");
            dest_row.icon_name = destination_icon ();
            string where = app.settings.get_string ("destination-path");
            if (kind == "disk") where = app.settings.get_boolean ("destination-encrypted") ? _("External disk, encrypted") : _("External disk");
            if (kind == "cloud") where = _("Online account");
            if (kind == "plugin") {
                bool cloud = app.settings.get_string ("destination-plugin") == "cloud";
                bool enc = app.settings.get_boolean ("destination-encrypted");
                where = cloud ? (enc ? _("Online account, encrypted") : _("Online account, not encrypted"))
                              : (enc ? _("Storage service, encrypted") : _("Storage service, not encrypted"));
                string repo = app.settings.get_string ("destination-repository");
                if (repo != "") where += " · " + _("Continues the backups of %s").printf (repo);
            }
            dest_row.subtitle = where;
            int n = app.settings.get_strv ("exclusions").length;
            exclusions_row.subtitle = n == 0 ? _("Nothing is excluded") : ngettext ("%d rule", "%d rules", n).printf (n);
            int keep = app.settings.get_int ("keep-last");
            schedule_row.title = frequency_label (app.settings.get_string ("frequency"));
            if (app.settings.get_string ("retention") == "keep-last") {
                schedule_row.subtitle = ngettext ("Keeps the latest backup", "Keeps the latest %d backups", keep).printf (keep);
            } else {
                schedule_row.subtitle = _("Keeps hourly backups for a day, daily for a month, weekly before that");
            }
        }

        public void refresh_state () {
            var d = app.daemon;
            if (d == null) return;
            string state = d.state;
            bool running = state == "backing-up" || state == "restoring" || state == "verifying";
            error_banner.visible = state == "error";
            error_banner.title = d.last_error;
            waiting_banner.visible = state == "waiting" || state == "paused";
            if (state == "paused") {
                waiting_banner.title = _("The battery is below %d%%. Backups continue when the computer is plugged in.").printf (app.settings.get_int ("battery-threshold"));
            } else {
                waiting_banner.title = _("Waiting for “%s”. The backup starts as soon as it is available.").printf (d.destination_name);
            }
            ring.fraction = running || state == "paused" ? d.fraction : 1.0;
            ring.remove_css_class ("backups-ring-error");
            ring.remove_css_class ("backups-ring-idle");
            ring.color = state == "error" ? "#e01b24" : Singularity.Style.StyleManager.get_default ().accent_hex;
            hero_icon.icon_name = destination_icon ();
            switch (state) {
                case "backing-up":
                    state_label.label = d.phase == "preparing" || d.phase == "scanning" ? _("Preparing Backup…")
                                      : _("Backing Up… %d%%").printf ((int) Math.round (d.fraction * 100));
                    break;
                case "restoring":
                    state_label.label = _("Restoring…");
                    break;
                case "verifying":
                    state_label.label = _("Verifying… %d%%").printf ((int) Math.round (d.fraction * 100));
                    break;
                case "error":
                    state_label.label = _("Backup Failed");
                    ring.add_css_class ("backups-ring-error");
                    break;
                case "waiting":
                    state_label.label = _("Waiting for the Destination");
                    ring.add_css_class ("backups-ring-idle");
                    break;
                case "paused":
                    state_label.label = _("Paused, Battery Low");
                    ring.add_css_class ("backups-ring-idle");
                    break;
                default:
                    state_label.label = d.last_backup > 0 ? _("Backed Up") : _("Ready to Back Up");
                    if (d.last_backup == 0) ring.add_css_class ("backups-ring-idle");
                    break;
            }
            last_label.label = _("Latest backup: %s").printf (relative_time (d.last_backup));
            string next_text = "";
            if (!running) {
                if (d.next_backup > 0) next_text = _("Next backup: %s").printf (relative_time (d.next_backup));
                else if (app.settings.get_string ("frequency") == "manual") next_text = _("Automatic backups are off");
            }
            next_label.label = next_text;
            next_label.visible = next_text != "";
            string item = "";
            if (running && d.current_item != "") item = Restorer.from_tree (d.current_item);
            item_label.label = item;
            item_label.visible = item != "";
            verify_button.sensitive = !running;
        }

        private async void reload_sources () {
            if (app.daemon == null) return;
            HashTable<string, Variant>[] providers = {};
            try {
                providers = yield app.daemon.list_providers ();
            } catch (Error e) {
                return;
            }
            foreach (var r in source_rows) contents.remove_row (r);
            source_rows.clear ();
            contents.remove_row (exclusions_row);
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
                contents.add_row (row);
                source_rows.add (row);
            }
            contents.add_row (exclusions_row);
        }

        public async void reload () {
            refresh_settings ();
            refresh_state ();
            if (source_rows.size == 0) reload_sources.begin ();
            if (app.daemon == null || reloading) return;
            reloading = true;
            try {
                var status = yield app.daemon.get_status ();
                if (get_bool (status, "available")) {
                    uint64 used = get_u64 (status, "used");
                    uint64 free = get_u64 (status, "free");
                    uint64 cap = get_u64 (status, "capacity");
                    usage_bar.value = cap > 0 ? (double) (cap - free) / cap : 0;
                    if (get_str (status, "store") == "remote") {
                        usage_label.label = cap > 0 ? _("Backups use %s, %s free in the account").printf (GLib.format_size (used), GLib.format_size (free))
                                                    : _("Backups use %s").printf (GLib.format_size (used));
                    } else {
                        usage_label.label = _("Backups use %s, %s free").printf (GLib.format_size (used), GLib.format_size (free));
                    }
                    int count = (int) get_int (status, "snapshots");
                    browse_row.subtitle = count == 0 ? _("No backups yet") : ngettext ("%d backup", "%d backups", count).printf (count);
                    if (count > 0) {
                        var snaps = yield app.daemon.list_snapshots ();
                        last_warnings = snaps.length > 0 ? get_strv (snaps[snaps.length - 1], "warnings") : new string[0];
                        int w = last_warnings.length;
                        warnings_banner.title = ngettext ("The latest backup finished with %d warning", "The latest backup finished with %d warnings", w).printf (w);
                        warnings_banner.visible = w > 0 && app.daemon.state != "error";
                        if (snaps.length > 0) {
                            browse_row.subtitle = ngettext ("%d backup, the oldest from %s", "%d backups, the oldest from %s", count)
                                .printf (count, relative_time (get_int (snaps[0], "created")).down ());
                        }
                    }
                } else {
                    usage_bar.value = 0;
                    usage_label.label = get_str (status, "unavailable-reason", _("The destination is not available"));
                    browse_row.subtitle = _("Connect the destination to browse your backups");
                }
            } catch (Error e) {
                usage_label.label = error_text (e);
            }
            reloading = false;
        }

        private void show_warnings () {
            var dialog = new ConfirmDialog.message (app, _("Warnings of the Latest Backup"), "dev.sinty.backups",
                _("These items were skipped. Everything else was backed up."));
            dialog.transient_for = (Gtk.Window) get_root ();
            dialog.modal = true;
            var list = new Box (Orientation.VERTICAL, 6);
            int shown = 0;
            foreach (string w in last_warnings) {
                if (shown++ >= 12) break;
                var label = new Label (w);
                label.xalign = 0;
                label.wrap = true;
                label.max_width_chars = 44;
                label.add_css_class ("caption");
                list.append (label);
            }
            if (last_warnings.length > 12) {
                var more = new Label (ngettext ("And %d more", "And %d more", last_warnings.length - 12).printf (last_warnings.length - 12));
                more.xalign = 0;
                more.add_css_class ("dim-label");
                list.append (more);
            }
            dialog.custom_area.append (list);
            dialog.present ();
        }

        public async void verify () {
            if (app.daemon == null) return;
            verify_button.sensitive = false;
            try {
                var r = yield app.daemon.verify ("");
                if (get_bool (r, "ok")) {
                    uint64 n = get_u64 (r, "checked");
                    toast (new Toast (ngettext ("The latest backup is intact: %s file checked", "The latest backup is intact: %s files checked", (ulong) n)
                                      .printf (n.to_string ())));
                } else {
                    int bad = get_strv (r, "damaged").length + get_strv (r, "missing").length;
                    error_banner.title = ngettext ("%d file in the latest backup is damaged. Back up now to replace it.",
                                                   "%d files in the latest backup are damaged. Back up now to replace them.", bad).printf (bad);
                    error_banner.visible = true;
                }
            } catch (Error e) {
                toast (new Toast (error_text (e)));
            }
            verify_button.sensitive = true;
        }
    }
}
