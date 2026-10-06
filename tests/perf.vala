using Singularity.Backups;

int prune (string repository, int keep) {
    var backend = new LocalBackend ();
    try {
        backend.open (repository);
        int64 start = get_monotonic_time ();
        backend.prune (keep);
        stdout.printf ("store=%s pruned seconds=%.2f\n", backend.store_mode,
                       (get_monotonic_time () - start) / 1000000.0);
    } catch (Error e) {
        stderr.printf ("%s\n", e.message);
        return 1;
    }
    return 0;
}

int main (string[] args) {
    if (args.length == 4 && args[1] == "prune") return prune (args[2], int.parse (args[3]));
    if (args.length < 4) {
        stderr.printf ("usage: backups-perf HOME REPOSITORY tree|objects [smart|keep-last]\n       backups-perf prune REPOSITORY KEEP\n");
        return 2;
    }
    var backend = new LocalBackend ();
    backend.requested_store = args[3];
    var plan = new BackupPlan ();
    plan.source_home = args[1];
    plan.exclusions = Exclusions.DEFAULTS;
    plan.host = "perf";
    plan.retention = args.length > 4 ? RetentionMode.parse (args[4]) : RetentionMode.SMART;
    try {
        backend.open (args[2]);
        var roots = new Gee.ArrayList<SourceRoot> ();
        roots.add (new UserDataProvider ().prepare (plan, args[2], args[2]));
        int64 start = get_monotonic_time ();
        string last_phase = "";
        var info = backend.create_snapshot (plan, roots, null, (f, phase, item) => {
            if (phase == last_phase) return;
            last_phase = phase;
            stderr.printf ("%.2f %s\n", (get_monotonic_time () - start) / 1000000.0, phase);
        });
        double seconds = (get_monotonic_time () - start) / 1000000.0;
        stdout.printf ("store=%s snapshot=%s entries=%llu added_files=%llu added_bytes=%llu anchor_copies=%llu seconds=%.2f\n",
                       backend.store_mode, info.id, info.files, info.added_files, info.added_bytes,
                       backend.last_anchor_copies, seconds);
    } catch (Error e) {
        stderr.printf ("%s\n", e.message);
        return 1;
    }
    return 0;
}
