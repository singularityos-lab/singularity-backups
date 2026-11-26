namespace Singularity.Backups {

    public class BackupsApp : Singularity.Application, Singularity.Migration.Migratable, Singularity.Startup.Bootable {
        public DaemonProxy? daemon { get; private set; default = null; }
        public GLib.Settings settings { get; private set; }

        private BackupsWindow? window = null;
        private string? pending_browse = null;
        private string? pending_versions = null;

        public bool daemon_checked { get; private set; default = false; }

        public signal void daemon_ready ();

        public BackupsApp () {
            Object (application_id: "dev.sinty.backups", flags: ApplicationFlags.HANDLES_COMMAND_LINE);
            about_name = _("Backups");
            about_icon = "dev.sinty.backups";
            about_version = Config.VERSION;
            about_description = _("Automatic backups of your files, with a way back to any moment");
        }

        protected override void startup () {
            base.startup ();
            settings = new GLib.Settings ("dev.sinty.backups");
            Style.install ();

            var menu = new GLib.Menu ();
            var file_menu = new GLib.Menu ();
            var backup_section = new GLib.Menu ();
            backup_section.append (_("Back Up Now"), "win.back-up-now");
            backup_section.append (_("Browse Backups"), "win.browse");
            backup_section.append (_("Verify Backups"), "win.verify");
            file_menu.append_section (null, backup_section);
            var dest_section = new GLib.Menu ();
            dest_section.append (_("Change Destination…"), "win.change-destination");
            file_menu.append_section (null, dest_section);
            var close_section = new GLib.Menu ();
            close_section.append (_("Close Window"), "win.close");
            close_section.append (_("Quit"), "app.quit");
            file_menu.append_section (null, close_section);
            menu.append_submenu (_("File"), file_menu);
            var edit_menu = new GLib.Menu ();
            edit_menu.append (_("Settings"), "app.settings");
            menu.append_submenu (_("Edit"), edit_menu);
            set_menubar (menu);

            var quit_action = new SimpleAction ("quit", null);
            quit_action.activate.connect (() => quit ());
            add_action (quit_action);
            var settings_action = new SimpleAction ("settings", null);
            settings_action.activate.connect (() => open_settings ());
            add_action (settings_action);
            var browse = new SimpleAction ("browse", new VariantType ("as"));
            browse.activate.connect ((param) => open_uris (param.get_strv (), false));
            add_action (browse);
            var versions = new SimpleAction ("versions", new VariantType ("as"));
            versions.activate.connect ((param) => open_uris (param.get_strv (), true));
            add_action (versions);
            var browse_home = new SimpleAction ("browse-home", null);
            browse_home.activate.connect (() => {
                pending_browse = "";
                show_window ();
            });
            add_action (browse_home);
            var back_up = new SimpleAction ("back-up-now", null);
            back_up.activate.connect (() => {
                if (daemon == null) return;
                try {
                    daemon.back_up_now ();
                } catch (Error e) {
                    warning ("Backups: %s", error_text (e));
                }
            });
            add_action (back_up);
            var show = new SimpleAction ("show", null);
            show.activate.connect (() => show_window ());
            add_action (show);

            set_accels_for_action ("app.settings", { "<Control>comma" });
            set_accels_for_action ("win.close", { "<Control>w" });
            set_accels_for_action ("win.back-up-now", { "<Control>b" });
            set_accels_for_action ("win.browse", { "<Control>t" });

            BackupsIntents.install (this);

            hold ();
            Bus.get_proxy.begin<DaemonProxy> (BusType.SESSION, DAEMON_NAME, DAEMON_PATH, DBusProxyFlags.NONE, null, (o, r) => {
                try {
                    daemon = Bus.get_proxy.end<DaemonProxy> (r);
                } catch (Error e) {
                    warning ("Backups: the backup service is not available: %s", e.message);
                }
                release ();
                daemon_checked = true;
                daemon_ready ();
            });
        }

        public void open_settings () {
            try {
                Singularity.Shell.ShellService shell = Bus.get_proxy_sync (BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                shell.open_app_settings ("dev.sinty.backups");
            } catch (Error e) {
                warning ("Backups: cannot open Settings: %s", e.message);
            }
        }

        private void open_uris (string[] uris, bool versions) {
            if (uris.length == 0) {
                show_window ();
                return;
            }
            var file = File.new_for_uri (uris[0]);
            string rel = home_relative (file);
            if (versions) pending_versions = rel;
            else pending_browse = rel;
            show_window ();
        }

        protected override int command_line (ApplicationCommandLine command_line) {
            string[] args = command_line.get_arguments ();
            if ("--back-up-now" in args) {
                activate_action ("back-up-now", null);
                return 0;
            }
            for (int i = 1; i < args.length; i++) {
                if ((args[i] == "--browse" || args[i] == "--versions") && i + 1 < args.length) {
                    var file = command_line.create_file_for_arg (args[i + 1]);
                    open_uris ({ file.get_uri () }, args[i] == "--versions");
                    return 0;
                }
            }
            activate ();
            return 0;
        }

        public Singularity.Startup.Plan build_plan (Singularity.Startup.Request request) {
            var plan = new Singularity.Startup.Plan ();
            plan.version = "backups-1";
            if (request.kind == Singularity.Startup.RequestKind.SERVICE) {
                plan.main ("ready", Singularity.Startup.Category.PREPARE, (c) => {})
                    .reaches (Singularity.Startup.Milestone.SHELL_READY)
                    .reaches (Singularity.Startup.Milestone.CONTENT_READY)
                    .reaches (Singularity.Startup.Milestone.INTERACTIVE);
                return plan;
            }
            plan.main ("window", Singularity.Startup.Category.SHELL, (c) => {
                show_window ();
                c.window = get_active_window ();
            }).reaches (Singularity.Startup.Milestone.SHELL_READY)
              .reaches (Singularity.Startup.Milestone.CONTENT_READY)
              .reaches (Singularity.Startup.Milestone.INTERACTIVE);
            return plan;
        }

        public void handle_request (Singularity.Startup.Request request) {
            show_window ();
        }

        private void show_window () {
            if (window == null) adopt (new BackupsWindow (this));
            window.present ();
            if (pending_browse != null || pending_versions != null) {
                string? b = pending_browse;
                string? v = pending_versions;
                pending_browse = null;
                pending_versions = null;
                window.open_time_travel (v ?? b, v != null);
            }
        }

        private void adopt (BackupsWindow w) {
            window = w;
            w.close_request.connect (() => {
                if (window == w) window = null;
                return false;
            });
        }

        public Variant save_model () {
            return new VariantDict ().end ();
        }

        public async void restore_model (Variant model) throws Error {
        }

        public string window_kind (Gtk.Window w) {
            return (w is BackupsWindow) ? "backups" : "";
        }

        public Variant save_window (Gtk.Window w) {
            return ((BackupsWindow) w).save_migration ();
        }

        public async Gtk.Window? rebuild_window (string kind, Variant data) throws Error {
            if (kind != "backups") return null;
            if (window != null) window.destroy ();
            var w = new BackupsWindow (this);
            adopt (w);
            yield w.restore_migration (data);
            return w;
        }

        public static int main (string[] args) {
            Intl.setlocale (LocaleCategory.ALL, "");
            Intl.bindtextdomain ("singularity-backups", Config.LOCALEDIR);
            Intl.bind_textdomain_codeset ("singularity-backups", "UTF-8");
            Intl.textdomain ("singularity-backups");
            return new BackupsApp ().run (args);
        }
    }
}
