namespace Singularity.Backups {

    public class Destination : Object {
        public string kind { get; set; default = "disk"; }
        public string id { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string device { get; set; default = ""; }
        public string object_path { get; set; default = ""; }
        public string mount_point { get; set; default = ""; }
        public string fstype { get; set; default = ""; }
        public uint64 size { get; set; default = 0; }
        public uint64 free { get; set; default = 0; }
        public bool encrypted { get; set; default = false; }
        public bool locked { get; set; default = false; }
        public bool removable { get; set; default = false; }
        public bool has_backups { get; set; default = false; }

        public bool supports_links {
            get {
                switch (fstype) {
                    case "vfat":
                    case "exfat":
                    case "msdos":
                    case "iso9660":
                    case "udf":
                    case CLOUD_FSTYPE:
                        return false;
                    default:
                        return true;
                }
            }
        }

        public bool can_hold_backups {
            get { return fstype != "iso9660" && fstype != "udf"; }
        }

        public Variant to_variant () {
            var b = new VariantBuilder (VariantType.VARDICT);
            b.add ("{sv}", "kind", new Variant.string (kind));
            b.add ("{sv}", "id", new Variant.string (id));
            b.add ("{sv}", "name", new Variant.string (name));
            b.add ("{sv}", "device", new Variant.string (device));
            b.add ("{sv}", "object", new Variant.string (object_path));
            b.add ("{sv}", "mount-point", new Variant.string (mount_point));
            b.add ("{sv}", "fstype", new Variant.string (fstype));
            b.add ("{sv}", "size", new Variant.uint64 (size));
            b.add ("{sv}", "free", new Variant.uint64 (free));
            b.add ("{sv}", "encrypted", new Variant.boolean (encrypted));
            b.add ("{sv}", "locked", new Variant.boolean (locked));
            b.add ("{sv}", "removable", new Variant.boolean (removable));
            b.add ("{sv}", "has-backups", new Variant.boolean (has_backups));
            b.add ("{sv}", "supports-links", new Variant.boolean (supports_links));
            b.add ("{sv}", "can-hold-backups", new Variant.boolean (can_hold_backups));
            return b.end ();
        }
    }

    public const string CLOUD_FSTYPE = "fuse.singularity-cloud";

    public class Destinations : Object {
        private const string UDISKS = "org.freedesktop.UDisks2";
        private const string IFACE_DRIVE = "org.freedesktop.UDisks2.Drive";
        private const string IFACE_BLOCK = "org.freedesktop.UDisks2.Block";
        private const string IFACE_FILESYSTEM = "org.freedesktop.UDisks2.Filesystem";
        private const string IFACE_ENCRYPTED = "org.freedesktop.UDisks2.Encrypted";
        private const string IFACE_PARTITION_TABLE = "org.freedesktop.UDisks2.PartitionTable";
        private const string[] NETWORK_TYPES = { "cifs", "smb3", "smbfs", "nfs", "nfs4", "fuse.sshfs", "sshfs", "davfs", "fuse.davfs2", "9p", "fuse.rclone" };
        private const string[] SYSTEM_MOUNTS = { "/", "/boot", "/boot/efi", "/efi", "/usr", "/var", "/home", "/sysroot" };

        private DBusObjectManagerClient? manager = null;
        public string repository_name { get; set; default = "Singularity Backups"; }

        public signal void changed ();

        public async void connect_udisks () {
            try {
                manager = yield new DBusObjectManagerClient.for_bus (BusType.SYSTEM, DBusObjectManagerClientFlags.DO_NOT_AUTO_START,
                    UDISKS, "/org/freedesktop/UDisks2", null, null);
                if (manager.name_owner == null) {
                    manager = null;
                    return;
                }
                manager.object_added.connect (() => changed ());
                manager.object_removed.connect (() => changed ());
                manager.interface_proxy_properties_changed.connect (() => changed ());
            } catch (Error e) {
                manager = null;
            }
        }

        public bool udisks_available {
            get { return manager != null && manager.name_owner != null; }
        }

        private static DBusProxy? iface (DBusObject o, string name) {
            return o.get_interface (name) as DBusProxy;
        }

        private static Variant? prop (DBusObject o, string iface_name, string property) {
            var p = iface (o, iface_name);
            return p != null ? p.get_cached_property (property) : null;
        }

        private static string str (DBusObject o, string iface_name, string property) {
            var v = prop (o, iface_name, property);
            if (v == null) return "";
            if (v.is_of_type (VariantType.STRING) || v.is_of_type (VariantType.OBJECT_PATH)) return v.get_string ();
            if (v.is_of_type (VariantType.BYTESTRING)) return v.get_bytestring ();
            return "";
        }

        private static bool flag (DBusObject o, string iface_name, string property) {
            var v = prop (o, iface_name, property);
            return v != null && v.is_of_type (VariantType.BOOLEAN) && v.get_boolean ();
        }

        private static uint64 u64 (DBusObject o, string iface_name, string property) {
            var v = prop (o, iface_name, property);
            if (v == null) return 0;
            if (v.is_of_type (VariantType.UINT64)) return v.get_uint64 ();
            return 0;
        }

        private static string[] mount_points (DBusObject o) {
            string[] result = {};
            var v = prop (o, IFACE_FILESYSTEM, "MountPoints");
            if (v == null) return result;
            for (size_t i = 0; i < v.n_children (); i++) result += v.get_child_value (i).get_bytestring ();
            return result;
        }

        private DBusObject? find_by_path (string path) {
            return manager != null ? manager.get_object (path) : null;
        }

        private DBusObject? cleartext_of (DBusObject crypto) {
            foreach (var o in manager.get_objects ()) {
                if (str (o, IFACE_BLOCK, "CryptoBackingDevice") == crypto.get_object_path ()) return o;
            }
            return null;
        }

        public string repository_in (string base_path) {
            string user = Environment.get_user_name ();
            string host = Environment.get_host_name ();
            return Path.build_filename (base_path, repository_name, "%s@%s".printf (user, host));
        }

        private bool holds_backups (string mount_point) {
            if (mount_point == "") return false;
            return FileUtils.test (Path.build_filename (mount_point, repository_name), FileTest.IS_DIR);
        }

        private static void fill_space (Destination d) {
            if (d.mount_point == "") return;
            Posix.statvfs v;
            if (Posix.statvfs_exec (d.mount_point, out v) == 0) {
                d.free = (uint64) v.f_bavail * v.f_frsize;
                if (d.size == 0) d.size = (uint64) v.f_blocks * v.f_frsize;
            }
        }

        private static bool is_system_mount (string m) {
            foreach (string s in SYSTEM_MOUNTS) if (m == s) return true;
            return false;
        }

        public Gee.List<Destination> list_disks () {
            var list = new Gee.ArrayList<Destination> ();
            if (manager == null) return list;
            foreach (var o in manager.get_objects ()) {
                if (iface (o, IFACE_BLOCK) == null) continue;
                bool is_fs = iface (o, IFACE_FILESYSTEM) != null;
                bool is_crypto = iface (o, IFACE_ENCRYPTED) != null;
                if (!is_fs && !is_crypto) continue;
                if (str (o, IFACE_BLOCK, "CryptoBackingDevice") != "/" && str (o, IFACE_BLOCK, "CryptoBackingDevice") != "") continue;
                if (flag (o, IFACE_BLOCK, "HintSystem") && !flag (o, IFACE_BLOCK, "HintAuto")) continue;
                if (flag (o, IFACE_BLOCK, "HintIgnore")) continue;
                var d = new Destination ();
                d.kind = "disk";
                d.object_path = o.get_object_path ();
                d.device = str (o, IFACE_BLOCK, "PreferredDevice");
                if (d.device == "") d.device = str (o, IFACE_BLOCK, "Device");
                d.id = str (o, IFACE_BLOCK, "IdUUID");
                d.size = u64 (o, IFACE_BLOCK, "Size");
                d.encrypted = is_crypto;
                DBusObject target = o;
                if (is_crypto) {
                    var clear = cleartext_of (o);
                    d.locked = clear == null;
                    if (clear != null) target = clear;
                }
                d.fstype = str (target, IFACE_BLOCK, "IdType");
                string label = str (target, IFACE_BLOCK, "IdLabel");
                if (label == "") label = str (o, IFACE_BLOCK, "IdLabel");
                string[] mounts = iface (target, IFACE_FILESYSTEM) != null ? mount_points (target) : new string[0];
                bool system = false;
                foreach (string m in mounts) if (is_system_mount (m)) system = true;
                if (system) continue;
                d.mount_point = mounts.length > 0 ? mounts[0] : "";
                var drive = find_by_path (str (o, IFACE_BLOCK, "Drive"));
                if (drive != null) {
                    d.removable = flag (drive, IFACE_DRIVE, "Removable") || flag (drive, IFACE_DRIVE, "MediaRemovable") ||
                                  str (drive, IFACE_DRIVE, "ConnectionBus") == "usb";
                    string vendor = str (drive, IFACE_DRIVE, "Vendor").strip ();
                    string model = str (drive, IFACE_DRIVE, "Model").strip ();
                    if (label == "") label = model != "" ? (vendor != "" && !model.has_prefix (vendor) ? vendor + " " + model : model) : vendor;
                }
                d.name = label != "" ? label : GLib.format_size (d.size) + " " + _("Disk");
                d.has_backups = holds_backups (d.mount_point);
                fill_space (d);
                list.add (d);
            }
            list.sort ((a, b) => {
                if (a.removable != b.removable) return a.removable ? -1 : 1;
                return strcmp (a.name, b.name);
            });
            return list;
        }

        public static Gee.List<Destination> list_network_mounts () {
            var list = new Gee.ArrayList<Destination> ();
            string text;
            try {
                FileUtils.get_contents ("/proc/self/mounts", out text);
            } catch (Error e) {
                return list;
            }
            foreach (string line in text.split ("\n")) {
                string[] f = line.split (" ");
                if (f.length < 3) continue;
                bool network = false;
                foreach (string t in NETWORK_TYPES) if (f[2] == t) network = true;
                if (!network) continue;
                var d = new Destination ();
                d.kind = "network";
                d.mount_point = f[1].compress ();
                d.id = d.mount_point;
                d.fstype = f[2];
                d.name = "%s (%s)".printf (Path.get_basename (d.mount_point), f[0].compress ());
                fill_space (d);
                list.add (d);
            }
            string gvfs = Path.build_filename (Environment.get_user_runtime_dir (), "gvfs");
            try {
                var dir = Dir.open (gvfs);
                string? name;
                while ((name = dir.read_name ()) != null) {
                    var d = new Destination ();
                    d.kind = "network";
                    d.mount_point = Path.build_filename (gvfs, name);
                    d.id = d.mount_point;
                    d.fstype = "gvfs";
                    d.name = name;
                    fill_space (d);
                    list.add (d);
                }
            } catch (FileError e) {
            }
            return list;
        }

        private static HashTable<string, string> mount_table () {
            var table = new HashTable<string, string> (str_hash, str_equal);
            string text;
            try {
                FileUtils.get_contents ("/proc/self/mounts", out text);
            } catch (Error e) {
                return table;
            }
            foreach (string line in text.split ("\n")) {
                string[] f = line.split (" ");
                if (f.length < 3) continue;
                table[f[1].compress ()] = f[2];
            }
            return table;
        }

        public static string cloud_folder () {
            return Path.build_filename (Environment.get_home_dir (), "Cloud");
        }

        public static Gee.List<Destination> list_cloud_drives () {
            var list = new Gee.ArrayList<Destination> ();
            var mounts = mount_table ();
            Dir dir;
            try {
                dir = Dir.open (cloud_folder ());
            } catch (FileError e) {
                return list;
            }
            string? name;
            while ((name = dir.read_name ()) != null) {
                string path = Path.build_filename (cloud_folder (), name);
                string? real = Posix.realpath (path);
                if (real == null) continue;
                string? type = mounts[real];
                if (type == null || type != CLOUD_FSTYPE) continue;
                var d = new Destination ();
                d.kind = "cloud";
                d.mount_point = path;
                d.id = path;
                d.fstype = type;
                d.name = name;
                fill_space (d);
                list.add (d);
            }
            list.sort ((a, b) => strcmp (a.name, b.name));
            return list;
        }

        public static async void start_cloud_mount (string path) {
            try {
                var bus = yield Bus.get (BusType.SESSION);
                yield bus.call ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "StartServiceByName",
                    new Variant ("(su)", "dev.sinty.CloudMount", 0), null, DBusCallFlags.NONE, 10000, null);
            } catch (Error e) {
                return;
            }
            for (int i = 0; i < 50 && !FileUtils.test (path, FileTest.IS_DIR); i++) {
                Timeout.add (200, start_cloud_mount.callback);
                yield;
            }
        }

        public string? mount_for_uuid (string uuid) {
            if (uuid == "") return null;
            if (manager != null) {
                foreach (var d in list_disks ()) {
                    if (d.id == uuid && d.mount_point != "") return d.mount_point;
                }
            }
            string link = Path.build_filename ("/dev/disk/by-uuid", uuid);
            string device;
            try {
                device = FileUtils.read_link (link);
            } catch (FileError e) {
                return null;
            }
            if (!Path.is_absolute (device)) device = Path.build_filename ("/dev/disk/by-uuid", device);
            string text;
            try {
                FileUtils.get_contents ("/proc/self/mounts", out text);
            } catch (Error e) {
                return null;
            }
            string real = Posix.realpath (device) ?? device;
            foreach (string line in text.split ("\n")) {
                string[] f = line.split (" ");
                if (f.length < 2) continue;
                string dev = Posix.realpath (f[0]) ?? f[0];
                if (dev == real) return f[1].compress ();
            }
            return null;
        }

        public Destination? disk_for_uuid (string uuid) {
            foreach (var d in list_disks ()) if (d.id == uuid) return d;
            return null;
        }

        public async string mount_disk (string uuid, string? passphrase) throws Error {
            string? existing = mount_for_uuid (uuid);
            if (existing != null) return existing;
            if (manager == null) throw new BackupError.UNAVAILABLE (_("The backup disk is not connected"));
            var d = disk_for_uuid (uuid);
            if (d == null) throw new BackupError.UNAVAILABLE (_("The backup disk is not connected"));
            var o = find_by_path (d.object_path);
            DBusObject fs_object = o;
            if (d.encrypted) {
                var clear = cleartext_of (o);
                if (clear == null) {
                    if (passphrase == null) throw new BackupError.UNAVAILABLE (_("The backup disk is locked"));
                    var opts = new VariantBuilder (new VariantType ("a{sv}"));
                    var reply = yield iface (o, IFACE_ENCRYPTED).call ("Unlock", new Variant ("(s@a{sv})", passphrase, opts.end ()),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, 60000, null);
                    string clear_path;
                    reply.get ("(o)", out clear_path);
                    for (int i = 0; i < 50 && find_by_path (clear_path) == null; i++) {
                        Timeout.add (100, mount_disk.callback);
                        yield;
                    }
                    clear = find_by_path (clear_path);
                    if (clear == null) throw new BackupError.UNAVAILABLE (_("The backup disk could not be unlocked"));
                }
                fs_object = clear;
            }
            for (int i = 0; i < 50 && iface (fs_object, IFACE_FILESYSTEM) == null; i++) {
                Timeout.add (100, mount_disk.callback);
                yield;
            }
            var fs = iface (fs_object, IFACE_FILESYSTEM);
            if (fs == null) throw new BackupError.UNAVAILABLE (_("The backup disk has no file system"));
            var mount_opts = new VariantBuilder (new VariantType ("a{sv}"));
            var reply = yield fs.call ("Mount", new Variant ("(@a{sv})", mount_opts.end ()),
                DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, 60000, null);
            string mount_point;
            reply.get ("(s)", out mount_point);
            return mount_point;
        }

        public async string prepare_disk (string object_path, string label, string? passphrase) throws Error {
            if (manager == null) throw new BackupError.UNAVAILABLE (_("Disks cannot be managed on this system"));
            var o = find_by_path (object_path);
            if (o == null) throw new BackupError.NOT_FOUND (_("The disk is no longer connected"));
            string drive_path = str (o, IFACE_BLOCK, "Drive");
            DBusObject? whole = null;
            foreach (var b in manager.get_objects ()) {
                if (iface (b, IFACE_BLOCK) == null) continue;
                if (str (b, IFACE_BLOCK, "Drive") != drive_path || drive_path == "/") continue;
                if (b.get_interface ("org.freedesktop.UDisks2.Partition") != null) continue;
                whole = b;
            }
            if (whole == null) whole = o;
            foreach (var b in manager.get_objects ()) {
                if (iface (b, IFACE_BLOCK) == null) continue;
                if (str (b, IFACE_BLOCK, "Drive") != drive_path) continue;
                if (iface (b, IFACE_FILESYSTEM) != null && mount_points (b).length > 0) {
                    yield iface (b, IFACE_FILESYSTEM).call ("Unmount", new Variant ("(@a{sv})", new VariantBuilder (new VariantType ("a{sv}")).end ()),
                        DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, 60000, null);
                }
            }
            yield iface (whole, IFACE_BLOCK).call ("Format", new Variant ("(s@a{sv})", "gpt", new VariantBuilder (new VariantType ("a{sv}")).end ()),
                DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, 600000, null);
            for (int i = 0; i < 100 && iface (whole, IFACE_PARTITION_TABLE) == null; i++) {
                Timeout.add (100, prepare_disk.callback);
                yield;
            }
            var table = iface (whole, IFACE_PARTITION_TABLE);
            if (table == null) throw new BackupError.FAILED (_("The disk could not be prepared"));
            var opts = new VariantBuilder (new VariantType ("a{sv}"));
            opts.add ("{sv}", "label", new Variant.string (label));
            if (passphrase != null && passphrase != "") {
                opts.add ("{sv}", "encrypt.passphrase", new Variant.string (passphrase));
                opts.add ("{sv}", "encrypt.type", new Variant.string ("luks2"));
            }
            var reply = yield table.call ("CreatePartitionAndFormat",
                new Variant ("(ttss@a{sv}s@a{sv})", (uint64) 1048576, (uint64) 0, "", label,
                             new VariantBuilder (new VariantType ("a{sv}")).end (), "ext4", opts.end ()),
                DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, 600000, null);
            string created;
            reply.get ("(o)", out created);
            for (int i = 0; i < 100; i++) {
                var c = find_by_path (created);
                if (c != null && str (c, IFACE_BLOCK, "IdUUID") != "") return str (c, IFACE_BLOCK, "IdUUID");
                Timeout.add (100, prepare_disk.callback);
                yield;
            }
            throw new BackupError.FAILED (_("The disk could not be prepared"));
        }
    }
}
