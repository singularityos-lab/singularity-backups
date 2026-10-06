namespace Singularity.Backups {

    public class Exclusions : Object {
        private GenericArray<PatternSpec> names = new GenericArray<PatternSpec> ();
        private GenericArray<PatternSpec> paths = new GenericArray<PatternSpec> ();
        private Gee.HashSet<string> anchored = new Gee.HashSet<string> ();

        public const string[] DEFAULTS = {
            ".cache",
            ".local/share/Trash",
            ".var/app/*/cache",
            "node_modules",
            ".tmp",
            "*.tmp",
            "*.part",
            "*.crdownload"
        };

        private string[] _patterns = {};

        public string[] patterns {
            owned get {
                string[] all = _patterns;
                foreach (string a in anchored) all += "/" + a;
                return all;
            }
        }

        public Exclusions (string[] patterns) {
            foreach (string raw in patterns) add (raw);
        }

        public void add (string raw) {
            string p = raw.strip ();
            while (p.has_suffix ("/") && p.length > 1) p = p.substring (0, p.length - 1);
            if (p == "" || p == "/") return;
            if (!p.has_prefix ("/") || p.contains ("*") || p.contains ("?")) _patterns += p;
            if (p.has_prefix ("/")) {
                string rel = p.substring (1);
                if (rel.contains ("*") || rel.contains ("?")) paths.add (new PatternSpec (rel));
                else anchored.add (rel);
            } else if (p.contains ("/")) {
                paths.add (new PatternSpec (p));
                paths.add (new PatternSpec ("*/" + p));
            } else {
                names.add (new PatternSpec (p));
            }
        }

        public void add_path (string relative) {
            if (relative != "") anchored.add (relative);
        }

        public bool excluded (string relative) {
            if (relative == "") return false;
            if (anchored.contains (relative)) return true;
            string name = Path.get_basename (relative);
            for (uint i = 0; i < names.length; i++) {
                if (names[i].match_string (name)) return true;
            }
            for (uint i = 0; i < paths.length; i++) {
                if (paths[i].match_string (relative)) return true;
            }
            return false;
        }
    }
}
