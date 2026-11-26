namespace Singularity.Backups {

    internal class BackupsIntents : Object {

        private static Json.Node value_node (Variant v) {
            var n = new Json.Node (Json.NodeType.VALUE);
            if (v.is_of_type (VariantType.STRING)) n.set_string (v.get_string ());
            else if (v.is_of_type (VariantType.BYTESTRING)) n.set_string (v.get_bytestring ());
            else if (v.is_of_type (VariantType.BOOLEAN)) n.set_boolean (v.get_boolean ());
            else if (v.is_of_type (VariantType.INT64)) n.set_int (v.get_int64 ());
            else if (v.is_of_type (VariantType.UINT64)) n.set_int ((int64) v.get_uint64 ());
            else if (v.is_of_type (VariantType.INT32)) n.set_int (v.get_int32 ());
            else if (v.is_of_type (VariantType.UINT32)) n.set_int (v.get_uint32 ());
            else if (v.is_of_type (VariantType.DOUBLE)) n.set_double (v.get_double ());
            else if (v.is_of_type (VariantType.VARIANT)) return value_node (v.get_variant ());
            else if (v.is_of_type (VariantType.STRING_ARRAY)) {
                var a = new Json.Array ();
                foreach (var s in v.get_strv ()) a.add_string_element (s);
                n = new Json.Node (Json.NodeType.ARRAY);
                n.set_array (a);
            } else n.set_string (v.print (false));
            return n;
        }

        private static Json.Object table (HashTable<string, Variant> t) {
            var o = new Json.Object ();
            t.foreach ((k, v) => o.set_member (k, value_node (v)));
            if (o.has_member ("created")) o.set_string_member ("when", new DateTime.from_unix_local (o.get_int_member ("created")).format ("%Y-%m-%d %H:%M"));
            if (o.has_member ("mtime")) o.set_string_member ("modified", new DateTime.from_unix_local (o.get_int_member ("mtime")).format ("%Y-%m-%d %H:%M"));
            return o;
        }

        private static Json.Node tables (HashTable<string, Variant>[] list) {
            var a = new Json.Array ();
            foreach (var t in list) a.add_object_element (table (t));
            var n = new Json.Node (Json.NodeType.ARRAY);
            n.set_array (a);
            return n;
        }

        private static Json.Node object (Json.Object o) {
            var n = new Json.Node (Json.NodeType.OBJECT);
            n.set_object (o);
            return n;
        }

        private static string text (Json.Object args, string key) {
            return args.has_member (key) ? args.get_string_member (key).strip () : "";
        }

        private static string home_relative (string path) {
            var home = Environment.get_home_dir ();
            var p = path.strip ();
            if (p.has_prefix ("~/")) p = p.substring (2);
            else if (p == "~" || p == home) p = "";
            else if (p.has_prefix (home + "/")) p = p.substring (home.length + 1);
            while (p.has_prefix ("/")) p = p.substring (1);
            return p;
        }

        private static async DaemonProxy daemon_of (BackupsApp app) throws Error {
            while (!app.daemon_checked) {
                ulong id = 0;
                id = app.daemon_ready.connect (() => {
                    app.disconnect (id);
                    daemon_of.callback ();
                });
                yield;
            }
            if (app.daemon == null) throw new IOError.NOT_FOUND ("the backup service is not running");
            return app.daemon;
        }

        private static async string snapshot_of (DaemonProxy d, Json.Object args) throws Error {
            var id = text (args, "snapshot");
            var list = yield d.list_snapshots ();
            if (list.length == 0) throw new IOError.NOT_FOUND ("there are no backups yet");
            if (id == "" || id == "latest") return get_str (list[list.length - 1], "id");
            foreach (var s in list) if (get_str (s, "id") == id) return id;
            throw new IOError.NOT_FOUND ("no backup %s; see backups_list", id);
        }

        private static async Json.Node work (string name, DaemonProxy d, Json.Object args) throws Error {
            switch (name) {
                case "backups_status": return yield status (d, args);
                case "backups_list": return yield list (d, args);
                case "backups_browse": return yield browse (d, args);
                case "backups_versions": return yield versions (d, args);
                case "backups_back_up_now": return yield back_up (d, args);
                case "backups_cancel": return yield cancel (d, args);
                case "backups_restore": return yield restore (d, args);
                case "backups_verify": return yield verify (d, args);
                case "backups_delete": return yield remove (d, args);
                case "backups_destinations": return yield destinations (d, args);
                default: return yield set_destination (d, args);
            }
        }

        private static async void run (BackupsApp app, string name, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold ();
            try {
                var d = yield daemon_of (app);
                reply (yield work (name, d, args), null);
            } catch (Error e) {
                reply (null, new IOError.FAILED ("%s", error_text (e)));
            } finally {
                app.release ();
            }
        }

        private static async Json.Node status (DaemonProxy d, Json.Object args) throws Error {
            var o = table (yield d.get_status ());
            o.set_string_member ("state", d.state);
            o.set_boolean_member ("configured", d.configured);
            o.set_string_member ("destination", d.destination_name);
            if (d.state == "running" || d.state == "restoring") {
                o.set_double_member ("progress", d.fraction);
                o.set_string_member ("phase", d.phase);
                o.set_string_member ("item", d.current_item);
            }
            if (d.last_backup > 0) o.set_string_member ("last_backup", new DateTime.from_unix_local (d.last_backup).format ("%Y-%m-%d %H:%M"));
            if (d.next_backup > 0) o.set_string_member ("next_backup", new DateTime.from_unix_local (d.next_backup).format ("%Y-%m-%d %H:%M"));
            if (d.last_error != "") o.set_string_member ("last_error", d.last_error);
            return object (o);
        }

        private static async Json.Node list (DaemonProxy d, Json.Object args) throws Error {
            return tables (yield d.list_snapshots ());
        }

        private static async Json.Node browse (DaemonProxy d, Json.Object args) throws Error {
            var snap = yield snapshot_of (d, args);
            return tables (yield d.list_directory (snap, home_relative (text (args, "path"))));
        }

        private static async Json.Node versions (DaemonProxy d, Json.Object args) throws Error {
            var p = home_relative (text (args, "path"));
            if (p == "") throw new IOError.INVALID_ARGUMENT ("give the path of a file in the home folder");
            return tables (yield d.versions (p));
        }

        private static async Json.Node back_up (DaemonProxy d, Json.Object args) throws Error {
            if (!d.configured) throw new IOError.NOT_INITIALIZED ("backups have no destination yet; see backups_destinations");
            if (d.state == "running") {
                var n = yield status (d, args);
                n.get_object ().set_boolean_member ("already_running", true);
                return n;
            }
            var before = d.last_backup;
            var error_before = d.last_error;
            d.back_up_now ();
            for (int i = 0; i < 100 && d.state != "running" && d.last_backup == before && d.last_error == error_before; i++) {
                Timeout.add (100, back_up.callback);
                yield;
            }
            return yield status (d, args);
        }

        private static async Json.Node cancel (DaemonProxy d, Json.Object args) throws Error {
            if (d.state != "running") throw new IOError.INVALID_ARGUMENT ("no backup is running");
            d.cancel ();
            return yield status (d, args);
        }

        private static async Json.Node restore (DaemonProxy d, Json.Object args) throws Error {
            var snap = yield snapshot_of (d, args);
            string[] paths = {};
            if (args.has_member ("paths")) args.get_array_member ("paths").foreach_element ((a, i, n) => paths += home_relative (n.get_string ()));
            if (paths.length == 0) throw new IOError.INVALID_ARGUMENT ("give the paths to bring back");
            var policy = text (args, "if_exists");
            if (policy == "") policy = "keep_both";
            if (policy != "keep_both" && policy != "replace" && policy != "skip") throw new IOError.INVALID_ARGUMENT ("if_exists is keep_both, replace or skip");
            var target = text (args, "to");
            var done = yield d.restore (snap, paths, target, policy == "keep_both" ? "keep-both" : policy);
            var o = new Json.Object ();
            o.set_string_member ("snapshot", snap);
            var a = new Json.Array ();
            foreach (var p in done) a.add_string_element (p);
            o.set_array_member ("restored", a);
            return object (o);
        }

        private static async Json.Node verify (DaemonProxy d, Json.Object args) throws Error {
            var snap = yield snapshot_of (d, args);
            var o = table (yield d.verify (snap));
            o.set_string_member ("snapshot", snap);
            return object (o);
        }

        private static async Json.Node remove (DaemonProxy d, Json.Object args) throws Error {
            var id = text (args, "snapshot");
            if (id == "" || id == "latest") throw new IOError.INVALID_ARGUMENT ("give the exact id of the backup to delete");
            var snap = yield snapshot_of (d, args);
            yield d.delete_snapshot (snap);
            return tables (yield d.list_snapshots ());
        }

        private static async Json.Node destinations (DaemonProxy d, Json.Object args) throws Error {
            return tables (yield d.list_destinations ());
        }

        private static async Json.Node set_destination (DaemonProxy d, Json.Object args) throws Error {
            var kind = text (args, "kind");
            var target = text (args, "target");
            if (kind != "disk" && kind != "folder") throw new IOError.INVALID_ARGUMENT ("kind is disk or folder");
            if (target == "") throw new IOError.INVALID_ARGUMENT ("give the disk id or the folder path from backups_destinations");
            var name = text (args, "name") != "" ? text (args, "name") : Path.get_basename (target);
            var encrypted = args.has_member ("encrypted") && args.get_boolean_member ("encrypted");
            var o = table (yield d.set_destination (kind, target, name, encrypted));
            o.set_string_member ("destination", d.destination_name);
            if (o.has_member ("snapshots") && o.get_int_member ("snapshots") == 0) o.set_string_member ("note", "the folder held no backups, so a first one started on its own; follow it with backups_status");
            return object (o);
        }

        private static void add (BackupsApp app, string name, string desc, string schema, Singularity.AppIntentRisk risk) {
            app.agent.add_async_intent (name, desc, schema, risk, (args, reply) => {
                run.begin (app, name, args, (owned) reply);
            });
        }

        internal static void install (BackupsApp app) {
            const string NONE = "{\"type\":\"object\",\"properties\":{}}";
            const string SNAP = "{\"type\":\"object\",\"properties\":{\"snapshot\":{\"type\":\"string\"}}}";
            add (app, "backups_status", "Where backups go, whether one is running and how far, the last and next backup, space used and free, and any error.",
                NONE, Singularity.AppIntentRisk.READ);
            add (app, "backups_list", "Every backup kept, oldest first: id, when, how many files and bytes, what changed.",
                NONE, Singularity.AppIntentRisk.READ);
            add (app, "backups_browse", "The files and folders of a folder as they were in a backup (latest when snapshot is omitted). path is relative to the home folder; empty is the home folder itself.",
                "{\"type\":\"object\",\"properties\":{\"snapshot\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"}}}", Singularity.AppIntentRisk.READ);
            add (app, "backups_versions", "Every different version of a file kept in the backups, with the backup that holds it.",
                "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}", Singularity.AppIntentRisk.READ);
            add (app, "backups_back_up_now", "Start a backup now. It runs in the background: follow it with backups_status.",
                NONE, Singularity.AppIntentRisk.UNDOABLE);
            add (app, "backups_cancel", "Stop the backup that is running.",
                NONE, Singularity.AppIntentRisk.UNDOABLE);
            add (app, "backups_restore", "Bring files or folders back from a backup (latest when snapshot is omitted). They return to where they were, or into the folder given as to. When a file is already there: keep_both (default) adds a copy, replace moves the current one to the trash, skip leaves it.",
                "{\"type\":\"object\",\"properties\":{\"snapshot\":{\"type\":\"string\"},\"paths\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"to\":{\"type\":\"string\"},\"if_exists\":{\"type\":\"string\",\"enum\":[\"keep_both\",\"replace\",\"skip\"]}},\"required\":[\"paths\"]}",
                Singularity.AppIntentRisk.UNDOABLE);
            add (app, "backups_verify", "Check that a backup can still be read in full (latest when snapshot is omitted).",
                SNAP, Singularity.AppIntentRisk.READ);
            add (app, "backups_delete", "Delete one backup for good, by its exact id.",
                "{\"type\":\"object\",\"properties\":{\"snapshot\":{\"type\":\"string\"}},\"required\":[\"snapshot\"]}", Singularity.AppIntentRisk.IRREVERSIBLE);
            add (app, "backups_destinations", "The disks and folders that can hold backups, and which one is in use.",
                NONE, Singularity.AppIntentRisk.READ);
            add (app, "backups_set_destination", "Make a disk or a folder the place backups go. Existing backups there are picked up.",
                "{\"type\":\"object\",\"properties\":{\"kind\":{\"type\":\"string\",\"enum\":[\"disk\",\"folder\"]},\"target\":{\"type\":\"string\"},\"name\":{\"type\":\"string\"},\"encrypted\":{\"type\":\"boolean\"}},\"required\":[\"kind\",\"target\"]}",
                Singularity.AppIntentRisk.UNDOABLE);
        }
    }
}
