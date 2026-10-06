namespace Singularity.Backups {

    public class IndexWriter : Object {
        private const string ITEM = "(@ayyutxs@ay)";
        private const int ALIGN = 8;

        private FileStream? stream;
        private string file;
        private string tmp;
        private uint64 body = 0;
        private uint64[] ends = {};

        public int count {
            get { return ends.length; }
        }

        public IndexWriter (string file) throws Error {
            this.file = file;
            tmp = file + ".part";
            stream = FileStream.open (tmp, "w");
            if (stream == null) throw new BackupError.FAILED (_("Cannot write the index %s"), file);
        }

        public void add (Entry e) {
            add_fields (e.path, e.kind, e.mode, e.size, e.mtime_ns, e.digest, e.target);
        }

        public void add_fields (string path, EntryKind kind, uint32 mode, uint64 size, int64 mtime_ns,
                                string digest, string target) {
            var v = new Variant (ITEM, new Variant.bytestring (path), (uchar) kind.to_char (), mode, size, mtime_ns,
                                 digest, new Variant.bytestring (target));
            while (body % ALIGN != 0) {
                stream.putc (0);
                body++;
            }
            var bytes = v.get_data_as_bytes ();
            unowned uint8[]? data = bytes.get_data ();
            if (data != null && data.length > 0) stream.write (data);
            body += bytes.get_size ();
            ends += body;
        }

        public void finish () throws Error {
            uint64 n = ends.length;
            int width;
            if (body + n <= uint8.MAX) width = 1;
            else if (body + 2 * n <= uint16.MAX) width = 2;
            else if (body + 4 * n <= uint32.MAX) width = 4;
            else width = 8;
            uint8[] cell = new uint8[width];
            foreach (uint64 end in ends) {
                for (int i = 0; i < width; i++) cell[i] = (uint8) ((end >> (8 * i)) & 0xff);
                stream.write (cell);
            }
            bool ok = stream.flush () == 0 && stream.error () == 0;
            stream = null;
            if (!ok || FileUtils.rename (tmp, file) != 0) {
                FileUtils.unlink (tmp);
                throw new BackupError.FAILED (_("Cannot write the index %s"), file);
            }
        }

        public void abandon () {
            stream = null;
            FileUtils.unlink (tmp);
        }
    }

    public delegate void DigestFunc (string digest) throws Error;

    public class SnapshotIndex : Object {
        private const string TYPE = "a(ayyutxsay)";
        private const string ITEM = "(ayyutxsay)";

        private Gee.ArrayList<Entry> entries = new Gee.ArrayList<Entry> ();
        private HashTable<string, Entry> by_path = new HashTable<string, Entry> (str_hash, str_equal);
        private HashTable<string, Gee.ArrayList<int>>? children = null;
        private MappedFile? mapping = null;
        private Variant? packed = null;
        private uint32[] slots = {};
        private uint mask = 0;

        public int size {
            get { return packed != null ? (int) packed.n_children () : entries.size; }
        }

        public void add (Entry entry) {
            return_if_fail (packed == null);
            entries.add (entry);
            by_path[entry.path] = entry;
            children = null;
        }

        public Entry? lookup (string path) {
            if (packed == null) return by_path[path];
            int i = find (path);
            return i < 0 ? null : at (i);
        }

        public Entry at (int i) {
            if (packed == null) return entries[i];
            var item = packed.get_child_value (i);
            var e = new Entry.with (item.get_child_value (0).get_bytestring (),
                                    EntryKind.from_char ((char) item.get_child_value (1).get_byte ()),
                                    item.get_child_value (2).get_uint32 (),
                                    item.get_child_value (3).get_uint64 (),
                                    item.get_child_value (4).get_int64 (),
                                    item.get_child_value (5).get_string ());
            e.target = item.get_child_value (6).get_bytestring ();
            return e;
        }

        public string digest_at (int i) {
            if (packed == null) return entries[i].digest;
            return packed.get_child_value (i).get_child_value (5).get_string ();
        }

        private string path_at (int i) {
            if (packed == null) return entries[i].path;
            return packed.get_child_value (i).get_child_value (0).get_bytestring ();
        }

        public Iterator iterator () {
            return new Iterator (this);
        }

        public class Iterator {
            private SnapshotIndex index;
            private int position = -1;

            public Iterator (SnapshotIndex index) {
                this.index = index;
            }

            public bool next () {
                position++;
                return position < index.size;
            }

            public Entry get () {
                return index.at (position);
            }
        }

        public Gee.List<Entry> list (string dir) {
            if (children == null) build_children ();
            var result = new Gee.ArrayList<Entry> ();
            var found = children[dir];
            if (found != null) foreach (int i in found) result.add (at (i));
            return result;
        }

        public bool has_dir (string dir) {
            if (dir == "") return true;
            var e = lookup (dir);
            return e != null && e.kind == EntryKind.DIRECTORY;
        }

        private void build_children () {
            children = new HashTable<string, Gee.ArrayList<int>> (str_hash, str_equal);
            int n = size;
            for (int i = 0; i < n; i++) {
                string parent = parent_of (path_at (i));
                var list = children[parent];
                if (list == null) {
                    list = new Gee.ArrayList<int> ();
                    children[parent] = list;
                }
                list.add (i);
            }
        }

        private int find (string path) {
            if (mask == 0) return -1;
            uint h = str_hash (path) & mask;
            while (slots[h] != 0) {
                int i = (int) slots[h] - 1;
                if (path_at (i) == path) return i;
                h = (h + 1) & mask;
            }
            return -1;
        }

        private void build_slots () {
            int n = size;
            uint capacity = 16;
            while (capacity < (uint) n * 2) capacity <<= 1;
            slots = new uint32[capacity];
            mask = capacity - 1;
            for (int i = 0; i < n; i++) {
                uint h = str_hash (path_at (i)) & mask;
                while (slots[h] != 0) h = (h + 1) & mask;
                slots[h] = (uint32) i + 1;
            }
        }

        public static string parent_of (string path) {
            int slash = path.last_index_of_char ('/');
            return slash < 0 ? "" : path.substring (0, slash);
        }

        public void save (string file) throws Error {
            var writer = new IndexWriter (file);
            int n = size;
            for (int i = 0; i < n; i++) writer.add (at (i));
            writer.finish ();
        }

        public static void each_digest (string file, DigestFunc func) throws Error {
            var items = FileStream.open (file, "rb");
            var table = FileStream.open (file, "rb");
            if (items == null || table == null) throw new BackupError.CORRUPT (_("The backup index %s is damaged"), file);
            items.seek (0, FileSeek.END);
            int64 total = items.tell ();
            if (total <= 0) return;
            int width = total <= uint8.MAX ? 1 : total <= uint16.MAX ? 2 : total <= uint32.MAX ? 4 : 8;
            if (total < width) throw new BackupError.CORRUPT (_("The backup index %s is damaged"), file);
            uint8[] cell = new uint8[width];
            table.seek ((long) (total - width), FileSeek.SET);
            if (table.read (cell) != width) throw new BackupError.CORRUPT (_("The backup index %s is damaged"), file);
            uint64 body = read_offset (cell);
            if (body > total || (total - body) % width != 0) throw new BackupError.CORRUPT (_("The backup index %s is damaged"), file);
            uint64 count = (total - body) / width;
            table.seek ((long) body, FileSeek.SET);
            items.seek (0, FileSeek.SET);
            uint64 start = 0;
            uint8[] buffer = new uint8[4096];
            var type = new VariantType (ITEM);
            for (uint64 i = 0; i < count; i++) {
                if (table.read (cell) != width) throw new BackupError.CORRUPT (_("The backup index %s is damaged"), file);
                uint64 end = read_offset (cell);
                uint64 skip = (8 - start % 8) % 8;
                if (end < start + skip || end > body) throw new BackupError.CORRUPT (_("The backup index %s is damaged"), file);
                if (skip > 0) items.seek ((long) skip, FileSeek.CUR);
                size_t length = (size_t) (end - start - skip);
                if (length > buffer.length) buffer = new uint8[length];
                if (length > 0 && items.read (buffer[0:length]) != length) {
                    throw new BackupError.CORRUPT (_("The backup index %s is damaged"), file);
                }
                var item = new Variant.from_bytes (type, new Bytes (buffer[0:length]), false);
                if (!item.is_normal_form ()) throw new BackupError.CORRUPT (_("The backup index %s is damaged"), file);
                func (item.get_child_value (5).get_string ());
                start = end;
            }
        }

        private static uint64 read_offset (uint8[] cell) {
            uint64 value = 0;
            for (int i = 0; i < cell.length; i++) value |= ((uint64) cell[i]) << (8 * i);
            return value;
        }

        public static SnapshotIndex load (string file) throws Error {
            var mapping = new MappedFile (file, false);
            var bytes = mapping.get_bytes ();
            var v = new Variant.from_bytes (new VariantType (TYPE), bytes, false);
            if (!v.is_normal_form ()) throw new BackupError.CORRUPT (_("The backup index %s is damaged"), file);
            var index = new SnapshotIndex ();
            index.mapping = mapping;
            index.packed = new Variant.from_bytes (new VariantType (TYPE), bytes, true);
            index.entries.clear ();
            index.build_slots ();
            return index;
        }
    }
}
