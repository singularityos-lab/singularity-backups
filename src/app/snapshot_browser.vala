using Gtk;
using Singularity.Widgets;

namespace Singularity.Backups {

    public class SnapshotBrowser : Box {
        public BackupsApp app { get; construct; }
        public string folder { get; private set; default = ""; }
        public SnapshotItem? snapshot { get; private set; default = null; }
        public bool changes_only { get; set; default = false; }
        public bool show_hidden { get; set; default = false; }

        public signal void folder_changed (string folder);
        public signal void preview_requested (EntryItem item);
        public signal void selection_changed ();

        private GLib.ListStore store = new GLib.ListStore (typeof (EntryItem));
        private Gtk.FilterListModel filtered;
        private Gtk.MultiSelection selection;
        private ListView list;
        private Stack body;
        private StatusPage empty;
        private Label title_label;
        private Label date_label;
        private Button up_button;
        private uint generation = 0;
        private Gee.List<EntryItem> all_items = new Gee.ArrayList<EntryItem> ();

        public SnapshotBrowser (BackupsApp app) {
            Object (app: app, orientation: Orientation.VERTICAL, spacing: 0);
        }

        construct {
            add_css_class ("tt-card");
            overflow = Overflow.HIDDEN;

            var header = new Box (Orientation.HORIZONTAL, 8);
            header.add_css_class ("tt-card-header");
            up_button = new Button.from_icon_name ("go-up-symbolic");
            up_button.tooltip_text = _("Enclosing Folder (Alt+Up)");
            up_button.add_css_class ("flat");
            up_button.clicked.connect (() => go_up ());
            header.append (up_button);
            var titles = new Box (Orientation.VERTICAL, 0);
            titles.hexpand = true;
            title_label = new Label ("");
            title_label.add_css_class ("heading");
            title_label.xalign = 0;
            title_label.ellipsize = Pango.EllipsizeMode.START;
            titles.append (title_label);
            date_label = new Label ("");
            date_label.add_css_class ("caption");
            date_label.add_css_class ("dim-label");
            date_label.xalign = 0;
            titles.append (date_label);
            header.append (titles);
            var changes = new ToggleButton.with_label (_("Changes Only"));
            changes.tooltip_text = _("Show only what changed in this backup");
            changes.valign = Align.CENTER;
            changes.bind_property ("active", this, "changes-only", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);
            header.append (changes);
            append (header);

            var columns = new Box (Orientation.HORIZONTAL, 12);
            columns.add_css_class ("tt-columns");
            var name_col = new Label (_("Name"));
            name_col.hexpand = true;
            name_col.xalign = 0;
            columns.append (name_col);
            var mod_col = new Label (_("Modified"));
            mod_col.width_chars = 16;
            mod_col.xalign = 0;
            columns.append (mod_col);
            var size_col = new Label (_("Size"));
            size_col.width_chars = 9;
            size_col.xalign = 1;
            columns.append (size_col);
            append (columns);

            var filter = new CustomFilter ((o) => {
                var e = (EntryItem) o;
                return !changes_only || e.change != "none";
            });
            filtered = new Gtk.FilterListModel (store, filter);
            notify["changes-only"].connect (() => {
                filter.changed (FilterChange.DIFFERENT);
                sync_empty ();
            });
            selection = new Gtk.MultiSelection (filtered);
            selection.selection_changed.connect (() => selection_changed ());

            var factory = new SignalListItemFactory ();
            factory.setup.connect ((obj) => {
                var li = (ListItem) obj;
                var row = new Box (Orientation.HORIZONTAL, 12);
                row.add_css_class ("tt-row");
                var icon = new Image ();
                icon.pixel_size = 24;
                row.append (icon);
                var name = new Label ("");
                name.xalign = 0;
                name.hexpand = true;
                name.ellipsize = Pango.EllipsizeMode.MIDDLE;
                row.append (name);
                var chip = new Label ("");
                chip.add_css_class ("tt-change");
                chip.valign = Align.CENTER;
                row.append (chip);
                var modified = new Label ("");
                modified.width_chars = 16;
                modified.xalign = 0;
                modified.add_css_class ("dim-label");
                row.append (modified);
                var size = new Label ("");
                size.width_chars = 9;
                size.xalign = 1;
                size.add_css_class ("dim-label");
                row.append (size);
                li.child = row;
            });
            factory.bind.connect ((obj) => {
                var li = (ListItem) obj;
                var e = (EntryItem) li.item;
                var row = (Box) li.child;
                var icon = (Image) row.get_first_child ();
                var name = (Label) icon.get_next_sibling ();
                var chip = (Label) name.get_next_sibling ();
                var modified = (Label) chip.get_next_sibling ();
                var size = (Label) modified.get_next_sibling ();
                icon.gicon = e.icon ();
                name.label = e.name;
                string text = change_label (e.change);
                chip.label = e.change == "contains" ? "" : text;
                chip.visible = e.change != "none";
                chip.tooltip_text = text;
                foreach (string c in new string[] { "added", "changed", "removed", "contains" }) chip.remove_css_class ("tt-change-" + c);
                chip.add_css_class ("tt-change-" + e.change);
                if (e.change == "removed") row.add_css_class ("tt-row-removed");
                else row.remove_css_class ("tt-row-removed");
                modified.label = e.modified_text ();
                size.label = e.size_text ();
                row.tooltip_text = e.change == "removed" ? _("Deleted after the previous backup. Restore brings back its last copy.") : null;
            });

            list = new ListView (selection, factory);
            list.add_css_class ("tt-list");
            list.activate.connect ((pos) => {
                var e = (EntryItem) filtered.get_item (pos);
                if (e.is_dir && e.change != "removed") open_folder (e.path);
                else preview_requested (e);
            });
            var keys = new EventControllerKey ();
            keys.propagation_phase = PropagationPhase.CAPTURE;
            keys.key_pressed.connect ((keyval, code, state) => {
                if (keyval == Gdk.Key.space) {
                    var sel = selected_items ();
                    if (sel.size > 0) preview_requested (sel[0]);
                    return true;
                }
                if (keyval == Gdk.Key.BackSpace || (keyval == Gdk.Key.Up && (state & Gdk.ModifierType.ALT_MASK) != 0)) {
                    go_up ();
                    return true;
                }
                return false;
            });
            list.add_controller (keys);

            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = list;

            empty = new StatusPage ();
            empty.compact = true;
            empty.icon_name = "folder";
            var loading = new Spinner ();
            loading.spinning = true;
            loading.halign = Align.CENTER;
            loading.valign = Align.CENTER;
            loading.width_request = 24;
            loading.height_request = 24;

            body = new Stack ();
            body.vexpand = true;
            body.add_named (scroll, "list");
            body.add_named (empty, "empty");
            body.add_named (loading, "loading");
            append (body);
        }

        public Gee.List<EntryItem> selected_items () {
            var result = new Gee.ArrayList<EntryItem> ();
            var bits = selection.get_selection ();
            for (uint i = 0; i < bits.get_size (); i++) {
                result.add ((EntryItem) filtered.get_item (bits.get_nth (i)));
            }
            return result;
        }

        public Gee.List<EntryItem> items () {
            return all_items;
        }

        public void select_name (string name) {
            for (uint i = 0; i < filtered.get_n_items (); i++) {
                var e = (EntryItem) filtered.get_item (i);
                if (e.name == name) {
                    selection.select_item (i, true);
                    list.scroll_to (i, ListScrollFlags.FOCUS | ListScrollFlags.SELECT, null);
                    return;
                }
            }
        }

        public void focus_list () {
            list.grab_focus ();
        }

        private void go_up () {
            if (folder == "") return;
            string parent = folder.contains ("/") ? Path.get_dirname (folder) : "";
            string child = Path.get_basename (folder);
            open_folder (parent, child);
        }

        public void open_folder (string path, string? select = null) {
            folder = path;
            folder_changed (path);
            load.begin (snapshot, select);
        }

        public async void show_snapshot (SnapshotItem item, string path, string? select = null) {
            folder = path;
            yield load (item, select);
        }

        private string folder_title () {
            if (folder == "") return _("Home");
            return Path.get_basename (folder);
        }

        private void sync_empty () {
            if (body.visible_child_name == "loading") return;
            if (filtered.get_n_items () > 0) {
                body.visible_child_name = "list";
                return;
            }
            if (all_items.size > 0 && changes_only) {
                empty.icon_name = "folder";
                empty.title = _("No Changes");
                empty.description = _("Nothing in this folder changed in this backup.");
            }
            body.visible_child_name = "empty";
        }

        private async void load (SnapshotItem? item, string? select) {
            if (item == null) return;
            uint gen = ++generation;
            snapshot = item;
            title_label.label = folder_title ();
            date_label.label = item.title ();
            up_button.sensitive = folder != "";
            var items = new Gee.ArrayList<EntryItem> ();
            string problem_title = "";
            string problem_text = "";
            var loading_timer = Timeout.add (150, () => {
                if (gen == generation) body.visible_child_name = "loading";
                return Source.REMOVE;
            });
            try {
                if (item.live) yield list_live (items);
                else {
                    foreach (var t in yield app.daemon.list_directory (item.id, folder)) {
                    var entry = new EntryItem.from_table (t);
                    if (entry.name.has_prefix (".") && !show_hidden) continue;
                    items.add (entry);
                }
                }
            } catch (Error e) {
                problem_title = item.live ? _("Not in Your Home Now") : _("Not in This Backup");
                problem_text = item.live ? _("This folder does not exist anymore. Go back in time to find it.")
                                         : _("This folder was not backed up at this time.");
            }
            if (gen != generation) return;
            Source.remove (loading_timer);
            items.sort ((a, b) => {
                if (a.is_dir != b.is_dir) return a.is_dir ? -1 : 1;
                return a.name.collate (b.name);
            });
            all_items = items;
            store.remove_all ();
            foreach (var e in items) store.append (e);
            body.visible_child_name = "list";
            if (problem_title != "") {
                empty.icon_name = "folder";
                empty.title = problem_title;
                empty.description = problem_text;
                body.visible_child_name = "empty";
            } else if (items.size == 0) {
                empty.icon_name = "folder";
                empty.title = _("Empty Folder");
                empty.description = _("There was nothing in this folder.");
                body.visible_child_name = "empty";
            } else {
                sync_empty ();
            }
            if (select != null) select_name (select);
        }

        private async void list_live (Gee.List<EntryItem> items) throws Error {
            var dir = File.new_for_path (Path.build_filename (Environment.get_home_dir (), folder));
            var enumerator = yield dir.enumerate_children_async ("standard::name,standard::type,standard::size,standard::content-type,time::modified",
                                                                 FileQueryInfoFlags.NOFOLLOW_SYMLINKS, Priority.DEFAULT, null);
            var known = new HashTable<string, EntryItem> (str_hash, str_equal);
            while (true) {
                var infos = yield enumerator.next_files_async (200, Priority.DEFAULT, null);
                if (infos == null) break;
                foreach (var info in infos) {
                    if (info.get_name ().has_prefix (".") && !show_hidden) continue;
                    var e = new EntryItem ();
                    e.name = info.get_name ();
                    e.path = folder == "" ? e.name : folder + "/" + e.name;
                    var type = info.get_file_type ();
                    e.kind = type == FileType.DIRECTORY ? "directory" : (type == FileType.SYMBOLIC_LINK ? "symlink" : "file");
                    e.size = (uint64) info.get_size ();
                    var dt = info.get_modification_date_time ();
                    e.mtime = dt != null ? dt.to_unix () : 0;
                    e.guess_type ();
                    known[e.name] = e;
                    items.add (e);
                }
            }
            var latest = latest_id ();
            var excluded = new Exclusions (app.settings.get_strv ("exclusions"));
            foreach (var e in items) {
                if (excluded.excluded (e.path)) e.origin = "excluded";
            }
            if (latest == "") return;
            try {
                foreach (var t in yield app.daemon.list_directory (latest, folder)) {
                    var old = new EntryItem.from_table (t);
                    if (old.change == "removed") continue;
                    if (old.name.has_prefix (".") && !show_hidden) continue;
                    var now = known[old.name];
                    if (now == null) {
                        old.change = "removed";
                        old.origin = latest;
                        items.add (old);
                    } else if (!now.is_dir && (now.size != old.size || now.mtime != old.mtime)) {
                        now.change = "changed";
                    }
                    if (now != null) now.origin = latest;
                }
                foreach (var e in items) {
                    if (e.origin == "" && e.change == "none") e.change = "added";
                    if (e.origin == "excluded") {
                        e.origin = "";
                        e.change = "none";
                    }
                }
            } catch (Error e) {
            }
        }

        public string latest_snapshot { get; set; default = ""; }

        private string latest_id () {
            return latest_snapshot;
        }
    }
}
