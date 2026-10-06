namespace Singularity.Backups {

    public delegate void SealStep (uint64 bytes);

    public class Sealing : Object {
        public const string CIPHER = "xchacha20poly1305-secretstream";
        public const string KDF = "argon2id13";
        private const size_t CHUNK = 1024 * 1024;
        private const uint8[] MAGIC = { 'S', 'B', 'K', '1' };
        private const string CHECK_TEXT = "singularity-backups-repository-key";
        private const string CONTEXT = "sbackups";

        private uint8[] data_key = new uint8[32];
        private uint8[] name_key = new uint8[32];
        public string salt { get; private set; default = ""; }
        public uint64 ops { get; private set; default = 0; }
        public uint64 memory { get; private set; default = 0; }
        public string check { get; private set; default = ""; }

        private static bool ready = false;

        private static void ensure_ready () throws Error {
            if (ready) return;
            if (Sodium.init () < 0) throw new BackupError.UNSUPPORTED (_("Encryption is not available on this system"));
            ready = true;
        }

        ~Sealing () {
            Sodium.memzero (data_key);
            Sodium.memzero (name_key);
        }

        private void derive (string passphrase, uint8[] salt_bytes, uint64 ops, uint64 memory) throws Error {
            uint8[] master = new uint8[32];
            if (Sodium.pwhash (master, master.length, passphrase, passphrase.length, salt_bytes, ops, (size_t) memory,
                               Sodium.PWHASH_ARGON2ID13) != 0) {
                throw new BackupError.FAILED (_("Not enough memory to unlock the backups"));
            }
            Sodium.kdf_derive (data_key, 1, CONTEXT, master);
            Sodium.kdf_derive (name_key, 2, CONTEXT, master);
            Sodium.memzero (master);
            this.salt = Base64.encode (salt_bytes);
            this.ops = ops;
            this.memory = memory;
        }

        public static Sealing create (string passphrase) throws Error {
            ensure_ready ();
            if (passphrase == "") throw new BackupError.PASSPHRASE (_("Choose a passphrase to encrypt the backups"));
            var s = new Sealing ();
            uint8[] salt_bytes = new uint8[Sodium.PWHASH_SALTBYTES];
            Sodium.random_bytes (salt_bytes);
            s.derive (passphrase, salt_bytes, Sodium.PWHASH_OPSLIMIT_INTERACTIVE, Sodium.PWHASH_MEMLIMIT_INTERACTIVE);
            s.check = Base64.encode (s.seal_bytes (CHECK_TEXT.data));
            return s;
        }

        public static Sealing unlock (string passphrase, Json.Object parameters) throws Error {
            ensure_ready ();
            if (parameters.get_string_member_with_default ("cipher", "") != CIPHER ||
                parameters.get_string_member_with_default ("kdf", "") != KDF) {
                throw new BackupError.UNSUPPORTED (_("These backups are encrypted in a way this version of Backups cannot read"));
            }
            var s = new Sealing ();
            uint8[] salt_bytes = Base64.decode (parameters.get_string_member_with_default ("salt", ""));
            if (salt_bytes.length != Sodium.PWHASH_SALTBYTES) throw new BackupError.CORRUPT (_("The encryption settings of the backups are damaged"));
            uint64 ops = (uint64) parameters.get_int_member_with_default ("ops", 0);
            uint64 mem = (uint64) parameters.get_int_member_with_default ("memory", 0);
            if (ops == 0 || mem == 0 || mem > 1024 * 1024 * 1024) throw new BackupError.CORRUPT (_("The encryption settings of the backups are damaged"));
            s.derive (passphrase, salt_bytes, ops, mem);
            s.check = parameters.get_string_member_with_default ("check", "");
            uint8[]? plain = null;
            try {
                plain = s.open_bytes (Base64.decode (s.check));
            } catch (Error e) {
                plain = null;
            }
            if (plain == null || plain.length != CHECK_TEXT.length || Memory.cmp (plain, CHECK_TEXT.data, CHECK_TEXT.length) != 0) throw new BackupError.PASSPHRASE (_("The passphrase is not correct"));
            return s;
        }

        public Json.Node to_json () {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("cipher");
            b.add_string_value (CIPHER);
            b.set_member_name ("kdf");
            b.add_string_value (KDF);
            b.set_member_name ("salt");
            b.add_string_value (salt);
            b.set_member_name ("ops");
            b.add_int_value ((int64) ops);
            b.set_member_name ("memory");
            b.add_int_value ((int64) memory);
            b.set_member_name ("check");
            b.add_string_value (check);
            b.end_object ();
            return b.get_root ();
        }

        public string object_name (string digest) {
            uint8[] hash = new uint8[32];
            Sodium.generichash (hash, digest.data, name_key);
            var text = new StringBuilder ();
            foreach (uint8 b in hash) text.append_printf ("%02x", b);
            return text.str;
        }

        public uint8[] seal_bytes (uint8[] plain) throws Error {
            var output = new ByteArray ();
            var state = Sodium.StreamState ();
            uint8[] header = new uint8[Sodium.STREAM_HEADERBYTES];
            Sodium.stream_init_push (ref state, header, data_key);
            output.append (MAGIC);
            output.append (header);
            size_t offset = 0;
            uint8[] cipher = new uint8[CHUNK + Sodium.STREAM_ABYTES];
            do {
                size_t n = size_t.min (CHUNK, plain.length - offset);
                bool last = offset + n >= plain.length;
                uint64 clen;
                Sodium.stream_push (ref state, cipher, out clen, plain[offset:offset + n], n, null, 0,
                                    last ? Sodium.TAG_FINAL : Sodium.TAG_MESSAGE);
                output.append (cipher[0:(int) clen]);
                offset += n;
                if (last) break;
            } while (true);
            return output.steal ();
        }

        public uint8[] open_bytes (uint8[] sealed) throws Error {
            int head = MAGIC.length + Sodium.STREAM_HEADERBYTES;
            if (sealed.length < head + Sodium.STREAM_ABYTES || Memory.cmp (sealed, MAGIC, MAGIC.length) != 0) {
                throw new BackupError.CORRUPT (_("An encrypted file of the backups is damaged"));
            }
            var state = Sodium.StreamState ();
            if (Sodium.stream_init_pull (ref state, sealed[MAGIC.length:head], data_key) != 0) {
                throw new BackupError.CORRUPT (_("An encrypted file of the backups is damaged"));
            }
            var output = new ByteArray ();
            uint8[] plain = new uint8[CHUNK];
            size_t offset = head;
            bool final_seen = false;
            while (offset < sealed.length) {
                size_t n = size_t.min (CHUNK + Sodium.STREAM_ABYTES, sealed.length - offset);
                uint64 plen;
                uint8 tag;
                if (Sodium.stream_pull (ref state, plain, out plen, out tag, sealed[offset:offset + n], n, null, 0) != 0) {
                    throw new BackupError.CORRUPT (_("An encrypted file of the backups is damaged"));
                }
                output.append (plain[0:(int) plen]);
                offset += n;
                if (tag == Sodium.TAG_FINAL) {
                    final_seen = offset == sealed.length;
                    break;
                }
            }
            if (!final_seen) throw new BackupError.CORRUPT (_("An encrypted file of the backups is damaged"));
            return output.steal ();
        }

        private static ssize_t read_full (int fd, uint8[] buffer, size_t wanted) {
            size_t got = 0;
            while (got < wanted) {
                ssize_t n = Posix.read (fd, (void*) ((uint8*) buffer + got), wanted - got);
                if (n < 0 && errno == Posix.EINTR) continue;
                if (n < 0) return -1;
                if (n == 0) break;
                got += (size_t) n;
            }
            return (ssize_t) got;
        }

        private static bool write_all (int fd, uint8[] buffer, size_t length) {
            size_t offset = 0;
            while (offset < length) {
                ssize_t n = Posix.write (fd, (void*) ((uint8*) buffer + offset), length - offset);
                if (n < 0) {
                    if (errno == Posix.EINTR) continue;
                    return false;
                }
                offset += (size_t) n;
            }
            return true;
        }

        public void seal_fd (int input, int output, Checksum? sum, Cancellable? cancellable, SealStep? step) throws Error {
            var state = Sodium.StreamState ();
            uint8[] header = new uint8[Sodium.STREAM_HEADERBYTES];
            Sodium.stream_init_push (ref state, header, data_key);
            if (!write_all (output, MAGIC, MAGIC.length) || !write_all (output, header, header.length)) {
                throw new BackupError.FAILED (_("Cannot write an encrypted file: %s"), strerror (errno));
            }
            uint8[] plain = new uint8[CHUNK];
            uint8[] cipher = new uint8[CHUNK + Sodium.STREAM_ABYTES];
            while (true) {
                if (cancellable != null && cancellable.is_cancelled ()) throw new BackupError.CANCELLED (_("The backup was cancelled"));
                ssize_t n = read_full (input, plain, CHUNK);
                if (n < 0) throw new BackupError.FAILED (_("Cannot read a file: %s"), strerror (errno));
                bool last = (size_t) n < CHUNK;
                if (sum != null && n > 0) sum.update (plain, (size_t) n);
                uint64 clen;
                Sodium.stream_push (ref state, cipher, out clen, plain, (uint64) n, null, 0, last ? Sodium.TAG_FINAL : Sodium.TAG_MESSAGE);
                if (!write_all (output, cipher, (size_t) clen)) throw new BackupError.FAILED (_("Cannot write an encrypted file: %s"), strerror (errno));
                if (step != null && n > 0) step ((uint64) n);
                if (last) break;
            }
        }

        public void open_fd (int input, int output, Checksum? sum, Cancellable? cancellable) throws Error {
            uint8[] magic = new uint8[MAGIC.length];
            uint8[] header = new uint8[Sodium.STREAM_HEADERBYTES];
            if (read_full (input, magic, magic.length) != magic.length || Memory.cmp (magic, MAGIC, MAGIC.length) != 0 ||
                read_full (input, header, header.length) != header.length) {
                throw new BackupError.CORRUPT (_("An encrypted file of the backups is damaged"));
            }
            var state = Sodium.StreamState ();
            if (Sodium.stream_init_pull (ref state, header, data_key) != 0) throw new BackupError.CORRUPT (_("An encrypted file of the backups is damaged"));
            uint8[] cipher = new uint8[CHUNK + Sodium.STREAM_ABYTES];
            uint8[] plain = new uint8[CHUNK];
            while (true) {
                if (cancellable != null && cancellable.is_cancelled ()) throw new BackupError.CANCELLED (_("Cancelled"));
                ssize_t n = read_full (input, cipher, cipher.length);
                if (n < Sodium.STREAM_ABYTES) throw new BackupError.CORRUPT (_("An encrypted file of the backups is damaged"));
                uint64 plen;
                uint8 tag;
                if (Sodium.stream_pull (ref state, plain, out plen, out tag, cipher, (uint64) n, null, 0) != 0) {
                    throw new BackupError.CORRUPT (_("An encrypted file of the backups is damaged"));
                }
                if (sum != null && plen > 0) sum.update (plain, (size_t) plen);
                if (output >= 0 && !write_all (output, plain, (size_t) plen)) throw new BackupError.FAILED (_("Cannot write %s"), strerror (errno));
                if (tag == Sodium.TAG_FINAL) {
                    uint8[] extra = new uint8[1];
                    if (read_full (input, extra, 1) != 0) throw new BackupError.CORRUPT (_("An encrypted file of the backups is damaged"));
                    return;
                }
                if ((size_t) n < cipher.length) throw new BackupError.CORRUPT (_("An encrypted file of the backups is damaged"));
            }
        }

        public void open_file (string source, string target, Checksum? sum, Cancellable? cancellable) throws Error {
            int input = Posix.open (source, Posix.O_RDONLY | Posix.O_CLOEXEC);
            if (input < 0) throw new BackupError.FAILED (_("Cannot read %s: %s"), source, strerror (errno));
            int output = target != "" ? Posix.open (target, Posix.O_WRONLY | Posix.O_CREAT | Posix.O_TRUNC | Posix.O_CLOEXEC, 0600) : -1;
            if (target != "" && output < 0) {
                int err = errno;
                Posix.close (input);
                throw new BackupError.FAILED (_("Cannot write %s: %s"), target, strerror (err));
            }
            try {
                open_fd (input, output, sum, cancellable);
            } finally {
                Posix.close (input);
                if (output >= 0) Posix.close (output);
            }
        }
    }
}
