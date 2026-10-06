namespace Singularity.Backups {

    public class SnapshotItem : Object {
        public string id { get; set; default = ""; }
        public int64 created { get; set; default = 0; }
        public bool live { get; set; default = false; }
        public bool has_version { get; set; default = false; }
        public uint64 added_bytes { get; set; default = 0; }
        public string[] warnings { get; set; default = {}; }
        public string[] providers { get; set; default = {}; }
        public Gdk.Paintable? image { get; set; default = null; }
        public string image_path { get; set; default = ""; }

        public SnapshotItem.now () {
            live = true;
            created = new DateTime.now_utc ().to_unix ();
        }

        public SnapshotItem.from_table (HashTable<string, Variant> t) {
            id = get_str (t, "id");
            created = get_int (t, "created");
            added_bytes = get_u64 (t, "added-bytes");
            warnings = get_strv (t, "warnings");
            providers = get_strv (t, "providers");
        }

        public string title () {
            if (live) return _("Today (Now)");
            var dt = new DateTime.from_unix_local (created);
            var now = new DateTime.now_local ();
            string time = dt.format ("%H:%M");
            if (dt.get_year () == now.get_year () && dt.get_day_of_year () == now.get_day_of_year ()) return _("Today, %s").printf (time);
            var yesterday = now.add_days (-1);
            if (dt.get_year () == yesterday.get_year () && dt.get_day_of_year () == yesterday.get_day_of_year ()) return _("Yesterday, %s").printf (time);
            if (dt.get_year () == now.get_year ()) return "%s, %s".printf (dt.format ("%A %e %B").replace ("  ", " "), time);
            return "%s, %s".printf (dt.format ("%e %B %Y").strip (), time);
        }

        public string short_title () {
            if (live) return _("Now");
            var dt = new DateTime.from_unix_local (created);
            var now = new DateTime.now_local ();
            if (dt.get_year () == now.get_year () && dt.get_day_of_year () == now.get_day_of_year ()) return dt.format ("%H:%M");
            if (dt.get_year () == now.get_year ()) return dt.format ("%e %b").strip ();
            return dt.format ("%b %Y");
        }

        public string day_key () {
            return new DateTime.from_unix_local (created).format ("%Y-%j");
        }
    }

    public class EntryItem : Object {
        public string path { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string kind { get; set; default = "file"; }
        public uint64 size { get; set; default = 0; }
        public int64 mtime { get; set; default = 0; }
        public string change { get; set; default = "none"; }
        public string origin { get; set; default = ""; }
        public string content_type { get; set; default = ""; }

        public bool is_dir {
            get { return kind == "directory"; }
        }

        public EntryItem.from_table (HashTable<string, Variant> t) {
            path = get_str (t, "path");
            name = get_str (t, "name");
            kind = get_str (t, "kind", "file");
            size = get_u64 (t, "size");
            mtime = get_int (t, "mtime");
            change = get_str (t, "change", "none");
            origin = get_str (t, "origin");
            guess_type ();
        }

        public void guess_type () {
            if (is_dir) {
                content_type = "inode/directory";
                return;
            }
            if (kind == "symlink") {
                content_type = "inode/symlink";
                return;
            }
            bool uncertain;
            content_type = ContentType.guess (name, null, out uncertain);
        }

        public GLib.Icon icon () {
            if (is_dir) {
                switch (path) {
                    case "Documents": return new ThemedIcon ("folder-documents");
                    case "Pictures": return new ThemedIcon ("folder-pictures");
                    case "Music": return new ThemedIcon ("folder-music");
                    case "Videos": return new ThemedIcon ("folder-videos");
                    case "Downloads": return new ThemedIcon ("folder-download");
                    case "Desktop": return new ThemedIcon ("user-desktop");
                    case "Templates": return new ThemedIcon ("folder-templates");
                    case "Public": return new ThemedIcon ("folder-publicshare");
                    default: return new ThemedIcon ("folder");
                }
            }
            return ContentType.get_icon (content_type);
        }

        public string modified_text () {
            if (mtime <= 0) return "";
            var dt = new DateTime.from_unix_local (mtime);
            var now = new DateTime.now_local ();
            if (dt.get_year () == now.get_year () && dt.get_day_of_year () == now.get_day_of_year ()) return dt.format ("%H:%M");
            if (dt.get_year () == now.get_year ()) return dt.format ("%e %b, %H:%M").strip ();
            return dt.format ("%e %b %Y").strip ();
        }

        public string size_text () {
            if (is_dir || kind == "symlink") return "";
            return GLib.format_size (size);
        }
    }

    public static string change_label (string change) {
        switch (change) {
            case "added": return _("Added");
            case "changed": return _("Changed");
            case "removed": return _("Removed");
            case "contains": return _("Contains changes");
            default: return "";
        }
    }

    public static string home_relative (File file) {
        var home = File.new_for_path (Environment.get_home_dir ());
        if (file.equal (home)) return "";
        string? rel = home.get_relative_path (file);
        return rel ?? "\x01";
    }
}
