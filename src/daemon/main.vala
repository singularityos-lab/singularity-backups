namespace Singularity.Backups {

    public class DaemonApp : GLib.Application {
        private DaemonService? service = null;
        private uint registration = 0;
        private bool held = false;

        public DaemonApp () {
            Object (application_id: "dev.sinty.backups.Daemon", flags: ApplicationFlags.ALLOW_REPLACEMENT);
            inactivity_timeout = 60000;
        }

        public override bool dbus_register (DBusConnection connection, string object_path) throws Error {
            base.dbus_register (connection, object_path);
            string[] configs = {
                Path.build_filename (Config.DATADIR, "singularity", "backups.conf"),
                Path.build_filename (Config.SYSCONFDIR, "singularity", "backups.conf")
            };
            string? extra = Environment.get_variable ("SINGULARITY_BACKUPS_CONFIG");
            if (extra != null && extra != "") configs += extra;
            service = new DaemonService (connection, configs, Config.HELPER);
            service.keep_alive.connect (set_held);
            service.open_app.connect (() => {
                connection.call.begin ("dev.sinty.backups", "/dev/sinty/backups", "org.freedesktop.Application", "Activate",
                    new Variant ("(@a{sv})", new VariantBuilder (new VariantType ("a{sv}")).end ()), null, DBusCallFlags.NONE, 20000, null);
            });
            registration = connection.register_object ("/dev/sinty/backups/Daemon", service);
            return true;
        }

        public override void dbus_unregister (DBusConnection connection, string object_path) {
            if (registration != 0) connection.unregister_object (registration);
            registration = 0;
            base.dbus_unregister (connection, object_path);
        }

        private void set_held (bool needed) {
            if (needed && !held) {
                hold ();
                held = true;
            } else if (!needed && held) {
                held = false;
                release ();
            }
        }

        public override void activate () {
        }

        public static int main (string[] args) {
            Intl.setlocale (LocaleCategory.ALL, "");
            Intl.bindtextdomain ("singularity-backups", Config.LOCALEDIR);
            Intl.bind_textdomain_codeset ("singularity-backups", "UTF-8");
            Intl.textdomain ("singularity-backups");
            Environment.set_prgname ("singularity-backups-daemon");
            return new DaemonApp ().run (args);
        }
    }
}
