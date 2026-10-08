"""A small, persistent-on-hover PipeWire/PulseAudio mixer above Waybar."""
import json
from pathlib import Path
import subprocess
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GtkLayerShell", "0.1")
from gi.repository import Gdk, Gio, GLib, Gtk, GtkLayerShell, Pango
import pulsectl
from volume_memory import remember_volume

HERE = Path(__file__).resolve().parent


def label(text, css=None):
    widget = Gtk.Label(label=text, xalign=0)
    widget.set_ellipsize(Pango.EllipsizeMode.END)
    if css:
        widget.get_style_context().add_class(css)
    return widget


def button(icon, tooltip, callback):
    widget = Gtk.Button()
    widget.set_image(Gtk.Image.new_from_icon_name(icon, Gtk.IconSize.BUTTON))
    widget.get_accessible().set_name(tooltip)
    widget.set_focus_on_click(False)
    widget.get_style_context().add_class("close")
    widget.connect("clicked", callback)
    return widget


class Mixer(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="local.desktop.AudioPopup", flags=Gio.ApplicationFlags.FLAGS_NONE)
        self.window = None
        self.dismiss_windows = []
        self.pulse = None
        self.rows = {}
        self.updating = False
        self.app_icons = {}
        self.desktop_apps = {}
        for app in Gio.AppInfo.get_all():
            for identity in (app.get_id(), app.get_name(), app.get_executable()):
                if identity:
                    self.desktop_apps[Path(identity).name.removesuffix(".desktop").casefold()] = app
        self.connect("activate", self.activate)

    def activate(self, *_):
        # A second click on Waybar closes the existing instance via D-Bus.
        if self.window:
            self.quit()
            return
        self.window = Gtk.ApplicationWindow(application=self)
        self.window.set_name("audio-popup")
        self.window.set_title("Sound")
        self.window.set_resizable(False)
        GtkLayerShell.init_for_window(self.window)
        GtkLayerShell.set_namespace(self.window, "audio-popup")
        GtkLayerShell.set_layer(self.window, GtkLayerShell.Layer.OVERLAY)
        self.configure_fullscreen_layer(self.window)
        # Use the monitor under the clicked icon, including scaled displays.
        display = Gdk.Display.get_default()
        selected_monitor = display.get_monitor(0)
        try:
            monitor = json.loads(subprocess.check_output(
                ["hyprctl", "monitors", "-j"], timeout=2))
            active = next(m for m in monitor if m.get("focused"))
            for index in range(display.get_n_monitors()):
                candidate = display.get_monitor(index)
                geometry = candidate.get_geometry()
                if (geometry.x, geometry.y) == (active["x"], active["y"]):
                    selected_monitor = candidate
                    break
        except (OSError, subprocess.SubprocessError, ValueError, StopIteration):
            pass
        GtkLayerShell.set_monitor(self.window, selected_monitor)
        self.window.connect("key-press-event", self.on_key)
        self.window.connect("destroy", lambda *_: self.quit())
        provider = Gtk.CssProvider()
        provider.load_from_path(str(HERE / "style.css"))
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_USER + 1)
        overlay = Gtk.Overlay()
        self.window.add(overlay)
        backdrop = self.dismiss_area()
        overlay.add(backdrop)
        self.card_surface = Gtk.EventBox()
        self.card_surface.set_name("audio-card-surface")
        self.card_surface.set_halign(Gtk.Align.END)
        self.card_surface.set_valign(Gtk.Align.END)
        self.card_surface.set_margin_end(5)
        self.card_surface.set_margin_bottom(50)
        # An input window over the card keeps clicks on its padding from reaching
        # the full-monitor dismiss surface below it.
        self.card_surface.connect("button-press-event", lambda *_: True)
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        card.set_name("audio-card")
        card.set_size_request(360, -1)
        self.card_surface.add(card)
        overlay.add_overlay(self.card_surface)
        header = Gtk.Box(spacing=8)
        header.pack_start(label("Sound", "title"), True, True, 0)
        header.pack_end(button("window-close-symbolic", "Close", lambda *_: self.quit()), False, False, 0)
        card.pack_start(header, False, False, 0)
        self.status = label("", "muted")
        card.pack_start(self.status, False, False, 0)
        self.status.set_no_show_all(True)
        self.master = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        card.pack_start(self.master, False, False, 0)
        scroll = Gtk.ScrolledWindow()
        self.scroll = scroll
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_propagate_natural_height(True)
        scroll.set_max_content_height(360)
        self.content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        scroll.add(self.content)
        card.pack_start(scroll, True, True, 0)
        self.refresh()
        for index in range(display.get_n_monitors()):
            monitor = display.get_monitor(index)
            if monitor == selected_monitor:
                continue
            dismiss = Gtk.ApplicationWindow(application=self)
            dismiss.set_name("audio-dismiss")
            GtkLayerShell.init_for_window(dismiss)
            GtkLayerShell.set_namespace(dismiss, "audio-popup-dismiss")
            GtkLayerShell.set_layer(dismiss, GtkLayerShell.Layer.OVERLAY)
            GtkLayerShell.set_monitor(dismiss, monitor)
            self.configure_fullscreen_layer(dismiss)
            dismiss.add(self.dismiss_area())
            dismiss.connect("key-press-event", self.on_key)
            dismiss.show_all()
            self.dismiss_windows.append(dismiss)
        self.window.show_all()
        GLib.timeout_add_seconds(1, self.refresh)

    def configure_fullscreen_layer(self, window):
        # GDK drops out-of-window pointer events. Give outside clicks a real,
        # transparent input surface, while the visible card keeps its own size.
        for edge in (GtkLayerShell.Edge.TOP, GtkLayerShell.Edge.BOTTOM,
                     GtkLayerShell.Edge.LEFT, GtkLayerShell.Edge.RIGHT):
            GtkLayerShell.set_anchor(window, edge, True)
        GtkLayerShell.set_exclusive_zone(window, -1)
        GtkLayerShell.set_keyboard_mode(window, GtkLayerShell.KeyboardMode.EXCLUSIVE)

    def dismiss_area(self):
        area = Gtk.EventBox()
        area.set_name("audio-dismiss-area")
        area.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
        area.connect("button-press-event", lambda *_: self.quit() or True)
        return area

    def on_key(self, _window, event):
        if event.keyval == Gdk.KEY_Escape:
            self.quit()
            return True
        return False

    def scroll_list(self, _widget, event):
        # Wheel gestures scroll the list, never adjust volume or select a device.
        adjustment = self.scroll.get_vadjustment()
        if event.direction == Gdk.ScrollDirection.SMOOTH:
            delta = event.delta_y
        else:
            delta = {Gdk.ScrollDirection.UP: -1, Gdk.ScrollDirection.DOWN: 1}.get(event.direction, 0)
        step = max(24, adjustment.get_step_increment())
        adjustment.set_value(adjustment.get_value() + delta * step)
        return True

    def item_icon(self, item, kind):
        if kind == "sink":
            return Gio.ThemedIcon.new("audio-volume-high-symbolic")
        props = item.proplist
        identities = tuple(props.get(key, "") for key in (
            "application.icon_name", "media.icon_name", "application.id",
            "application.process.binary", "application.name", "device.icon_name"))
        cache_key = (kind, identities)
        if cache_key in self.app_icons:
            return self.app_icons[cache_key]
        icon = None
        theme = Gtk.IconTheme.get_default()
        for name in (identities[0], identities[1], identities[5]):
            if name and theme.has_icon(name):
                icon = Gio.ThemedIcon.new(name)
                break
        if icon is None:
            for identity in identities[2:5]:
                app = self.desktop_apps.get(Path(identity).name.removesuffix(".desktop").casefold())
                if app and app.get_icon():
                    icon = app.get_icon()
                    break
        if icon is None:
            name = {
                "sink": "audio-volume-high-symbolic",
                "sink_input": "multimedia-player-symbolic",
            }[kind]
            icon = Gio.ThemedIcon.new(name)
        self.app_icons[cache_key] = icon
        return icon

    def action(self, function, *args):
        if self.updating:
            return False
        try:
            function(*args)
            self.status.hide()
            return True
        except pulsectl.PulseError:
            self.status.set_text("Device changed. Try again.")
            self.status.show()
            return False

    def row(self, key, title, item, kind):
        # A reconnect/default-output switch must not transfer an in-progress
        # slider gesture to a different device with a stale volume.
        if key in self.rows and kind == "sink":
            old = self.rows[key]["item"]
            if (old.index, old.name) != (item.index, item.name):
                self.rows.pop(key)["box"].destroy()
        if key not in self.rows:
            box = Gtk.Box(spacing=10)
            box.get_style_context().add_class("audio-row")
            if kind == "sink":
                box.get_style_context().add_class("master-row")
            icon = Gtk.Image()
            icon.set_pixel_size(22)
            box.pack_start(icon, False, False, 0)
            controls = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            top = Gtk.Box(spacing=8)
            name = label(title)
            value = label("", "muted")
            value.set_xalign(1)
            value.set_width_chars(5)
            top.pack_start(name, True, True, 0)
            top.pack_end(value, False, False, 0)
            controls.pack_start(top, False, False, 0)
            scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 1)
            scale.connect("scroll-event", self.scroll_list)
            scale.set_draw_value(False)
            scale.set_hexpand(True)
            scale.get_accessible().set_name(title + " volume")
            controls.pack_start(scale, False, False, 0)
            box.pack_start(controls, True, True, 0)
            state = dict(box=box, name=name, icon=icon, scale=scale, value=value,
                         item=item, dragging=False)
            self.rows[key] = state
            scale.connect("button-press-event", lambda *_: state.update(dragging=True) or False)
            scale.connect("button-release-event", lambda *_: state.update(dragging=False) or False)

            def volume_changed(w):
                if not self.updating:
                    state["value"].set_text(f"{w.get_value():.0f}%")
                    changed = self.action(self.pulse.volume_set_all_chans, state["item"], w.get_value() / 100)
                    if changed and kind == "sink_input":
                        remember_volume(state["item"], w.get_value() / 100)
                    if state["item"].mute and w.get_value() > 0:
                        self.action(self.pulse.mute, state["item"], False)

            scale.connect("value-changed", volume_changed)
            (self.master if kind == "sink" else self.content).pack_start(box, False, False, 0)
        state = self.rows[key]
        state["item"] = item
        state["name"].set_text(title)
        state["icon"].set_from_gicon(self.item_icon(item, kind), Gtk.IconSize.LARGE_TOOLBAR)
        if not state["dragging"]:
            state["scale"].set_value(item.volume.value_flat * 100)
            state["value"].set_text("Muted" if item.mute else f"{item.volume.value_flat * 100:.0f}%")
        return state["box"]

    def refresh(self):
        self.updating = True
        try:
            if self.pulse is None:
                self.pulse = pulsectl.Pulse("desktop-audio-popup")
            server = self.pulse.server_info()
            sinks = self.pulse.sink_list()
            entries = []
            master = next((d for d in sinks if d.name == server.default_sink_name), next(iter(sinks), None))
            if master:
                entries.append(("sink", "Main volume", master, "sink"))
            for item in self.pulse.sink_input_list():
                title = item.proplist.get("application.name", item.name)
                entries.append((f"sink_input:{item.index}", title, item, "sink_input"))
            active = {e[0] for e in entries}
            for key in list(self.rows):
                if key not in active:
                    self.rows.pop(key)["box"].destroy()
            for position, entry in enumerate(entries):
                widget = self.row(*entry)
                widget.get_parent().reorder_child(widget, position)
            self.master.show_all()
            self.master.set_sensitive(True)
            self.content.show_all()
            self.content.set_sensitive(True)
            if not entries:
                self.status.set_text("No audio output connected")
                self.status.show()
            else:
                self.status.hide()
        except pulsectl.PulseError:
            if self.pulse:
                self.pulse.close()
                self.pulse = None
            # Drop controls tied to the old server's stream/device indices.
            # A fresh connection gets fresh widgets and fresh server values.
            for state in self.rows.values():
                state["box"].destroy()
            self.rows.clear()
            self.master.set_sensitive(False)
            self.content.set_sensitive(False)
            self.status.set_text("Waiting for audio…")
            self.status.show()
        finally:
            self.updating = False
        return True

    def do_shutdown(self):
        if self.pulse:
            self.pulse.close()
        Gtk.Application.do_shutdown(self)


if __name__ == "__main__":
    Mixer().run(sys.argv)
