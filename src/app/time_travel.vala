using Gtk;
using Singularity.Widgets;

namespace Singularity.Backups {

    public class TimeTravelView : Widget {
        private const double FOCAL = 3.2;
        private const double MAX_DEPTH = 7.5;
        private const int TIMELINE_GAP = 8;
        private const int STARS = 180;

        public BackupsApp app { get; construct; }
        public unowned BackupsWindow window { get; construct; }

        public signal void exit_requested ();
        public signal void toast (Toast toast);

        private double _position = 0;
        private double _intro = 0;
        private double _fade = 1;
        private Gdk.Paintable? fade_from = null;
        private int selected = 0;
        private Gee.ArrayList<SnapshotItem> items = new Gee.ArrayList<SnapshotItem> ();
        private string image_folder = "";
        private Gee.HashSet<string> version_ids = new Gee.HashSet<string> ();
        private string versions_path = "";

        private SnapshotBrowser card;
        private Timeline timeline;
        private Box bar;
        private Label date_label;
        private Button restore_button;
        private MenuButton more_button;
        private Box arrows;
        private Button older_button;
        private Button newer_button;
        private QuickLook quick_look;
        private float[] star_angle = new float[STARS];
        private float[] star_radius = new float[STARS];
        private float[] star_size = new float[STARS];
        private float[] star_light = new float[STARS];
        private Gdk.RGBA accent = { 0.36f, 0.62f, 1.0f, 1.0f };
        private bool closing = false;

        public double position {
            get { return _position; }
            set {
                _position = value;
                timeline.position = value;
                queue_draw ();
            }
        }

        public double intro {
            get { return _intro; }
            set {
                _intro = value;
                queue_draw ();
            }
        }

        public double fade {
            get { return _fade; }
            set {
                _fade = value;
                queue_draw ();
            }
        }

        public TimeTravelView (BackupsApp app, BackupsWindow window) {
            Object (app: app, window: window);
        }

        construct {
            add_css_class ("time-travel");
            focusable = true;
            var rng = new Rand.with_seed (20260928);
            for (int i = 0; i < STARS; i++) {
                star_angle[i] = (float) rng.double_range (0, 2 * Math.PI);
                star_radius[i] = (float) rng.next_double ();
                star_size[i] = (float) rng.double_range (0.6, 2.2);
                star_light[i] = (float) rng.double_range (0.25, 0.95);
            }
            var parsed = Gdk.RGBA ();
            if (parsed.parse (Singularity.Style.StyleManager.get_default ().accent_hex)) accent = parsed;

            card = new SnapshotBrowser (app);
            card.set_parent (this);
            card.folder_changed.connect ((f) => {
                clear_images ();
                image_folder = f;
            });
            card.preview_requested.connect ((e) => preview.begin (e));
            card.selection_changed.connect (() => sync_actions ());

            timeline = new Timeline ();
            timeline.set_accent (accent);
            timeline.set_parent (this);
            timeline.activated.connect ((i) => navigate (i));

            arrows = new Box (Orientation.VERTICAL, 10);
            arrows.add_css_class ("tt-arrows");
            older_button = new Button.from_icon_name ("go-up-symbolic");
            older_button.tooltip_text = _("Older (Page Up)");
            older_button.add_css_class ("tt-arrow");
            older_button.clicked.connect (() => step (1));
            newer_button = new Button.from_icon_name ("go-down-symbolic");
            newer_button.tooltip_text = _("Newer (Page Down)");
            newer_button.add_css_class ("tt-arrow");
            newer_button.clicked.connect (() => step (-1));
            arrows.append (older_button);
            arrows.append (newer_button);
            arrows.set_parent (this);

            bar = new Box (Orientation.HORIZONTAL, 12);
            bar.add_css_class ("tt-bar");
            var cancel = new Button.with_label (_("Cancel"));
            cancel.add_css_class ("pill");
            cancel.clicked.connect (() => leave ());
            bar.append (cancel);
            date_label = new Label ("");
            date_label.add_css_class ("tt-date");
            date_label.width_chars = 24;
            bar.append (date_label);
            more_button = new MenuButton ();
            more_button.icon_name = "view-more-symbolic";
            more_button.tooltip_text = _("More Restore Options");
            more_button.add_css_class ("pill");
            var menu = new GLib.Menu ();
            menu.append (_("Restore To…"), "tt.restore-to");
            menu.append (_("Restore Everything From This Backup…"), "tt.restore-all");
            menu.append (_("Quick Look"), "tt.preview");
            more_button.menu_model = menu;
            bar.append (more_button);
            restore_button = new Button.with_label (_("Restore"));
            restore_button.add_css_class ("pill");
            restore_button.add_css_class ("suggested-action");
            restore_button.clicked.connect (() => restore.begin ("", ConflictPolicy.KEEP_BOTH));
            bar.append (restore_button);
            bar.set_parent (this);

            quick_look = new QuickLook ();
            quick_look.visible = false;
            quick_look.restore_requested.connect ((e) => {
                quick_look.close ();
                restore_items.begin (single (e), "");
            });
            quick_look.set_parent (this);

            var group = new SimpleActionGroup ();
            tt_group = group;
            var restore_to = new SimpleAction ("restore-to", null);
            restore_to.activate.connect (() => restore_to_folder.begin ());
            group.add_action (restore_to);
            var restore_all = new SimpleAction ("restore-all", null);
            restore_all.activate.connect (() => confirm_restore_all ());
            group.add_action (restore_all);
            var preview_action = new SimpleAction ("preview", null);
            preview_action.activate.connect (() => {
                var sel = card.selected_items ();
                if (sel.size > 0) preview.begin (sel[0]);
            });
            group.add_action (preview_action);
            insert_action_group ("tt", group);

            var keys = new EventControllerKey ();
            keys.propagation_phase = PropagationPhase.CAPTURE;
            keys.key_pressed.connect ((keyval, code, state) => {
                if (keyval == Gdk.Key.Escape) {
                    if (quick_look.visible) quick_look.close ();
                    else leave ();
                    return true;
                }
                if (keyval == Gdk.Key.space && !quick_look.visible) {
                    var sel = card.selected_items ();
                    if (sel.size > 0) {
                        preview.begin (sel[0]);
                        return true;
                    }
                    return false;
                }
                bool ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
                if (keyval == Gdk.Key.Page_Up || (ctrl && keyval == Gdk.Key.Up)) {
                    step (1);
                    return true;
                }
                if (keyval == Gdk.Key.Page_Down || (ctrl && keyval == Gdk.Key.Down)) {
                    step (-1);
                    return true;
                }
                return false;
            });
            add_controller (keys);

            var scroll = new EventControllerScroll (EventControllerScrollFlags.VERTICAL | EventControllerScrollFlags.DISCRETE);
            scroll.scroll.connect ((dx, dy) => {
                if (pointer_over_card) return false;
                if (dy < 0) step (1);
                else if (dy > 0) step (-1);
                return true;
            });
            add_controller (scroll);
            var motion = new EventControllerMotion ();
            motion.motion.connect ((x, y) => {
                Graphene.Rect bounds;
                pointer_over_card = card.compute_bounds (this, out bounds) && bounds.contains_point ({ (float) x, (float) y });
            });
            add_controller (motion);

            ((DBusProxy) app.daemon).g_properties_changed.connect (() => sync_actions ());
        }

        private bool pointer_over_card = false;
        private SimpleActionGroup? tt_group = null;

        protected override void dispose () {
            card.unparent ();
            timeline.unparent ();
            arrows.unparent ();
            bar.unparent ();
            quick_look.unparent ();
            base.dispose ();
        }

        public void shutdown () {
            closing = true;
            Singularity.Motion.cancel (this, "position");
            Singularity.Motion.cancel (this, "intro");
        }

        private static Gee.List<EntryItem> single (EntryItem e) {
            var l = new Gee.ArrayList<EntryItem> ();
            l.add (e);
            return l;
        }

        public async void start (string folder, string? select, bool versions) {
            items.clear ();
            items.add (new SnapshotItem.now ());
            try {
                var list = yield app.daemon.list_snapshots ();
                for (int i = list.length - 1; i >= 0; i--) items.add (new SnapshotItem.from_table (list[i]));
            } catch (Error e) {
                toast (new Toast (error_text (e)));
            }
            card.latest_snapshot = items.size > 1 ? items[1].id : "";
            timeline.set_items (items);
            image_folder = folder;
            selected = 0;
            _position = 0;
            timeline.selected = 0;
            timeline.position = 0;
            yield card.show_snapshot (items[0], folder, select);
            if (versions && select != null) yield load_versions (folder == "" ? select : folder + "/" + select);
            sync_actions ();
            grab_focus ();
            card.focus_list ();
            intro = 0;
            var anim = Singularity.Motion.tween (this, "intro", 1.0, Singularity.Motion.Duration.SCENE.ms (), Singularity.Motion.Curve.EMPHASIZED);
            anim.reduced_mode = Singularity.Animation.ReducedMode.SHORTEN;
        }

        public async void open_at (string path, bool versions) {
            string folder = path;
            string? select = null;
            var f = File.new_for_path (Path.build_filename (Environment.get_home_dir (), path));
            if (path != "" && (versions || f.query_file_type (FileQueryInfoFlags.NOFOLLOW_SYMLINKS) != FileType.DIRECTORY)) {
                folder = path.contains ("/") ? Path.get_dirname (path) : "";
                select = Path.get_basename (path);
            }
            clear_images ();
            image_folder = folder;
            yield card.show_snapshot (items[selected], folder, select);
            version_ids.clear ();
            foreach (var it in items) it.has_version = false;
            if (versions && select != null) yield load_versions (path);
            timeline.queue_draw ();
        }

        private async void load_versions (string path) {
            versions_path = path;
            try {
                foreach (var v in yield app.daemon.versions (path)) version_ids.add (get_str (v, "snapshot"));
            } catch (Error e) {
                return;
            }
            foreach (var it in items) it.has_version = !it.live && version_ids.contains (it.id);
            timeline.queue_draw ();
            if (version_ids.size == 0) toast (new Toast (_("This file is not in any backup yet")));
        }

        private void clear_images () {
            foreach (var it in items) it.image = null;
        }

        private void step (int direction) {
            int target = selected + direction;
            if (version_ids.size > 0) {
                while (target > 0 && target < items.size && !items[target].has_version) target += direction;
                if (target == 0 || target >= items.size) target = selected + direction;
            }
            if (target < 0 || target >= items.size) return;
            navigate (target);
        }

        public void navigate (int target) {
            if (target == selected || target < 0 || target >= items.size || closing) return;
            if (card.get_width () > 0) {
                var paintable = new WidgetPaintable (card);
                items[selected].image = paintable.get_current_image ();
            }
            var leaving = items[selected].image;
            selected = target;
            timeline.selected = target;
            var names = card.selected_items ();
            string? keep = names.size > 0 ? names[0].name : null;
            card.show_snapshot.begin (items[target], card.folder, keep);
            sync_actions ();
            if (Singularity.Motion.reduced ()) {
                Singularity.Motion.cancel (this, "position");
                position = target;
                fade_from = leaving;
                fade = 0;
                var anim = new Singularity.Animation.TimedAnimation.with_curve (this, 0, 1,
                    Singularity.Motion.Duration.MEDIUM.ms (), Singularity.Motion.Curve.STANDARD);
                anim.reduced_mode = Singularity.Animation.ReducedMode.FULL;
                anim.tick.connect (() => fade = anim.value);
                anim.done.connect (() => {
                    fade = 1;
                    fade_from = null;
                });
                anim.play ();
            } else {
                fade_from = null;
                fade = 1;
                Singularity.Motion.spring_to (this, "position", target, Singularity.Motion.Spring.GENTLE);
            }
        }

        private void sync_actions () {
            if (items.size == 0) return;
            var item = items[selected];
            date_label.label = item.title ();
            older_button.sensitive = selected + 1 < items.size;
            newer_button.sensitive = selected > 0;
            var sel = card.selected_items ();
            bool removed_selected = false;
            foreach (var e in sel) if (e.change == "removed") removed_selected = true;
            bool busy = app.daemon.state == "backing-up" || app.daemon.state == "restoring";
            restore_button.sensitive = !busy && (item.live ? removed_selected : (sel.size > 0 || card.folder != ""));
            var group = tt_group;
            if (group != null) {
                ((SimpleAction) group.lookup_action ("restore-to")).set_enabled (!busy && !item.live && (sel.size > 0 || card.folder != ""));
                ((SimpleAction) group.lookup_action ("restore-all")).set_enabled (!busy && !item.live);
                ((SimpleAction) group.lookup_action ("preview")).set_enabled (sel.size > 0);
            }
        }

        private void leave () {
            if (closing) return;
            closing = true;
            if (Singularity.Motion.reduced ()) {
                exit_requested ();
                return;
            }
            var anim = Singularity.Motion.tween (this, "intro", 0.0, Singularity.Motion.Duration.LARGE.exit_ms (), Singularity.Motion.Curve.EXIT);
            anim.done.connect (() => exit_requested ());
        }

        public override SizeRequestMode get_request_mode () {
            return SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure (Orientation orientation, int for_size, out int minimum, out int natural,
                                      out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = -1;
            natural_baseline = -1;
            minimum = orientation == Orientation.HORIZONTAL ? 560 : 420;
            natural = minimum;
        }

        private Graphene.Rect card_rect;

        public override void size_allocate (int width, int height, int baseline) {
            int tl_min, tl_nat;
            timeline.measure (Orientation.HORIZONTAL, -1, out tl_min, out tl_nat, null, null);
            int top = 56;
            var tl_alloc = Allocation () { x = width - tl_nat - TIMELINE_GAP, y = top, width = tl_nat, height = int.max (0, height - top - 24) };
            timeline.allocate_size (tl_alloc, -1);

            int area_w = width - tl_nat - TIMELINE_GAP;
            int bar_min, bar_nat, bh_min, bh_nat;
            bar.measure (Orientation.HORIZONTAL, -1, out bar_min, out bar_nat, null, null);
            bar.measure (Orientation.VERTICAL, bar_nat, out bh_min, out bh_nat, null, null);
            int bar_w = int.min (bar_nat, area_w - 24);
            var bar_alloc = Allocation () { x = (area_w - bar_w) / 2, y = height - bh_nat - 24, width = bar_w, height = bh_nat };
            bar.allocate_size (bar_alloc, -1);

            int avail_h = bar_alloc.y - top - 28;
            int card_w = (int) double.min (860, area_w * 0.74);
            int card_h = (int) double.min (560, avail_h * 0.74);
            card_w = int.max (card_w, 320);
            card_h = int.max (card_h, 240);
            int card_x = (area_w - card_w) / 2;
            int card_y = bar_alloc.y - 28 - card_h;
            card.allocate_size (Allocation () { x = card_x, y = card_y, width = card_w, height = card_h }, -1);
            card_rect = Graphene.Rect ();
            card_rect.init (card_x, card_y, card_w, card_h);

            int aw_min, aw_nat, ah_min, ah_nat;
            arrows.measure (Orientation.HORIZONTAL, -1, out aw_min, out aw_nat, null, null);
            arrows.measure (Orientation.VERTICAL, aw_nat, out ah_min, out ah_nat, null, null);
            int ax = int.min (card_x + card_w + 20, area_w - aw_nat - 4);
            arrows.allocate_size (Allocation () { x = ax, y = card_y + (card_h - ah_nat) / 2, width = aw_nat, height = ah_nat }, -1);

            quick_look.allocate_size (Allocation () { x = 0, y = 0, width = width, height = height }, -1);
        }

        private void depth_transform (double d, out double scale, out double cx, out double cy) {
            float w = card_rect.get_width ();
            float h = card_rect.get_height ();
            double fx = card_rect.get_x () + w / 2.0;
            double fy = card_rect.get_y () + h / 2.0;
            double vy = card_rect.get_y () - h * 0.42;
            scale = FOCAL / (FOCAL + d);
            cx = fx;
            cy = vy + (fy - vy) * scale;
        }

        private double frame_alpha (double d) {
            if (d < 0) return (1.0 + d).clamp (0, 1);
            return (1.0 - d / (MAX_DEPTH + 0.5)).clamp (0, 1);
        }

        private void draw_background (Snapshot snap, int width, int height) {
            var full = Graphene.Rect ();
            full.init (0, 0, width, height);
            Gsk.ColorStop[] stops = {
                { 0.0f, { 0.05f, 0.07f, 0.16f, 1 } },
                { 0.55f, { 0.02f, 0.03f, 0.08f, 1 } },
                { 1.0f, { 0.0f, 0.0f, 0.02f, 1 } }
            };
            var start = Graphene.Point ();
            start.init (0, 0);
            var end = Graphene.Point ();
            end.init (0, height);
            snap.append_linear_gradient (full, start, end, stops);

            double vx = card_rect.get_x () + card_rect.get_width () / 2.0;
            double vy = card_rect.get_y () - card_rect.get_height () * 0.42;
            var center = Graphene.Point ();
            center.init ((float) vx, (float) vy);
            Gdk.RGBA glow = accent;
            glow.alpha = (float) (0.30 * _intro);
            Gdk.RGBA clear = accent;
            clear.alpha = 0;
            Gsk.ColorStop[] glow_stops = { { 0.0f, glow }, { 1.0f, clear } };
            snap.append_radial_gradient (full, center, width * 0.42f, height * 0.36f, 0, 1, glow_stops);

            double travel = Singularity.Motion.reduced () ? selected : _position;
            double reach = Math.sqrt ((double) width * width + (double) height * height) * 0.6;
            for (int i = 0; i < STARS; i++) {
                double r = star_radius[i] + travel * 0.045;
                r = r - Math.floor (r);
                double rr = r * r * reach;
                double x = vx + Math.cos (star_angle[i]) * rr;
                double y = vy + Math.sin (star_angle[i]) * rr * 0.8;
                if (x < 0 || y < 0 || x > width || y > height) continue;
                double size = star_size[i] * (0.4 + r);
                Gdk.RGBA c = { 0.85f, 0.9f, 1, (float) (star_light[i] * double.min (1, r * 4) * _intro) };
                var dot = Graphene.Rect ();
                dot.init ((float) (x - size / 2), (float) (y - size / 2), (float) size, (float) size);
                var rounded = Gsk.RoundedRect ();
                rounded.init_from_rect (dot, (float) size / 2);
                snap.push_rounded_clip (rounded);
                snap.append_color (c, dot);
                snap.pop ();
            }
        }

        private void draw_generic_frame (Snapshot snap, SnapshotItem item, float w, float h) {
            var rect = Graphene.Rect ();
            rect.init (0, 0, w, h);
            var rounded = Gsk.RoundedRect ();
            rounded.init_from_rect (rect, 14);
            Gdk.RGBA ink = card.get_color ();
            bool light = (ink.red + ink.green + ink.blue) / 3 < 0.5;
            Gdk.RGBA bg = light ? Gdk.RGBA () { red = 0.96f, green = 0.957f, blue = 0.95f, alpha = 1 }
                                : Gdk.RGBA () { red = 0.13f, green = 0.14f, blue = 0.18f, alpha = 1 };
            Gdk.RGBA header = light ? Gdk.RGBA () { red = 0.93f, green = 0.93f, blue = 0.935f, alpha = 1 }
                                    : Gdk.RGBA () { red = 0.17f, green = 0.18f, blue = 0.23f, alpha = 1 };
            Gdk.RGBA line = ink;
            line.alpha = 0.08f;
            Gdk.RGBA text = ink;
            text.alpha = 0.75f;
            snap.push_rounded_clip (rounded);
            snap.append_color (bg, rect);
            var head = Graphene.Rect ();
            head.init (0, 0, w, 56);
            snap.append_color (header, head);
            for (int i = 0; i < 9; i++) {
                float y = 88 + i * 34;
                if (y + 18 > h) break;
                var icon = Graphene.Rect ();
                icon.init (20, y, 22, 20);
                snap.append_color (line, icon);
                var bar = Graphene.Rect ();
                bar.init (56, y + 5, (float) (w * (0.22 + ((i * 37) % 30) / 100.0)), 10);
                snap.append_color (line, bar);
            }
            var layout = create_pango_layout ("%s  ·  %s".printf (image_folder == "" ? _("Home") : Path.get_basename (image_folder), item.title ()));
            layout.set_width ((int) ((w - 40) * Pango.SCALE));
            layout.set_ellipsize (Pango.EllipsizeMode.END);
            snap.save ();
            var p = Graphene.Point ();
            p.init (20, 18);
            snap.translate (p);
            snap.append_layout (layout, text);
            snap.restore ();
            snap.pop ();
        }

        private void draw_frame (Snapshot snap, int index, double d) {
            double scale, cx, cy;
            depth_transform (d, out scale, out cx, out cy);
            double alpha = frame_alpha (d) * _intro;
            if (alpha <= 0.01) return;
            float w = card_rect.get_width ();
            float h = card_rect.get_height ();
            snap.save ();
            var p = Graphene.Point ();
            p.init ((float) cx, (float) cy);
            snap.translate (p);
            snap.scale ((float) scale, (float) scale);
            p.init (-w / 2, -h / 2);
            snap.translate (p);
            snap.push_opacity (alpha);
            var rect = Graphene.Rect ();
            rect.init (0, 0, w, h);
            var outline = Gsk.RoundedRect ();
            outline.init_from_rect (rect, 14);
            Gdk.RGBA shadow = { 0, 0, 0, 0.45f };
            snap.append_outset_shadow (outline, shadow, 0, 10, 0, 30);
            if (index == selected) {
                p.init (-card_rect.get_x (), -card_rect.get_y ());
                snap.translate (p);
                snapshot_child (card, snap);
            } else if (items[index].image != null) {
                items[index].image.snapshot (snap, w, h);
            } else {
                draw_generic_frame (snap, items[index], w, h);
            }
            snap.pop ();
            double dim = d > 0 ? double.min (0.55, d * 0.09) : 0;
            if (dim > 0) {
                snap.push_rounded_clip (outline);
                Gdk.RGBA veil = { 0.01f, 0.02f, 0.06f, (float) dim };
                snap.append_color (veil, rect);
                snap.pop ();
            }
            snap.restore ();
        }

        public override void snapshot (Snapshot snap) {
            int width = get_width ();
            int height = get_height ();
            draw_background (snap, width, height);
            if (items.size == 0) return;

            double entry = (1.0 - _intro) * 1.6;
            int far = (int) Math.floor (_position + MAX_DEPTH + entry);
            for (int i = int.min (items.size - 1, far); i >= 0; i--) {
                double d = i - _position + (Singularity.Motion.reduced () ? 0 : entry);
                if (d <= -1 || d > MAX_DEPTH + entry) continue;
                if (i == selected && fade_from != null) continue;
                draw_frame (snap, i, d);
            }
            if (fade_from != null) {
                double scale, cx, cy;
                depth_transform (selected - _position, out scale, out cx, out cy);
                float w = card_rect.get_width ();
                float h = card_rect.get_height ();
                snap.save ();
                var p = Graphene.Point ();
                p.init (card_rect.get_x (), card_rect.get_y ());
                snap.translate (p);
                var base_rect = Graphene.Rect ();
                base_rect.init (0, 0, w, h);
                var base_round = Gsk.RoundedRect ();
                base_round.init_from_rect (base_rect, 14);
                Gdk.RGBA ink = card.get_color ();
                bool light = (ink.red + ink.green + ink.blue) / 3 < 0.5;
                Gdk.RGBA paper = light ? Gdk.RGBA () { red = 0.96f, green = 0.957f, blue = 0.95f, alpha = 1 }
                                       : Gdk.RGBA () { red = 0.13f, green = 0.14f, blue = 0.18f, alpha = 1 };
                snap.push_rounded_clip (base_round);
                snap.append_color (paper, base_rect);
                snap.pop ();
                snap.push_opacity (1 - _fade);
                fade_from.snapshot (snap, w, h);
                snap.pop ();
                snap.restore ();
                snap.push_opacity (_fade);
                snapshot_child (card, snap);
                snap.pop ();
            }

            snap.push_opacity (_intro);
            snapshot_child (timeline, snap);
            snapshot_child (arrows, snap);
            snapshot_child (bar, snap);
            snap.pop ();
            if (quick_look.visible) snapshot_child (quick_look, snap);
        }

        private async void preview (EntryItem e) {
            var item = items[selected];
            string snapshot_id = e.origin != "" ? e.origin : item.id;
            string file;
            try {
                if (item.live && e.change != "removed") file = Path.build_filename (Environment.get_home_dir (), e.path);
                else file = yield app.daemon.get_file (snapshot_id, e.path);
            } catch (Error err) {
                toast (new Toast (error_text (err)));
                return;
            }
            bool shown = false;
            try {
                var bus = yield Bus.get (BusType.SESSION);
                var owner = yield bus.call ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
                    new Variant ("(s)", "dev.sinty.desktop"), new VariantType ("(b)"), DBusCallFlags.NONE, 1000, null);
                bool has_shell;
                owner.get ("(b)", out has_shell);
                if (!has_shell) throw new IOError.NOT_FOUND ("no shell");
                yield bus.call ("dev.sinty.desktop", "/dev/sinty/shell/Preview", "dev.sinty.shell.Preview", "ShowPreviews",
                    new Variant ("(^asis)", new string[] { File.new_for_path (file).get_uri () }, 0, "dev.sinty.backups"),
                    null, DBusCallFlags.NO_AUTO_START, 3000, null);
                shown = true;
            } catch (Error err) {
                shown = false;
            }
            if (!shown) quick_look.show_file (e, file, item.live && e.change != "removed" ? "" : item.title (), !item.live || e.change == "removed");
        }

        private string snapshot_for (EntryItem e) {
            if (e.origin != "" && (e.change == "removed" || items[selected].live)) return e.origin;
            return items[selected].id;
        }

        private async void restore (string target, ConflictPolicy fallback) {
            var sel = card.selected_items ();
            if (sel.size == 0 && card.folder != "") {
                var here = new EntryItem ();
                here.path = card.folder;
                here.name = Path.get_basename (card.folder);
                here.kind = "directory";
                here.origin = items[selected].id;
                sel.add (here);
            }
            if (items[selected].live) {
                var only_removed = new Gee.ArrayList<EntryItem> ();
                foreach (var e in sel) if (e.change == "removed") only_removed.add (e);
                sel = only_removed;
            }
            if (sel.size == 0) return;
            yield restore_items (sel, target);
        }

        private async void restore_items (Gee.List<EntryItem> sel, string target) {
            var groups = new HashTable<string, Gee.ArrayList<string>> (str_hash, str_equal);
            foreach (var e in sel) {
                string id = snapshot_for (e);
                if (id == "") continue;
                var g = groups[id];
                if (g == null) {
                    g = new Gee.ArrayList<string> ();
                    groups[id] = g;
                }
                g.add (e.path);
            }
            string[] conflicts = {};
            foreach (var id in groups.get_keys ()) {
                try {
                    foreach (string c in yield app.daemon.check_restore (id, groups[id].to_array (), target)) conflicts += c;
                } catch (Error err) {
                    toast (new Toast (error_text (err)));
                    return;
                }
            }
            string policy = "keep-both";
            if (conflicts.length > 0) {
                var choice = yield ask_conflict (conflicts);
                if (choice == null) return;
                policy = choice;
            }
            string[] done = {};
            try {
                foreach (var id in groups.get_keys ()) {
                    foreach (string p in yield app.daemon.restore (id, groups[id].to_array (), target, policy)) done += p;
                }
            } catch (Error err) {
                toast (new Toast (error_text (err)));
                return;
            }
            if (done.length == 0) return;
            string first = done[0];
            var t = new Toast (done.length == 1 ? _("Restored “%s”").printf (Path.get_basename (first))
                                                : ngettext ("Restored %d item", "Restored %d items", done.length).printf (done.length));
            t.button_label = _("Show in Files");
            t.button_clicked.connect (() => show_in_files (first));
            leave ();
            window.add_toast (t);
        }

        private void show_in_files (string path) {
            Bus.get.begin (BusType.SESSION, null, (o, r) => {
                try {
                    var bus = Bus.get.end (r);
                    bus.call.begin ("org.freedesktop.FileManager1", "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1",
                        "ShowItems", new Variant ("(^ass)", new string[] { File.new_for_path (path).get_uri () }, ""),
                        null, DBusCallFlags.NONE, 5000, null);
                } catch (Error e) {
                    warning ("Backups: %s", e.message);
                }
            });
        }

        private async string? ask_conflict (string[] conflicts) {
            string title = conflicts.length == 1 ? _("“%s” Already Exists").printf (Path.get_basename (conflicts[0]))
                                                 : ngettext ("%d Item Already Exists", "%d Items Already Exist", conflicts.length).printf (conflicts.length);
            var dialog = new ConfirmDialog (app, title, "dev.sinty.backups",
                _("Keep both, and the restored copy gets “restored” in its name, or replace the current version. A replaced version goes to the Trash."),
                _("Keep Both"), ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.set_secondary (_("Replace"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dialog.transient_for = window;
            dialog.modal = true;
            string? result = null;
            dialog.response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) result = "keep-both";
                else if (r == ConfirmDialog.Response.SECONDARY) result = "replace";
                Idle.add (ask_conflict.callback);
            });
            dialog.present ();
            yield;
            return result;
        }

        private async void restore_to_folder () {
            var dialog = new FileDialog ();
            dialog.title = _("Restore To");
            dialog.accept_label = _("Restore Here");
            try {
                var folder = yield dialog.select_folder (window, null);
                yield restore (folder.get_path (), ConflictPolicy.KEEP_BOTH);
            } catch (Error e) {
            }
        }

        private void confirm_restore_all () {
            var item = items[selected];
            if (item.live) return;
            var dialog = new ConfirmDialog (app, _("Restore Everything?"), "dev.sinty.backups",
                _("Every file in your home folder is put back as it was on %s. Files you created later are kept.").printf (item.title ()),
                _("Restore Everything"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dialog.transient_for = window;
            dialog.modal = true;
            var apps = new CheckButton.with_label (_("Also reinstall the apps from this backup"));
            apps.active = "flatpak" in item.providers;
            apps.visible = "flatpak" in item.providers;
            dialog.custom_area.append (apps);
            var system = new CheckButton.with_label (_("Also restore the system configuration"));
            system.active = false;
            system.visible = "abroot" in item.providers;
            dialog.custom_area.append (system);
            dialog.response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                string[] providers = { "userdata" };
                if (apps.active && apps.visible) providers += "flatpak";
                if (system.active && system.visible) providers += "abroot";
                run_restore_all.begin (item.id, providers);
            });
            dialog.present ();
        }

        private async void run_restore_all (string id, string[] providers) {
            try {
                yield app.daemon.restore_all (id, providers);
                leave ();
                window.add_toast (new Toast (_("Everything was restored")));
            } catch (Error e) {
                toast (new Toast (error_text (e)));
            }
        }
    }
}
