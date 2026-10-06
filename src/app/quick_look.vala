using Gtk;

namespace Singularity.Backups {

    public class QuickLook : Widget {
        private const int64 TEXT_LIMIT = 128 * 1024;

        public signal void restore_requested (EntryItem item);

        private Singularity.Animation.MotionBin motion;
        private Image icon;
        private Label title;
        private Label subtitle;
        private Stack stage;
        private Picture picture;
        private TextView text;
        private Image big_icon;
        private Label facts;
        private Button restore_button;
        private EntryItem? current = null;

        public QuickLook () {
            Object ();
        }

        protected override void dispose () {
            if (motion != null) motion.unparent ();
            base.dispose ();
        }

        public override void measure (Orientation orientation, int for_size, out int minimum, out int natural,
                                      out int minimum_baseline, out int natural_baseline) {
            minimum = 0;
            natural = 0;
            minimum_baseline = -1;
            natural_baseline = -1;
        }

        construct {
            add_css_class ("tt-quicklook");
            hexpand = true;
            vexpand = true;
            var click = new GestureClick ();
            click.pressed.connect ((n, x, y) => {
                Graphene.Rect bounds;
                if (motion.compute_bounds (this, out bounds) && !bounds.contains_point ({ (float) x, (float) y })) close ();
            });
            add_controller (click);

            var card = new Box (Orientation.VERTICAL, 0);
            card.add_css_class ("tt-quicklook-card");
            var header = new Box (Orientation.HORIZONTAL, 12);
            header.add_css_class ("tt-card-header");
            icon = new Image ();
            icon.pixel_size = 32;
            header.append (icon);
            var titles = new Box (Orientation.VERTICAL, 0);
            titles.hexpand = true;
            title = new Label ("");
            title.add_css_class ("heading");
            title.xalign = 0;
            title.ellipsize = Pango.EllipsizeMode.MIDDLE;
            titles.append (title);
            subtitle = new Label ("");
            subtitle.add_css_class ("caption");
            subtitle.add_css_class ("dim-label");
            subtitle.xalign = 0;
            titles.append (subtitle);
            header.append (titles);
            card.append (header);

            stage = new Stack ();
            stage.vexpand = true;
            stage.hexpand = true;
            picture = new Picture ();
            picture.content_fit = ContentFit.CONTAIN;
            picture.can_shrink = true;
            stage.add_named (picture, "image");
            text = new TextView ();
            text.editable = false;
            text.cursor_visible = false;
            text.monospace = true;
            text.wrap_mode = WrapMode.WORD_CHAR;
            text.left_margin = 16;
            text.right_margin = 16;
            text.top_margin = 12;
            text.bottom_margin = 12;
            var text_scroll = new ScrolledWindow ();
            text_scroll.child = text;
            stage.add_named (text_scroll, "text");
            var other = new Box (Orientation.VERTICAL, 12);
            other.valign = Align.CENTER;
            big_icon = new Image ();
            big_icon.pixel_size = 128;
            other.append (big_icon);
            facts = new Label ("");
            facts.add_css_class ("dim-label");
            facts.justify = Justification.CENTER;
            other.append (facts);
            stage.add_named (other, "other");
            card.append (stage);

            var buttons = new Box (Orientation.HORIZONTAL, 12);
            buttons.halign = Align.END;
            buttons.add_css_class ("tt-quicklook-actions");
            var close_button = new Button.with_label (_("Close"));
            close_button.add_css_class ("pill");
            close_button.clicked.connect (() => close ());
            buttons.append (close_button);
            restore_button = new Button.with_label (_("Restore"));
            restore_button.add_css_class ("pill");
            restore_button.add_css_class ("suggested-action");
            restore_button.clicked.connect (() => {
                if (current != null) restore_requested (current);
            });
            buttons.append (restore_button);
            card.append (buttons);

            motion = new Singularity.Animation.MotionBin (card);
            motion.set_parent (this);
        }

        public override void size_allocate (int width, int height, int baseline) {
            int w = (int) double.min (820, width * 0.62);
            int h = (int) double.min (620, height * 0.74);
            motion.allocate_size (Allocation () { x = (width - w) / 2, y = (height - h) / 2, width = w, height = h }, -1);
        }

        public void show_file (EntryItem entry, string path, string when, bool restorable) {
            current = entry;
            icon.gicon = entry.icon ();
            title.label = entry.name;
            string size = entry.size_text ();
            if (size == "") size = _("Folder");
            string line = size;
            if (when != "") line = _("%s, from the backup of %s").printf (size, when);
            subtitle.label = line;
            restore_button.visible = restorable;
            string type = entry.content_type;
            if (ContentType.is_a (type, "image/*") && !entry.is_dir) {
                try {
                    picture.paintable = Gdk.Texture.from_filename (path);
                    stage.visible_child_name = "image";
                } catch (Error e) {
                    show_other (entry);
                }
            } else if (ContentType.is_a (type, "text/plain") && !entry.is_dir) {
                try {
                    uint8[] data;
                    var f = File.new_for_path (path);
                    var stream = f.read ();
                    data = new uint8[TEXT_LIMIT + 1];
                    size_t n;
                    stream.read_all (data[0:TEXT_LIMIT], out n);
                    string s = ((string) data).make_valid ((ssize_t) n);
                    text.buffer.text = s;
                    stage.visible_child_name = "text";
                } catch (Error e) {
                    show_other (entry);
                }
            } else {
                show_other (entry);
            }
            visible = true;
            Singularity.Motion.reveal (motion, Singularity.Motion.Preset.SCALE_FADE);
            restore_button.grab_focus ();
        }

        private void show_other (EntryItem entry) {
            big_icon.gicon = entry.icon ();
            string kind = ContentType.get_description (entry.content_type);
            string when = entry.modified_text ();
            facts.label = "%s\n%s".printf (kind, when != "" ? _("Modified %s").printf (when) : "");
            stage.visible_child_name = "other";
        }

        public void close () {
            if (!visible) return;
            var anim = Singularity.Motion.conceal (motion, Singularity.Motion.Preset.FADE);
            anim.done.connect (() => visible = false);
        }
    }
}
