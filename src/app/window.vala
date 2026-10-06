using Gtk;
using Singularity.Widgets;

namespace Singularity.Backups {

    public class BackupsWindow : Singularity.Widgets.Window {
        public BackupsApp app { get; construct; }

        private Stack stack;
        private SetupPage setup_page;
        private OverviewPage overview_page;
        private ExclusionsPage exclusions_page;
        private TimeTravelView? time_travel = null;
        private StatusPage unavailable_page;
        private Button back_bubble;
        private Button start_bubble;
        private Button browse_bubble;
        private Button back_up_bubble;
        private Button stop_bubble;
        private string before_exclusions = "overview";
        private bool was_fullscreen = false;
        private string? pending_path = null;
        private bool pending_versions = false;

        public BackupsWindow (BackupsApp app) {
            Object (application: app, app: app);
            set_title (_("Backups"));
            set_default_size (920, 680);
            add_css_class ("backups-window");

            stack = new Stack ();
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.transition_duration = Singularity.Motion.Duration.MEDIUM.ms ();
            stack.add_css_class ("backups-pages");

            var loading = new Spinner ();
            loading.spinning = true;
            loading.halign = Align.CENTER;
            loading.valign = Align.CENTER;
            loading.width_request = 32;
            loading.height_request = 32;
            stack.add_named (loading, "loading");
            stack.add_named (build_welcome (), "welcome");

            setup_page = new SetupPage (app);
            setup_page.finished.connect (() => show_page ("overview"));
            setup_page.exclusions_requested.connect (() => open_exclusions ("setup"));
            stack.add_named (setup_page, "setup");

            overview_page = new OverviewPage (app);
            overview_page.browse_requested.connect (() => open_time_travel (null, false));
            overview_page.exclusions_requested.connect (() => open_exclusions ("overview"));
            overview_page.change_destination.connect (() => show_page ("welcome"));
            overview_page.toast.connect ((t) => add_toast (t));
            stack.add_named (overview_page, "overview");

            exclusions_page = new ExclusionsPage (app);
            stack.add_named (exclusions_page, "exclusions");

            unavailable_page = new StatusPage ();
            unavailable_page.icon_name = "dev.sinty.backups";
            unavailable_page.title = _("Backups Cannot Start");
            unavailable_page.description = _("The backup service is not installed or did not respond. Reinstall Backups or ask the person who manages this computer.");
            stack.add_named (unavailable_page, "unavailable");

            set_content (stack);

            back_bubble = add_bubble_icon ("go-previous-symbolic", _("Back"), () => go_back ());
            browse_bubble = add_bubble_icon ("document-open-recent-symbolic", _("Browse Backups (Ctrl+T)"), () => open_time_travel (null, false));
            stop_bubble = add_bubble_text (_("Stop"), () => {
                try {
                    app.daemon.cancel ();
                } catch (Error e) {
                    warning ("Backups: %s", error_text (e));
                }
            });
            back_up_bubble = add_bubble_suggested (_("Back Up Now"), () => back_up_now ());
            start_bubble = add_bubble_suggested (_("Start Backups"), () => setup_page.commit.begin ());

            var entries = new ActionEntry[] {
                { "back-up-now", () => back_up_now () },
                { "browse", () => open_time_travel (null, false) },
                { "verify", () => overview_page.verify.begin () },
                { "change-destination", () => show_page ("welcome") },
                { "close", () => close () }
            };
            add_action_entries (entries, this);

            stack.notify["visible-child-name"].connect (() => sync_bubbles ());
            setup_page.notify["can-commit"].connect (() => sync_bubbles ());
            show_page ("loading");

            if (app.daemon != null) on_daemon ();
            else app.daemon_ready.connect (on_daemon);

            close_request.connect (() => {
                if (time_travel != null) time_travel.shutdown ();
                return false;
            });
        }

        private Widget build_welcome () {
            var wp = new WelcomePage ();
            wp.app_icon_name = "dev.sinty.backups";
            wp.title = _("Backups");
            wp.subtitle = _("Keep automatic copies of your files, then go back in time to recover anything you lose or change by mistake");
            wp.add_action ("drive-harddisk-usb", _("Back Up to a Disk"),
                _("An external drive that you connect from time to time"), () => start_setup ("disk"));
            wp.add_action ("folder", _("Back Up to a Folder"),
                _("A folder on another internal disk or partition"), () => start_setup ("folder"));
            wp.add_action ("folder-remote", _("Back Up to a Network Share"),
                _("A shared folder on your network, once connected"), () => start_setup ("network"));
            wp.add_action ("folder-cloud", _("Back Up to an Online Account"),
                _("The files of an account in Settings, Online Accounts"), () => start_setup ("cloud"));
            bool other_services = false;
            foreach (var m in PluginRegistry.discover (PluginKind.DESTINATION)) if (m.id != "cloud") other_services = true;
            if (other_services) {
                wp.add_action ("application-x-addon", _("Back Up to Another Service"),
                    _("A storage service added by a backup plugin"), () => start_setup ("remote"));
            }
            return wp;
        }

        private void on_daemon () {
            if (app.daemon == null) {
                show_page ("unavailable");
                return;
            }
            ((DBusProxy) app.daemon).g_properties_changed.connect (() => {
                sync_bubbles ();
                overview_page.refresh_state ();
            });
            app.daemon.snapshots_changed.connect (() => overview_page.reload.begin ());
            app.daemon.failed.connect (() => overview_page.refresh_state ());
            if (app.daemon.configured) {
                overview_page.reload.begin ();
                show_page ("overview");
            } else {
                show_page ("welcome");
            }
            if (pending_path != null || pending_versions) {
                string? p = pending_path;
                pending_path = null;
                bool v = pending_versions;
                pending_versions = false;
                open_time_travel (p, v);
            }
        }

        private void start_setup (string kind) {
            setup_page.begin_setup.begin (kind);
            show_page ("setup");
        }

        private void open_exclusions (string from) {
            before_exclusions = from;
            exclusions_page.load ();
            show_page ("exclusions");
        }

        public void show_page (string name) {
            if (name == "overview") overview_page.reload.begin ();
            stack.visible_child_name = name;
            sync_bubbles ();
        }

        private void go_back () {
            string page = stack.visible_child_name;
            if (page == "exclusions") {
                if (before_exclusions == "setup") setup_page.refresh_exclusions ();
                else overview_page.reload.begin ();
                show_page (before_exclusions);
            } else if (page == "setup") {
                show_page ("welcome");
            } else if (page == "welcome" && app.daemon != null && app.daemon.configured) {
                show_page ("overview");
            }
        }

        private void sync_bubbles () {
            string page = stack.visible_child_name ?? "";
            bool configured = app.daemon != null && app.daemon.configured;
            string state = app.daemon != null ? app.daemon.state : "";
            bool busy = state == "backing-up" || state == "restoring" || state == "verifying";
            back_bubble.visible = page == "setup" || page == "exclusions" || (page == "welcome" && configured);
            start_bubble.visible = page == "setup";
            start_bubble.sensitive = setup_page.can_commit;
            browse_bubble.visible = page == "overview";
            back_up_bubble.visible = page == "overview" && state != "backing-up";
            back_up_bubble.sensitive = !busy;
            stop_bubble.visible = page == "overview" && state == "backing-up";
            var browse = lookup_action ("browse") as SimpleAction;
            if (browse != null) browse.set_enabled (configured);
            var backup = lookup_action ("back-up-now") as SimpleAction;
            if (backup != null) backup.set_enabled (configured && !busy);
            var verify = lookup_action ("verify") as SimpleAction;
            if (verify != null) verify.set_enabled (configured && !busy);
        }

        private void back_up_now () {
            if (app.daemon == null) return;
            try {
                app.daemon.back_up_now ();
            } catch (Error e) {
                add_toast (new Toast (error_text (e)));
            }
        }

        public void open_time_travel (string? path, bool versions) {
            if (app.daemon == null) {
                pending_path = path;
                pending_versions = versions;
                return;
            }
            if (!app.daemon.configured) {
                add_toast (new Toast (_("Set up backups first to browse them")));
                show_page ("welcome");
                return;
            }
            if (path != null && path.has_prefix ("\x01")) {
                add_toast (new Toast (_("Only files in your home folder are backed up")));
                path = null;
                versions = false;
            }
            if (time_travel != null) {
                time_travel.open_at.begin (path ?? "", versions);
                return;
            }
            string folder = path ?? "";
            string? select = null;
            if (path != null && path != "") {
                var f = File.new_for_path (Path.build_filename (Environment.get_home_dir (), path));
                if (versions || f.query_file_type (FileQueryInfoFlags.NOFOLLOW_SYMLINKS) != FileType.DIRECTORY) {
                    folder = path.contains ("/") ? Path.get_dirname (path) : "";
                    select = Path.get_basename (path);
                }
            }
            time_travel = new TimeTravelView (app, this);
            time_travel.exit_requested.connect (() => close_time_travel ());
            time_travel.toast.connect ((t) => add_toast (t));
            stack.add_named (time_travel, "timetravel");
            was_fullscreen = fullscreened;
            add_css_class ("time-travel-mode");
            stack.visible_child_name = "timetravel";
            sync_bubbles ();
            set_bubbles_visible (false);
            time_travel.start.begin (folder, select, versions);
        }

        private void set_bubbles_visible (bool shown) {
            foreach (var b in new Button[] { back_bubble, start_bubble, browse_bubble, back_up_bubble, stop_bubble }) {
                if (!shown) b.visible = false;
            }
            if (shown) sync_bubbles ();
        }

        public void close_time_travel () {
            if (time_travel == null) return;
            var leaving = time_travel;
            time_travel = null;
            leaving.shutdown ();
            remove_css_class ("time-travel-mode");
            if (!was_fullscreen && fullscreened) unfullscreen ();
            show_page (app.daemon != null && app.daemon.configured ? "overview" : "welcome");
            set_bubbles_visible (true);
            Timeout.add (Singularity.Motion.Duration.PAGE.ms () + 50, () => {
                stack.remove (leaving);
                return Source.REMOVE;
            });
        }
    }
}
