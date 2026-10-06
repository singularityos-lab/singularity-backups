using Gtk;
using Singularity.Widgets;

namespace Singularity.Backups {

    public class ExclusionsPage : Box {
        public BackupsApp app { get; construct; }

        private PreferencesGroup list_group;
        private Gee.ArrayList<Widget> rows = new Gee.ArrayList<Widget> ();
        private EntryRow add_row;

        public ExclusionsPage (BackupsApp app) {
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

            var heading = new Label (_("Excluded Items"));
            heading.add_css_class ("title-1");
            heading.xalign = 0;
            content.append (heading);
            var intro = new Label (_("These files and folders are never backed up. Caches and temporary files are excluded to save space."));
            intro.add_css_class ("dim-label");
            intro.xalign = 0;
            intro.wrap = true;
            content.append (intro);

            var add_group = new PreferencesGroup (_("Add an Exclusion"),
                _("A name such as node_modules matches everywhere, a path such as /Videos/Raw starts at your home folder, and * matches any text."));
            add_row = new EntryRow (_("Name or Pattern"));
            var add_button = new Button.with_label (_("Add"));
            add_button.valign = Align.CENTER;
            add_button.clicked.connect (() => add_pattern (add_row.text));
            add_row.entry_activated.connect (() => add_pattern (add_row.text));
            add_row.add_suffix (add_button);
            add_group.add_row (add_row);
            var folder_row = new ActionRow (_("A Folder in Your Home"), _("Pick a folder to leave out, such as a large downloads folder"), "folder");
            var choose = new Button.with_label (_("Choose…"));
            choose.valign = Align.CENTER;
            choose.clicked.connect (() => choose_folder.begin ());
            folder_row.add_suffix (choose);
            add_group.add_row (folder_row);
            content.append (add_group);

            list_group = new PreferencesGroup (_("Current Exclusions"));
            var reset = new Button.with_label (_("Restore Defaults"));
            reset.clicked.connect (() => {
                app.settings.reset ("exclusions");
                load ();
            });
            list_group.add_header_suffix (reset);
            content.append (list_group);

            scroll.child = new Clamp (content, 640);
            append (scroll);
        }

        public void load () {
            foreach (var r in rows) list_group.remove_row (r);
            rows.clear ();
            string[] patterns = app.settings.get_strv ("exclusions");
            if (patterns.length == 0) {
                var empty = new StatusPage ();
                empty.compact = true;
                empty.icon_name = "user-home";
                empty.title = _("Everything Is Backed Up");
                empty.description = _("Your whole home folder is copied, caches included.");
                var holder = new ListBoxRow ();
                holder.activatable = false;
                holder.selectable = false;
                holder.child = empty;
                list_group.add_row (holder);
                rows.add (holder);
                return;
            }
            foreach (string p in patterns) {
                string pattern = p;
                var row = new ActionRow (pattern, describe (pattern), pattern.has_prefix ("/") ? "folder-symbolic" : "edit-find-symbolic");
                var remove = new Button.from_icon_name ("user-trash-symbolic");
                remove.tooltip_text = _("Back Up Again");
                remove.valign = Align.CENTER;
                remove.add_css_class ("flat");
                remove.clicked.connect (() => {
                    string[] kept = {};
                    foreach (string e in app.settings.get_strv ("exclusions")) if (e != pattern) kept += e;
                    app.settings.set_strv ("exclusions", kept);
                    load ();
                });
                row.add_suffix (remove);
                list_group.add_row (row);
                rows.add (row);
            }
        }

        private static string describe (string pattern) {
            if (pattern.has_prefix ("/")) return _("This folder in your home");
            if (pattern.contains ("*") || pattern.contains ("?")) return _("Every name that matches");
            if (pattern.contains ("/")) return _("This path, wherever it appears");
            return _("Every file or folder with this name");
        }

        private void add_pattern (string raw) {
            string p = raw.strip ();
            if (p == "") return;
            string[] list = app.settings.get_strv ("exclusions");
            if (!(p in list)) list += p;
            app.settings.set_strv ("exclusions", list);
            add_row.text = "";
            load ();
        }

        private async void choose_folder () {
            var dialog = new FileDialog ();
            dialog.title = _("Choose a Folder to Exclude");
            dialog.initial_folder = File.new_for_path (Environment.get_home_dir ());
            try {
                var folder = yield dialog.select_folder ((Gtk.Window) get_root (), null);
                string rel = home_relative (folder);
                if (rel.has_prefix ("\x01") || rel == "") {
                    var root = get_root () as Singularity.Widgets.Window;
                    if (root != null) root.add_toast (new Toast (_("Choose a folder inside your home folder")));
                    return;
                }
                add_pattern ("/" + rel);
            } catch (Error e) {
            }
        }
    }
}
