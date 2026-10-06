namespace Singularity.Backups {

    public class Style : Object {
        public static void install () {
            var provider = new Gtk.CssProvider ();
            provider.load_from_string (CSS);
            Gtk.StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider,
                                                      Gtk.STYLE_PROVIDER_PRIORITY_USER + 2);
        }

        private const string CSS = """
.singularity-app:not(.ssd-mode) .backups-pages > .backups-page {
    padding-top: 44px;
}

.backups-hero {
    padding: 8px 4px 4px 4px;
}

.backups-ring-error {
    color: @error_color;
}

.backups-ring-idle {
    opacity: 0.55;
}

.backups-usage {
    padding: 12px 16px;
}

.backups-usage levelbar block.filled {
    background: @accent_bg_color;
}

.time-travel {
    background: #04060f;
}

.time-travel-mode .toolbar,
.time-travel-mode headerbar {
    background: transparent;
}

.tt-card {
    background: @window_bg;
    color: @text_color;
    border-radius: 14px;
}

.tt-card-header {
    padding: 10px 14px;
    border-bottom: 1px solid alpha(@text_color, 0.08);
}

.tt-columns {
    padding: 6px 26px 6px 50px;
    font-size: 0.85em;
    opacity: 0.6;
    border-bottom: 1px solid alpha(@text_color, 0.06);
}

.tt-list {
    background: transparent;
}

.tt-row {
    padding: 5px 12px;
    min-height: 30px;
}

.tt-row-removed {
    opacity: 0.55;
}

.tt-row-removed label:nth-child(2) {
    font-style: italic;
}

.tt-change {
    font-size: 0.8em;
    font-weight: bold;
    padding: 1px 8px;
    border-radius: 999px;
}

.tt-change-added {
    color: #1f9d55;
    background: alpha(#2ec27e, 0.16);
}

.tt-change-changed {
    color: #c77c02;
    background: alpha(#f5a623, 0.18);
}

.tt-change-removed {
    color: #d33;
    background: alpha(#e01b24, 0.14);
}

.tt-change-contains {
    min-width: 8px;
    min-height: 8px;
    padding: 0;
    background: alpha(@accent_bg_color, 0.85);
}

.tt-bar {
    padding: 8px;
    border-radius: 999px;
    background: alpha(#0b1020, 0.72);
    border: 1px solid alpha(white, 0.08);
}

.time-travel .tt-bar button:not(.suggested-action),
.time-travel .tt-bar menubutton > button {
    color: white;
    background: alpha(white, 0.14);
    border: 1px solid alpha(white, 0.12);
    box-shadow: none;
}

.time-travel .tt-bar button:not(.suggested-action) label,
.time-travel .tt-bar button:not(.suggested-action) image,
.time-travel .tt-arrow image {
    color: white;
}

.time-travel .tt-bar button:disabled {
    opacity: 0.45;
}

.time-travel .tt-bar button.suggested-action:disabled {
    color: alpha(white, 0.7);
    background: alpha(@accent_bg_color, 0.45);
}

.tt-date {
    color: white;
    font-weight: bold;
}

.time-travel .tt-arrow {
    min-width: 40px;
    min-height: 40px;
    border-radius: 999px;
    color: white;
    background: alpha(white, 0.12);
    border: 1px solid alpha(white, 0.1);
}

.time-travel .tt-arrow:hover {
    background: alpha(white, 0.2);
}

.tt-quicklook {
    background: alpha(black, 0.55);
}

.tt-quicklook-card {
    background: @window_bg;
    color: @text_color;
    border-radius: 16px;
    box-shadow: 0 20px 60px alpha(black, 0.5);
}

.tt-quicklook-actions {
    padding: 12px 16px;
    border-top: 1px solid alpha(@text_color, 0.08);
}
""";
    }
}
