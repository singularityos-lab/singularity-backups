using Singularity.Accounts;

namespace Singularity.Backups {

    public class CloudDestination : Object {
        private MainLoop loop = new MainLoop ();
        private int status = 0;
        private CloudDrive? drive = null;
        private HashTable<string, CloudEntry> folders = new HashTable<string, CloudEntry> (str_hash, str_equal);
        private HashTable<string, HashTable<string, CloudEntry>> children = new HashTable<string, HashTable<string, CloudEntry>> (str_hash, str_equal);
        private DataInputStream input;

        private static void answer (Json.Object o) {
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (o);
            var g = new Json.Generator ();
            g.root = node;
            stdout.printf ("%s\n", g.to_data (null));
            stdout.flush ();
        }

        private static void fail (string code, string message) {
            var o = new Json.Object ();
            o.set_boolean_member ("ok", false);
            o.set_string_member ("error", code);
            o.set_string_member ("message", message);
            answer (o);
        }

        private static Json.Object ok () {
            var o = new Json.Object ();
            o.set_boolean_member ("ok", true);
            return o;
        }

        private static string code_for (Error e) {
            if (e is AccountsError.NOT_FOUND) return "not-found";
            if (e is AccountsError.NETWORK || e is ResolverError || e is IOError.HOST_UNREACHABLE || e is IOError.NETWORK_UNREACHABLE ||
                e is IOError.CONNECTION_REFUSED || e is IOError.TIMED_OUT || e is AccountsError.UNAVAILABLE) return "offline";
            if (e is AccountsError.NEEDS_REAUTH || e is AccountsError.AUTH_FAILED) return "auth";
            if (e is IOError.NO_SPACE) return "no-space";
            return "failed";
        }

        private static async Manager? manager () {
            var m = Manager.get_default ();
            yield m.load ();
            return m.available ? m : null;
        }

        public int run (string[] args) {
            if (args.length >= 2 && args[1] == "targets") {
                list_targets.begin ();
            } else if (args.length >= 3 && args[1] == "serve") {
                serve.begin (args[2]);
            } else {
                stderr.printf ("usage: %s targets | serve ACCOUNT\n", args[0]);
                return 2;
            }
            loop.run ();
            return status;
        }

        private async CloudQuota? quota_of (CloudDrive d) {
            var cancel = new Cancellable ();
            uint timer = Timeout.add_seconds (8, () => {
                cancel.cancel ();
                return Source.REMOVE;
            });
            CloudQuota? q = null;
            try {
                q = yield d.quota (cancel);
            } catch (Error e) {
                q = null;
            }
            if (!cancel.is_cancelled ()) Source.remove (timer);
            return q;
        }

        private async void list_targets () {
            var b = new Json.Builder ();
            b.begin_array ();
            var m = yield manager ();
            if (m != null) {
                foreach (var account in m.get_accounts_for (Capability.FILES)) {
                    var d = CloudDrive.for_account (account);
                    if (d == null) continue;
                    b.begin_object ();
                    b.set_member_name ("id");
                    b.add_string_value (account.id);
                    b.set_member_name ("name");
                    b.add_string_value (account.display_name != "" ? account.display_name : account.identity);
                    b.set_member_name ("detail");
                    b.add_string_value (account.identity != "" ? "%s, %s".printf (account.provider_name, account.identity) : account.provider_name);
                    b.set_member_name ("icon");
                    b.add_string_value (account.icon_name);
                    b.set_member_name ("available");
                    b.add_boolean_value (account.healthy);
                    if (!account.healthy) {
                        b.set_member_name ("reason");
                        b.add_string_value (_("Sign in to the account again in Settings, Online Accounts"));
                    }
                    var q = account.healthy ? yield quota_of (d) : null;
                    if (q != null) {
                        b.set_member_name ("used");
                        b.add_int_value (q.used);
                        if (q.total >= 0) {
                            b.set_member_name ("total");
                            b.add_int_value (q.total);
                        }
                    }
                    b.end_object ();
                }
            }
            b.end_array ();
            var g = new Json.Generator ();
            g.root = b.get_root ();
            stdout.printf ("%s\n", g.to_data (null));
            loop.quit ();
        }

        private async HashTable<string, CloudEntry> entries_in (CloudEntry folder) throws Error {
            var known = children[folder.id];
            if (known != null) return known;
            var table = new HashTable<string, CloudEntry> (str_hash, str_equal);
            foreach (var e in yield drive.list (folder.id)) table[e.name] = e;
            children[folder.id] = table;
            return table;
        }

        private async CloudEntry? folder_at (string path, bool create) throws Error {
            if (path == "") return folders[""];
            var known = folders[path];
            if (known != null) return known;
            int slash = path.last_index_of_char ('/');
            string parent_path = slash >= 0 ? path.substring (0, slash) : "";
            string name = slash >= 0 ? path.substring (slash + 1) : path;
            var parent = yield folder_at (parent_path, create);
            if (parent == null) return null;
            var entries = yield entries_in (parent);
            var found = entries[name];
            if (found == null || !found.is_folder) {
                if (!create) return null;
                found = yield drive.create_folder (parent.id, name);
                entries[name] = found;
                children[found.id] = new HashTable<string, CloudEntry> (str_hash, str_equal);
            }
            folders[path] = found;
            return found;
        }

        private static void split (string key, out string dir, out string name) {
            int slash = key.last_index_of_char ('/');
            dir = slash >= 0 ? key.substring (0, slash) : "";
            name = slash >= 0 ? key.substring (slash + 1) : key;
        }

        private async CloudEntry? file_at (string key) throws Error {
            string dir, name;
            split (key, out dir, out name);
            var folder = yield folder_at (dir, false);
            if (folder == null) return null;
            var e = (yield entries_in (folder))[name];
            return e != null && !e.is_folder ? e : null;
        }

        private async void collect (CloudEntry folder, string path, Json.Builder b) throws Error {
            var entries = yield entries_in (folder);
            var names = new Gee.ArrayList<string> ();
            entries.foreach ((k, v) => names.add (k));
            names.sort ((x, y) => strcmp (x, y));
            foreach (string name in names) {
                var e = entries[name];
                string key = path == "" ? name : path + "/" + name;
                if (e.is_folder) {
                    folders[key] = e;
                    yield collect (e, key, b);
                    continue;
                }
                b.begin_object ();
                b.set_member_name ("key");
                b.add_string_value (key);
                b.set_member_name ("size");
                b.add_int_value (e.size >= 0 ? e.size : 0);
                b.end_object ();
            }
        }

        private async void handle (Json.Object req) {
            string op = req.get_string_member_with_default ("op", "");
            string key = req.get_string_member_with_default ("key", "");
            if (key.has_prefix ("/") || key.contains ("..")) {
                fail ("failed", "invalid key");
                return;
            }
            try {
                switch (op) {
                    case "hello": {
                        var o = ok ();
                        o.set_int_member ("protocol", 1);
                        answer (o);
                        break;
                    }
                    case "put": {
                        string dir, name;
                        split (key, out dir, out name);
                        var folder = yield folder_at (dir, true);
                        int64 last = 0;
                        var entry = yield drive.upload (folder.id, name, File.new_for_path (req.get_string_member ("file")), null, (done, total) => {
                            if (done - last < 256 * 1024 && done != total) return;
                            last = done;
                            var p = new Json.Object ();
                            p.set_int_member ("progress", done);
                            answer (p);
                        });
                        (yield entries_in (folder))[name] = entry;
                        answer (ok ());
                        break;
                    }
                    case "get": {
                        var e = yield file_at (key);
                        if (e == null) {
                            fail ("not-found", "%s is missing".printf (key));
                            break;
                        }
                        yield drive.download (e, File.new_for_path (req.get_string_member ("file")));
                        answer (ok ());
                        break;
                    }
                    case "list": {
                        string prefix = req.get_string_member_with_default ("prefix", "");
                        var b = new Json.Builder ();
                        b.begin_array ();
                        var folder = yield folder_at (prefix, false);
                        if (folder != null) {
                            children.remove (folder.id);
                            yield collect (folder, prefix, b);
                        }
                        b.end_array ();
                        var o = ok ();
                        o.set_array_member ("entries", b.get_root ().get_array ());
                        answer (o);
                        break;
                    }
                    case "delete": {
                        var e = yield file_at (key);
                        if (e != null) {
                            yield drive.delete (e);
                            string dir, name;
                            split (key, out dir, out name);
                            var folder = folders[dir];
                            if (folder != null && children[folder.id] != null) children[folder.id].remove (name);
                        }
                        answer (ok ());
                        break;
                    }
                    case "space": {
                        var q = yield drive.quota ();
                        var o = ok ();
                        o.set_int_member ("used", q != null ? q.used : 0);
                        o.set_int_member ("total", q != null && q.total >= 0 ? q.total : 0);
                        answer (o);
                        break;
                    }
                    default:
                        fail ("unsupported", "unknown operation %s".printf (op));
                        break;
                }
            } catch (Error e) {
                string code = code_for (e);
                if (code != "not-found") {
                    folders.remove_all ();
                    children.remove_all ();
                    folders[""] = root_entry;
                }
                fail (code, e.message);
            }
        }

        private CloudEntry root_entry;

        private async void serve (string account_id) {
            input = new DataInputStream (new UnixInputStream (0, false));
            var m = yield manager ();
            Account? account = m != null ? m.get_account (account_id) : null;
            drive = account != null ? CloudDrive.for_account (account) : null;
            root_entry = new CloudEntry ();
            if (drive != null) {
                root_entry.id = drive.root_id;
                root_entry.is_folder = true;
                folders[""] = root_entry;
            }
            while (true) {
                string? line = null;
                try {
                    size_t length;
                    line = yield input.read_line_utf8_async (Priority.DEFAULT, null, out length);
                } catch (Error e) {
                    line = null;
                }
                if (line == null) break;
                Json.Object req;
                try {
                    var parser = new Json.Parser ();
                    parser.load_from_data (line);
                    req = parser.get_root ().get_object ();
                } catch (Error e) {
                    fail ("failed", "not a request");
                    continue;
                }
                if (drive == null && req.get_string_member_with_default ("op", "") != "hello") {
                    fail (m == null ? "offline" : "failed", m == null ? _("The online accounts service is not running")
                                                                  : _("The online account is no longer available"));
                    continue;
                }
                yield handle (req);
            }
            loop.quit ();
        }

        public static int main (string[] args) {
            Intl.setlocale (LocaleCategory.ALL, "");
            Environment.set_prgname ("singularity-backups-cloud");
            return new CloudDestination ().run (args);
        }
    }
}
