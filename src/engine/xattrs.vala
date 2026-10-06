namespace Singularity.Backups {

    [CCode (cname = "llistxattr", cheader_filename = "sys/xattr.h")]
    private extern ssize_t c_llistxattr (string path, [CCode (array_length_type = "size_t")] uint8[]? list);

    [CCode (cname = "lgetxattr", cheader_filename = "sys/xattr.h")]
    private extern ssize_t c_lgetxattr (string path, string name, [CCode (array_length_type = "size_t")] uint8[]? value);

    [CCode (cname = "lsetxattr", cheader_filename = "sys/xattr.h")]
    private extern int c_lsetxattr (string path, string name, [CCode (array_length_type = "size_t")] uint8[] value, int flags);

    public class XattrSet : Object {
        public const string TYPE = "a(aya(ayay))";
        private const string ITEM = "a(ayay)";

        private HashTable<string, Variant> table = new HashTable<string, Variant> (str_hash, str_equal);

        public uint size {
            get { return table.size (); }
        }

        public static bool wanted (string name) {
            return name.has_prefix ("user.") || name == "system.posix_acl_access" || name == "system.posix_acl_default";
        }

        public static Variant? read (string path) {
            ssize_t needed = c_llistxattr (path, null);
            if (needed <= 0) return null;
            var names = new uint8[needed];
            ssize_t got = c_llistxattr (path, names);
            if (got <= 0) return null;
            var b = new VariantBuilder (new VariantType (ITEM));
            int count = 0;
            size_t start = 0;
            for (size_t i = 0; i < (size_t) got; i++) {
                if (names[i] != 0) continue;
                string name = ((string) ((uint8*) names + start)).dup ();
                start = i + 1;
                if (!wanted (name)) continue;
                ssize_t len = c_lgetxattr (path, name, null);
                if (len < 0) continue;
                var value = new uint8[len];
                if (len > 0) {
                    len = c_lgetxattr (path, name, value);
                    if (len < 0) continue;
                    value.length = (int) len;
                }
                b.add ("(@ay@ay)", new Variant.bytestring (name), new Variant.from_bytes (new VariantType ("ay"), new Bytes (value), true));
                count++;
            }
            if (count == 0) return null;
            return b.end ();
        }

        public static int apply (string path, Variant attrs) {
            int failures = 0;
            var iter = attrs.iterator ();
            Variant item;
            while ((item = iter.next_value ()) != null) {
                string name = item.get_child_value (0).get_bytestring ();
                if (!wanted (name)) continue;
                var bytes = item.get_child_value (1).get_data_as_bytes ();
                if (c_lsetxattr (path, name, bytes.get_data () ?? new uint8[0], 0) != 0) failures++;
            }
            return failures;
        }

        public void add (string path, Variant attrs) {
            table[path] = attrs;
        }

        public Variant? lookup (string path) {
            return table[path];
        }

        public void save (string file) throws Error {
            var b = new VariantBuilder (new VariantType (TYPE));
            table.foreach ((path, attrs) => b.add ("(@ay@a(ayay))", new Variant.bytestring (path), attrs));
            var v = b.end ();
            string tmp = file + ".part";
            FileUtils.set_data (tmp, v.get_data_as_bytes ().get_data ());
            if (FileUtils.rename (tmp, file) != 0) throw new BackupError.FAILED (_("Cannot write the index %s"), file);
        }

        public static XattrSet load (string file) {
            var set = new XattrSet ();
            uint8[] data;
            try {
                FileUtils.get_data (file, out data);
            } catch (Error e) {
                return set;
            }
            var bytes = new Bytes.take ((owned) data);
            var v = new Variant.from_bytes (new VariantType (TYPE), bytes, false);
            if (!v.is_normal_form ()) return set;
            v = new Variant.from_bytes (new VariantType (TYPE), bytes, true);
            var iter = v.iterator ();
            Variant item;
            while ((item = iter.next_value ()) != null) {
                set.table[item.get_child_value (0).get_bytestring ()] = item.get_child_value (1);
            }
            return set;
        }
    }
}
