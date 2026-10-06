using Gtk;
using Singularity;
using Singularity.Backups;

[ModuleInit]
public void peas_register_types (TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type (typeof (Singularity.Plugin), typeof (BackupsStatus.StatusPlugin));
}

namespace BackupsStatus {

    public class StatusPlugin : Object, Singularity.Plugin {
        private PluginContext context;
        private QuickTile tile;
        private MenuButton indicator;
        private Singularity.Widgets.CircularProgress ring;
        private Label popover_title;
        private Label popover_detail;
        private DaemonProxy? daemon = null;
        private uint watch = 0;
        private Label? detail_state = null;
        private Label? detail_times = null;
        private ProgressBar? detail_bar = null;
        private Button? detail_action = null;

        public void activate (PluginContext context) {
            this.context = context;
            string locale_dir = "/usr/share/locale";
            try {
                string exe = FileUtils.read_link ("/proc/self/exe");
                locale_dir = Path.build_filename (Path.get_dirname (Path.get_dirname (exe)), "share", "locale");
            } catch (Error e) {
            }
            Intl.bindtextdomain ("singularity-backups", locale_dir);
            Intl.bind_textdomain_codeset ("singularity-backups", "UTF-8");

            tile = new QuickTile ("dev.sinty.backups.status", _("Backups"), "document-open-recent-symbolic");
            tile.toggleable = false;
            tile.detail_title = _("Backups");
            tile.clicked.connect (() => {
                if (daemon == null || !daemon.configured) {
                    open_app (null);
                    return;
                }
                if (daemon.state == "backing-up") return;
                try {
                    daemon.back_up_now ();
                } catch (Error e) {
                    warning ("backups tile: %s", e.message);
                }
            });
            tile.set_detail_page (() => build_detail ());
            context.add_quick_tile (tile);

            indicator = new MenuButton ();
            indicator.add_css_class ("flat");
            indicator.add_css_class ("panel-button");
            ring = new Singularity.Widgets.CircularProgress (16);
            ring.valign = Align.CENTER;
            indicator.child = ring;
            var box = new Box (Orientation.VERTICAL, 6);
            box.margin_start = 12;
            box.margin_end = 12;
            box.margin_top = 10;
            box.margin_bottom = 10;
            popover_title = new Label ("");
            popover_title.add_css_class ("heading");
            popover_title.xalign = 0;
            box.append (popover_title);
            popover_detail = new Label ("");
            popover_detail.add_css_class ("dim-label");
            popover_detail.xalign = 0;
            popover_detail.wrap = true;
            popover_detail.max_width_chars = 32;
            box.append (popover_detail);
            var buttons = new Box (Orientation.HORIZONTAL, 8);
            buttons.halign = Align.END;
            buttons.margin_top = 6;
            var stop = new Button.with_label (_("Stop"));
            stop.add_css_class ("pill");
            stop.clicked.connect (() => {
                try {
                    if (daemon != null) daemon.cancel ();
                } catch (Error e) {
                    warning ("backups indicator: %s", e.message);
                }
            });
            buttons.append (stop);
            var open = new Button.with_label (_("Open Backups"));
            open.add_css_class ("pill");
            open.clicked.connect (() => open_app (null));
            buttons.append (open);
            box.append (buttons);
            var popover = new Popover ();
            popover.child = box;
            indicator.popover = popover;
            indicator.visible = false;
            context.add_panel_widget (indicator, Align.END);

            var flags = BusNameWatcherFlags.NONE;
            var source = SettingsSchemaSource.get_default ();
            if (source != null && source.lookup ("dev.sinty.backups", true) != null) {
                if (new GLib.Settings ("dev.sinty.backups").get_string ("destination-kind") != "") flags = BusNameWatcherFlags.AUTO_START;
            }
            watch = Bus.watch_name (BusType.SESSION, DAEMON_NAME, flags,
                () => connect_daemon.begin (), () => {
                    daemon = null;
                    update ();
                });
            update ();
        }

        public void deactivate () {
            if (watch != 0) Bus.unwatch_name (watch);
            watch = 0;
            context.remove_quick_tile (tile);
            context.remove_panel_widget (indicator);
            daemon = null;
        }

        public Gtk.Widget? get_settings_widget () {
            return null;
        }

        private async void connect_daemon () {
            try {
                daemon = yield Bus.get_proxy<DaemonProxy> (BusType.SESSION, DAEMON_NAME, DAEMON_PATH, DBusProxyFlags.DO_NOT_AUTO_START);
                ((DBusProxy) daemon).g_properties_changed.connect (() => update ());
                daemon.progress.connect (() => update ());
            } catch (Error e) {
                daemon = null;
            }
            update ();
        }

        private void open_app (string? action) {
            Bus.get.begin (BusType.SESSION, null, (o, r) => {
                try {
                    var bus = Bus.get.end (r);
                    var platform = new VariantBuilder (new VariantType ("a{sv}"));
                    if (action == null) {
                        bus.call.begin ("dev.sinty.backups", "/dev/sinty/backups", "org.freedesktop.Application", "Activate",
                            new Variant ("(@a{sv})", platform.end ()), null, DBusCallFlags.NONE, 20000, null);
                    } else {
                        bus.call.begin ("dev.sinty.backups", "/dev/sinty/backups", "org.freedesktop.Application", "ActivateAction",
                            new Variant ("(s@av@a{sv})", action, new Variant.array (VariantType.VARIANT, {}), platform.end ()),
                            null, DBusCallFlags.NONE, 20000, null);
                    }
                } catch (Error e) {
                    warning ("backups tile: %s", e.message);
                }
            });
        }

        private string state_text (out string detail) {
            detail = "";
            if (daemon == null || !daemon.configured) {
                detail = _("Choose a disk or folder to start");
                return _("Not Set Up");
            }
            switch (daemon.state) {
                case "backing-up":
                    detail = daemon.current_item != "" ? Restorer.from_tree (daemon.current_item) : "";
                    return _("Backing Up, %d%%").printf ((int) Math.round (daemon.fraction * 100));
                case "restoring":
                    return _("Restoring");
                case "verifying":
                    return _("Verifying, %d%%").printf ((int) Math.round (daemon.fraction * 100));
                case "error":
                    detail = daemon.last_error;
                    return _("Backup Failed");
                case "waiting":
                    detail = _("Waiting for “%s”").printf (daemon.destination_name);
                    return _("Waiting");
                case "paused":
                    detail = _("Continues when the computer is plugged in");
                    return _("Paused, Battery Low");
                default:
                    detail = _("Latest backup: %s").printf (relative_time (daemon.last_backup));
                    return daemon.last_backup > 0 ? _("Backed Up") : _("Ready");
            }
        }

        private void update () {
            string detail;
            string title = state_text (out detail);
            bool running = daemon != null && (daemon.state == "backing-up" || daemon.state == "restoring" || daemon.state == "verifying");
            tile.active = running;
            string subtitle = title;
            if (!running && daemon != null && daemon.configured && daemon.last_backup > 0) subtitle = relative_time (daemon.last_backup);
            tile.subtitle = subtitle;
            indicator.visible = running;
            ring.fraction = running ? daemon.fraction : 0;
            ring.color = Singularity.Style.StyleManager.get_default ().accent_hex;
            indicator.tooltip_text = title;
            popover_title.label = title;
            popover_detail.label = detail;
            popover_detail.visible = detail != "";
            if (detail_state != null) {
                detail_state.label = title;
                detail_times.label = detail;
                detail_bar.visible = running;
                detail_bar.fraction = running ? daemon.fraction : 0;
                string action = _("Set Up Backups");
                if (running) action = _("Stop");
                else if (daemon != null && daemon.configured) action = _("Back Up Now");
                detail_action.label = action;
            }
        }

        private Gtk.Widget build_detail () {
            var box = new Box (Orientation.VERTICAL, 12);
            box.margin_top = 12;
            box.margin_bottom = 12;
            box.margin_start = 12;
            box.margin_end = 12;
            var icon = new Image.from_icon_name ("dev.sinty.backups");
            icon.pixel_size = 64;
            box.append (icon);
            detail_state = new Label ("");
            detail_state.add_css_class ("title-3");
            detail_state.wrap = true;
            detail_state.justify = Justification.CENTER;
            box.append (detail_state);
            detail_times = new Label ("");
            detail_times.add_css_class ("dim-label");
            detail_times.wrap = true;
            detail_times.justify = Justification.CENTER;
            detail_times.ellipsize = Pango.EllipsizeMode.MIDDLE;
            detail_times.max_width_chars = 34;
            box.append (detail_times);
            detail_bar = new ProgressBar ();
            box.append (detail_bar);
            var buttons = new FlowBox ();
            buttons.selection_mode = SelectionMode.NONE;
            buttons.max_children_per_line = 2;
            buttons.min_children_per_line = 1;
            buttons.column_spacing = 8;
            buttons.row_spacing = 8;
            buttons.homogeneous = true;
            detail_action = new Button.with_label ("");
            detail_action.add_css_class ("pill");
            detail_action.add_css_class ("suggested-action");
            detail_action.clicked.connect (() => {
                if (daemon == null || !daemon.configured) {
                    open_app (null);
                    return;
                }
                try {
                    if (daemon.state == "backing-up") daemon.cancel ();
                    else daemon.back_up_now ();
                } catch (Error e) {
                    warning ("backups tile: %s", e.message);
                }
            });
            buttons.append (detail_action);
            var browse = new Button.with_label (_("Browse Backups"));
            browse.add_css_class ("pill");
            browse.clicked.connect (() => open_app ("browse-home"));
            buttons.append (browse);
            box.append (buttons);
            box.destroy.connect (() => {
                detail_state = null;
                detail_times = null;
                detail_bar = null;
                detail_action = null;
            });
            update ();
            return box;
        }
    }
}
