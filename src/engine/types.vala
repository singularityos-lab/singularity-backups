namespace Singularity.Backups {

    public errordomain BackupError {
        UNAVAILABLE,
        NOT_FOUND,
        NO_SPACE,
        BUSY,
        CORRUPT,
        FAILED,
        CANCELLED,
        UNSUPPORTED,
        PASSPHRASE
    }

    public enum EntryKind {
        FILE,
        DIRECTORY,
        SYMLINK;

        public char to_char () {
            switch (this) {
                case DIRECTORY: return 'd';
                case SYMLINK: return 'l';
                default: return 'f';
            }
        }

        public static EntryKind from_char (char c) {
            if (c == 'd') return DIRECTORY;
            if (c == 'l') return SYMLINK;
            return FILE;
        }

        public string to_string () {
            switch (this) {
                case DIRECTORY: return "directory";
                case SYMLINK: return "symlink";
                default: return "file";
            }
        }

        public static EntryKind parse (string text) {
            if (text == "directory" || text == "dir" || text == "d") return DIRECTORY;
            if (text == "symlink" || text == "link" || text == "l") return SYMLINK;
            return FILE;
        }
    }

    public enum Change {
        NONE,
        ADDED,
        CHANGED,
        REMOVED,
        CONTAINS;

        public string to_string () {
            switch (this) {
                case ADDED: return "added";
                case CHANGED: return "changed";
                case REMOVED: return "removed";
                case CONTAINS: return "contains";
                default: return "none";
            }
        }

        public static Change parse (string text) {
            switch (text) {
                case "added": return ADDED;
                case "changed": return CHANGED;
                case "removed": return REMOVED;
                case "contains": return CONTAINS;
                default: return NONE;
            }
        }
    }

    public class Entry : Object {
        public string path { get; set; default = ""; }
        public EntryKind kind { get; set; default = EntryKind.FILE; }
        public uint32 mode { get; set; default = 0644; }
        public uint64 size { get; set; default = 0; }
        public int64 mtime_ns { get; set; default = 0; }
        public string digest { get; set; default = ""; }
        public string target { get; set; default = ""; }
        public Change change { get; set; default = Change.NONE; }
        public string origin { get; set; default = ""; }

        public string name {
            owned get { return Path.get_basename (path); }
        }

        public string display_name {
            owned get { return name.make_valid (); }
        }

        public int64 mtime_seconds {
            get { return mtime_ns / 1000000000; }
        }

        public Entry.with (string path, EntryKind kind, uint32 mode, uint64 size, int64 mtime_ns, string digest) {
            this.path = path;
            this.kind = kind;
            this.mode = mode;
            this.size = size;
            this.mtime_ns = mtime_ns;
            this.digest = digest;
        }

        public bool same_content (Entry other) {
            if (kind != other.kind) return false;
            if (kind == EntryKind.DIRECTORY) return true;
            if (kind == EntryKind.SYMLINK) return target == other.target;
            if (digest != "" && other.digest != "") return digest == other.digest && size == other.size;
            return size == other.size && mtime_ns == other.mtime_ns;
        }

        public Entry copy () {
            var e = new Entry.with (path, kind, mode, size, mtime_ns, digest);
            e.target = target;
            e.change = change;
            e.origin = origin;
            return e;
        }

        public Variant to_variant () {
            var b = new VariantBuilder (VariantType.VARDICT);
            b.add ("{sv}", "path", new Variant.bytestring (path));
            b.add ("{sv}", "name", new Variant.string (display_name));
            b.add ("{sv}", "kind", new Variant.string (kind.to_string ()));
            b.add ("{sv}", "mode", new Variant.uint32 (mode));
            b.add ("{sv}", "size", new Variant.uint64 (size));
            b.add ("{sv}", "mtime", new Variant.int64 (mtime_seconds));
            b.add ("{sv}", "digest", new Variant.string (digest));
            b.add ("{sv}", "target", new Variant.bytestring (target));
            b.add ("{sv}", "change", new Variant.string (change.to_string ()));
            b.add ("{sv}", "origin", new Variant.string (origin));
            return b.end ();
        }

        public static Entry from_variant (Variant v) {
            var e = new Entry ();
            var d = new VariantDict (v);
            string s;
            uint32 u;
            uint64 t;
            int64 x;
            var p = d.lookup_value ("path", VariantType.BYTESTRING);
            if (p != null) e.path = p.get_bytestring ();
            if (d.lookup ("kind", "s", out s)) e.kind = EntryKind.parse (s);
            if (d.lookup ("mode", "u", out u)) e.mode = u;
            if (d.lookup ("size", "t", out t)) e.size = t;
            if (d.lookup ("mtime", "x", out x)) e.mtime_ns = x * 1000000000;
            if (d.lookup ("digest", "s", out s)) e.digest = s;
            var t2 = d.lookup_value ("target", VariantType.BYTESTRING);
            if (t2 != null) e.target = t2.get_bytestring ();
            if (d.lookup ("change", "s", out s)) e.change = Change.parse (s);
            if (d.lookup ("origin", "s", out s)) e.origin = s;
            return e;
        }
    }

    public class SnapshotInfo : Object {
        public string id { get; set; default = ""; }
        public int64 created { get; set; default = 0; }
        public string label { get; set; default = ""; }
        public uint64 files { get; set; default = 0; }
        public uint64 bytes { get; set; default = 0; }
        public uint64 added_bytes { get; set; default = 0; }
        public uint64 added_files { get; set; default = 0; }
        public string[] providers { get; set; default = {}; }
        public string[] warnings { get; set; default = {}; }
        public string host { get; set; default = ""; }

        public Variant to_variant () {
            var b = new VariantBuilder (VariantType.VARDICT);
            b.add ("{sv}", "id", new Variant.string (id));
            b.add ("{sv}", "created", new Variant.int64 (created));
            b.add ("{sv}", "label", new Variant.string (label));
            b.add ("{sv}", "files", new Variant.uint64 (files));
            b.add ("{sv}", "bytes", new Variant.uint64 (bytes));
            b.add ("{sv}", "added-bytes", new Variant.uint64 (added_bytes));
            b.add ("{sv}", "added-files", new Variant.uint64 (added_files));
            b.add ("{sv}", "providers", new Variant.strv (providers));
            b.add ("{sv}", "warnings", new Variant.strv (warnings));
            b.add ("{sv}", "host", new Variant.string (host));
            return b.end ();
        }

        public static SnapshotInfo from_variant (Variant v) {
            var s = new SnapshotInfo ();
            var d = new VariantDict (v);
            string str;
            int64 x;
            uint64 t;
            if (d.lookup ("id", "s", out str)) s.id = str;
            if (d.lookup ("created", "x", out x)) s.created = x;
            if (d.lookup ("label", "s", out str)) s.label = str;
            if (d.lookup ("files", "t", out t)) s.files = t;
            if (d.lookup ("bytes", "t", out t)) s.bytes = t;
            if (d.lookup ("added-bytes", "t", out t)) s.added_bytes = t;
            if (d.lookup ("added-files", "t", out t)) s.added_files = t;
            if (d.lookup ("host", "s", out str)) s.host = str;
            var p = d.lookup_value ("providers", VariantType.STRING_ARRAY);
            if (p != null) s.providers = p.dup_strv ();
            var w = d.lookup_value ("warnings", VariantType.STRING_ARRAY);
            if (w != null) s.warnings = w.dup_strv ();
            return s;
        }
    }

    public class VerifyResult : Object {
        public uint64 checked { get; set; default = 0; }
        public string[] damaged { get; set; default = {}; }
        public string[] missing { get; set; default = {}; }

        public bool ok {
            get { return damaged.length == 0 && missing.length == 0; }
        }
    }

    public class RepoStats : Object {
        public uint64 used { get; set; default = 0; }
        public uint64 free { get; set; default = 0; }
        public uint64 capacity { get; set; default = 0; }
        public bool links { get; set; default = true; }
        public string store { get; set; default = "tree"; }
        public bool encrypted { get; set; default = false; }
    }

    public class BackupPlan : Object {
        public string source_home { get; set; default = ""; }
        public string[] providers { get; set; default = { "userdata" }; }
        public string[] exclusions { get; set; default = {}; }
        public string label { get; set; default = ""; }
        public bool deduplicate { get; set; default = true; }
        public int keep_last { get; set; default = 0; }
        public RetentionMode retention { get; set; default = RetentionMode.KEEP_LAST; }
        public PauseGate? gate { get; set; default = null; }
        public string host { get; set; default = ""; }
        public string system_root { get; set; default = "/"; }
        public string system_helper { get; set; default = ""; }
        public string abroot_command { get; set; default = "abroot"; }
        public string[] notes { get; set; default = {}; }
    }

    public delegate void ProgressFunc (double fraction, string phase, string item);

    public static string snapshot_id_for (DateTime time) {
        return time.to_utc ().format ("%Y%m%dT%H%M%SZ");
    }

    public static int64 parse_snapshot_id (string id) {
        if (id.length < 16) return 0;
        string iso = "%s-%s-%sT%s:%s:%sZ".printf (id.substring (0, 4), id.substring (4, 2), id.substring (6, 2),
                                                id.substring (9, 2), id.substring (11, 2), id.substring (13, 2));
        var dt = new DateTime.from_iso8601 (iso, new TimeZone.utc ());
        return dt != null ? dt.to_unix () : 0;
    }

    public static string format_bytes (uint64 bytes) {
        return GLib.format_size (bytes);
    }
}
