namespace Singularity.Backups {

    public class PowerSource : Object {
        private const string UPOWER = "org.freedesktop.UPower";
        private const string DISPLAY_DEVICE = "/org/freedesktop/UPower/devices/DisplayDevice";

        public bool available { get; private set; default = false; }
        public bool on_battery { get; private set; default = false; }
        public double percent { get; private set; default = -1; }
        public string backend { get; private set; default = "none"; }

        public signal void changed ();

        private DBusProxy? daemon = null;
        private DBusProxy? device = null;
        private string sysfs = "/sys/class/power_supply";
        private uint poll = 0;

        public async void start () {
            load_config ();
            try {
                daemon = yield new DBusProxy.for_bus (BusType.SYSTEM, DBusProxyFlags.DO_NOT_AUTO_START, null,
                    UPOWER, "/org/freedesktop/UPower", UPOWER, null);
                device = yield new DBusProxy.for_bus (BusType.SYSTEM, DBusProxyFlags.DO_NOT_AUTO_START, null,
                    UPOWER, DISPLAY_DEVICE, UPOWER + ".Device", null);
                if (daemon.g_name_owner != null && daemon.get_cached_property ("OnBattery") != null) {
                    backend = "upower";
                    daemon.g_properties_changed.connect (() => read_upower ());
                    device.g_properties_changed.connect (() => read_upower ());
                    read_upower ();
                    return;
                }
            } catch (Error e) {
                daemon = null;
                device = null;
            }
            daemon = null;
            device = null;
            if (read_sysfs ()) {
                backend = "sysfs";
                poll = Timeout.add_seconds (60, () => {
                    read_sysfs ();
                    return Source.CONTINUE;
                });
            }
        }

        private void load_config () {
            string[] dirs = {};
            foreach (string d in Environment.get_system_config_dirs ()) dirs += d;
            dirs += Config.SYSCONFDIR;
            foreach (string d in dirs) {
                var kf = new KeyFile ();
                try {
                    kf.load_from_file (Path.build_filename (d, "singularity", "power.conf"), KeyFileFlags.NONE);
                    if (kf.has_key ("Battery", "SysfsPath")) sysfs = kf.get_string ("Battery", "SysfsPath").strip ();
                    return;
                } catch (Error e) {
                }
            }
        }

        private void update (bool has, bool battery, double level) {
            bool differs = has != available || battery != on_battery || level != percent;
            available = has;
            on_battery = battery;
            percent = level;
            if (differs) changed ();
        }

        private void read_upower () {
            var ob = daemon.get_cached_property ("OnBattery");
            var pc = device != null ? device.get_cached_property ("Percentage") : null;
            var present = device != null ? device.get_cached_property ("IsPresent") : null;
            bool has = present == null || present.get_boolean ();
            update (true, ob != null && ob.get_boolean () && has, pc != null ? pc.get_double () : -1);
        }

        private static string read_value (string dir, string name) {
            string text;
            try {
                FileUtils.get_contents (Path.build_filename (dir, name), out text);
            } catch (Error e) {
                return "";
            }
            return text.strip ();
        }

        public bool read_sysfs () {
            Dir dir;
            try {
                dir = Dir.open (sysfs);
            } catch (FileError e) {
                return false;
            }
            bool any_battery = false;
            bool mains_online = false;
            bool discharging = false;
            double total = 0;
            int count = 0;
            string? name;
            while ((name = dir.read_name ()) != null) {
                string path = Path.build_filename (sysfs, name);
                string type = read_value (path, "type");
                if (type == "Mains" || type == "USB") {
                    if (read_value (path, "online") == "1") mains_online = true;
                    continue;
                }
                if (type != "Battery" || read_value (path, "scope") == "Device") continue;
                any_battery = true;
                string status = read_value (path, "status");
                if (status == "Discharging") discharging = true;
                string cap = read_value (path, "capacity");
                if (cap != "") {
                    total += double.parse (cap);
                    count++;
                }
            }
            if (!any_battery) {
                update (false, false, -1);
                return true;
            }
            update (true, discharging && !mains_online, count > 0 ? total / count : -1);
            return true;
        }
    }
}
