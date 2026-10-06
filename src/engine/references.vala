namespace Singularity.Backups {

    public class ReferenceSet : Object {
        public const int DIGEST = 64;
        private const int FAN_IN = 16;

        public int chunk { get; construct; }
        public string folder { get; construct; }

        private uint8[] buffer;
        private int used = 0;
        private int serial = 0;
        private Gee.ArrayList<string> runs = new Gee.ArrayList<string> ();
        private FileStream? reader = null;
        private string? sorted = null;
        private string current = "";
        private bool exhausted = false;

        public ReferenceSet (string folder, int chunk = 32768) {
            Object (folder: folder, chunk: int.max (chunk, 1));
            buffer = new uint8[this.chunk * DIGEST];
        }

        public void add (string digest) throws Error {
            if (digest == "") return;
            if (digest.length != DIGEST) throw new BackupError.CORRUPT (_("The backup index has an unknown content id"));
            Memory.copy (&buffer[used * DIGEST], digest.data, DIGEST);
            used++;
            if (used == chunk) flush ();
        }

        public void add_index (string file) throws Error {
            SnapshotIndex.each_digest (file, (digest) => add (digest));
        }

        private static int compare (void* a, void* b) {
            return Posix.memcmp (a, b, DIGEST);
        }

        private void flush () throws Error {
            if (used == 0) return;
            Posix.qsort (buffer, used, DIGEST, compare);
            string path = next_run ();
            var stream = open_run (path, "wb");
            uint8* last = null;
            for (int i = 0; i < used; i++) {
                uint8* record = &buffer[i * DIGEST];
                if (last != null && Posix.memcmp (last, record, DIGEST) == 0) continue;
                write_record (stream, record, path);
                last = record;
            }
            close_run (stream, path);
            runs.add (path);
            used = 0;
        }

        private string next_run () {
            return Path.build_filename (folder, "references-%d-%d".printf ((int) Posix.getpid (), serial++));
        }

        private static FileStream open_run (string path, string mode) throws Error {
            var stream = FileStream.open (path, mode);
            if (stream == null) throw new BackupError.FAILED (_("Cannot write %s"), path);
            return stream;
        }

        private static void write_record (FileStream stream, uint8* record, string path) throws Error {
            unowned uint8[] data = (uint8[]) record;
            data.length = DIGEST;
            if (stream.write (data) != DIGEST) throw new BackupError.FAILED (_("Cannot write %s"), path);
        }

        private static void close_run (FileStream stream, string path) throws Error {
            if (stream.flush () != 0 || stream.error () != 0) throw new BackupError.FAILED (_("Cannot write %s"), path);
        }

        public void finish () throws Error {
            flush ();
            buffer = new uint8[0];
            while (runs.size > 1) {
                var next = new Gee.ArrayList<string> ();
                for (int i = 0; i < runs.size; i += FAN_IN) {
                    var group = runs.slice (i, int.min (i + FAN_IN, runs.size));
                    if (group.size == 1) {
                        next.add (group[0]);
                        continue;
                    }
                    next.add (merge (group));
                }
                runs = next;
            }
            if (runs.size == 1) {
                sorted = runs[0];
                reader = open_run (sorted, "rb");
                advance ();
            } else {
                exhausted = true;
            }
        }

        private string merge (Gee.List<string> group) throws Error {
            string path = next_run ();
            var output = open_run (path, "wb");
            var inputs = new FileStream[group.size];
            var heads = new uint8[group.size * DIGEST];
            var live = new bool[group.size];
            for (int i = 0; i < group.size; i++) {
                inputs[i] = open_run (group[i], "rb");
                live[i] = read_into (inputs[i], &heads[i * DIGEST]);
            }
            uint8[] last = new uint8[DIGEST];
            bool have_last = false;
            while (true) {
                int best = -1;
                for (int i = 0; i < group.size; i++) {
                    if (!live[i]) continue;
                    if (best < 0 || Posix.memcmp (&heads[i * DIGEST], &heads[best * DIGEST], DIGEST) < 0) best = i;
                }
                if (best < 0) break;
                uint8* record = &heads[best * DIGEST];
                if (!have_last || Posix.memcmp (last, record, DIGEST) != 0) {
                    write_record (output, record, path);
                    Memory.copy (last, record, DIGEST);
                    have_last = true;
                }
                live[best] = read_into (inputs[best], record);
            }
            close_run (output, path);
            inputs = null;
            foreach (string run in group) FileUtils.unlink (run);
            return path;
        }

        private static bool read_into (FileStream stream, uint8* target) {
            unowned uint8[] data = (uint8[]) target;
            data.length = DIGEST;
            return stream.read (data) == DIGEST;
        }

        private void advance () {
            uint8[] record = new uint8[DIGEST + 1];
            if (reader == null || !read_into (reader, record)) {
                exhausted = true;
                current = "";
                return;
            }
            record[DIGEST] = 0;
            unowned string text = (string) record;
            current = text;
        }

        public bool contains_next (string name) {
            while (!exhausted && GLib.strcmp (current, name) < 0) advance ();
            return !exhausted && current == name;
        }

        public void close () {
            reader = null;
            if (sorted != null) FileUtils.unlink (sorted);
            foreach (string run in runs) FileUtils.unlink (run);
            runs.clear ();
            sorted = null;
            exhausted = true;
        }
    }
}
