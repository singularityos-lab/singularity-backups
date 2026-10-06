using Gtk;

namespace Singularity.Backups {

    public class Timeline : Widget {
        private const int WIDTH = 148;
        private const double LINE_INSET = 30;
        private const double MAX_SPACING = 56;
        private const double MIN_SPACING = 3;
        private const double MARGIN = 28;

        private Gee.List<SnapshotItem> items = new Gee.ArrayList<SnapshotItem> ();
        private int _selected = 0;
        private double _position = 0;
        private double hover_y = -1;
        private Gdk.RGBA accent;

        public signal void activated (int index);

        public int selected {
            get { return _selected; }
            set {
                _selected = value;
                queue_draw ();
                update_property (Gtk.AccessibleProperty.VALUE_TEXT, items.size > value && value >= 0 ? items[value].title () : "", -1);
            }
        }

        public double position {
            get { return _position; }
            set {
                _position = value;
                queue_draw ();
            }
        }

        public Timeline () {
            Object (accessible_role: AccessibleRole.SLIDER);
        }

        construct {
            add_css_class ("tt-timeline");
            focusable = true;
            tooltip_text = _("Choose a backup");
            accent = { 0.36f, 0.62f, 1.0f, 1.0f };
            var motion = new EventControllerMotion ();
            motion.motion.connect ((x, y) => {
                hover_y = y;
                queue_draw ();
            });
            motion.leave.connect (() => {
                hover_y = -1;
                queue_draw ();
            });
            add_controller (motion);
            var click = new GestureClick ();
            click.pressed.connect ((n, x, y) => {
                int i = index_at (y);
                if (i >= 0) activated (i);
            });
            add_controller (click);
            var drag = new GestureDrag ();
            drag.drag_update.connect ((dx, dy) => {
                double sx, sy;
                drag.get_start_point (out sx, out sy);
                hover_y = sy + dy;
                int i = index_at (hover_y);
                if (i >= 0 && i != _selected) activated (i);
            });
            add_controller (drag);
            var keys = new EventControllerKey ();
            keys.key_pressed.connect ((keyval, code, state) => {
                if (keyval == Gdk.Key.Up) {
                    if (_selected + 1 < items.size) activated (_selected + 1);
                    return true;
                }
                if (keyval == Gdk.Key.Down) {
                    if (_selected > 0) activated (_selected - 1);
                    return true;
                }
                return false;
            });
            add_controller (keys);
        }

        public void set_items (Gee.List<SnapshotItem> list) {
            items = list;
            queue_draw ();
        }

        public void set_accent (Gdk.RGBA color) {
            accent = color;
            queue_draw ();
        }

        public override SizeRequestMode get_request_mode () {
            return SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure (Orientation orientation, int for_size, out int minimum, out int natural,
                                      out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = -1;
            natural_baseline = -1;
            if (orientation == Orientation.HORIZONTAL) {
                minimum = WIDTH;
                natural = WIDTH;
            } else {
                minimum = 120;
                natural = 400;
            }
        }

        private double spacing () {
            double h = get_height () - 2 * MARGIN;
            if (items.size <= 1) return MAX_SPACING;
            return (h / (items.size - 1)).clamp (MIN_SPACING, MAX_SPACING);
        }

        private double y_for (double index) {
            return get_height () - MARGIN - index * spacing ();
        }

        private int index_at (double y) {
            if (items.size == 0) return -1;
            double i = (get_height () - MARGIN - y) / spacing ();
            return (int) Math.round (i).clamp (0, items.size - 1);
        }

        private void label_at (Snapshot snap, string text, double right, double y, Gdk.RGBA color, bool bold) {
            var layout = create_pango_layout (text);
            var desc = get_pango_context ().get_font_description ().copy ();
            if (bold) desc.set_weight (Pango.Weight.BOLD);
            desc.set_size ((int) (desc.get_size () * (bold ? 0.95 : 0.85)));
            layout.set_font_description (desc);
            int w, h;
            layout.get_pixel_size (out w, out h);
            snap.save ();
            var point = Graphene.Point ();
            point.init ((float) (right - w), (float) (y - h / 2.0));
            snap.translate (point);
            snap.append_layout (layout, color);
            snap.restore ();
        }

        public override void snapshot (Snapshot snap) {
            if (items.size == 0) return;
            double w = get_width ();
            double line_x = w - LINE_INSET;
            Gdk.RGBA faint = { 1, 1, 1, 0.22f };
            Gdk.RGBA tick = { 1, 1, 1, 0.55f };
            Gdk.RGBA text = { 1, 1, 1, 0.92f };
            Gdk.RGBA dim_text = { 1, 1, 1, 0.6f };

            var rail = Graphene.Rect ();
            rail.init ((float) line_x - 1, (float) (y_for (items.size - 1) - 6), 2, (float) (y_for (0) - y_for (items.size - 1) + 12));
            snap.append_color (faint, rail);

            double sp = spacing ();
            int hover_index = hover_y >= 0 ? index_at (hover_y) : -1;
            for (int i = 0; i < items.size; i++) {
                double y = y_for (i);
                double magnify = hover_y >= 0 ? Math.exp (-Math.pow ((y - hover_y) / 42.0, 2)) : 0;
                double len = 8 + 16 * magnify;
                if (i == 0) len = double.max (len, 14);
                double thickness = sp < 6 ? 1.5 : 2;
                var r = Graphene.Rect ();
                r.init ((float) (line_x - len), (float) (y - thickness / 2), (float) len, (float) thickness);
                Gdk.RGBA c = tick;
                c.alpha = (float) (0.45 + 0.5 * magnify);
                snap.append_color (c, r);
                if (items[i].has_version) {
                    var dot = Graphene.Rect ();
                    dot.init ((float) (line_x + 6), (float) (y - 3), 6, 6);
                    var rounded = Gsk.RoundedRect ();
                    rounded.init_from_rect (dot, 3);
                    snap.push_rounded_clip (rounded);
                    snap.append_color (accent, dot);
                    snap.pop ();
                }
            }

            double py = y_for (_position);
            var marker = Graphene.Rect ();
            marker.init ((float) (line_x - 30), (float) (py - 2), 36, 4);
            var marker_round = Gsk.RoundedRect ();
            marker_round.init_from_rect (marker, 2);
            snap.push_rounded_clip (marker_round);
            snap.append_color (accent, marker);
            snap.pop ();

            if (_selected >= 0 && _selected < items.size) {
                label_at (snap, items[_selected].short_title (), line_x - 38, y_for (_selected), text, true);
            }
            if (hover_index >= 0 && hover_index != _selected) {
                label_at (snap, items[hover_index].title (), line_x - 30, y_for (hover_index), text, false);
            }
            if (_selected != 0 && hover_index != 0) label_at (snap, _("Now"), line_x - 24, y_for (0), dim_text, false);
            int last = items.size - 1;
            if (last > 0 && _selected != last && hover_index != last && Math.fabs (y_for (last) - y_for (_selected)) > 20) {
                label_at (snap, items[last].short_title (), line_x - 24, y_for (last), dim_text, false);
            }
        }
    }
}
