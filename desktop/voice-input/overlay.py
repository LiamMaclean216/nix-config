"""Presentation-only animations; never delay dictation or clipboard delivery."""

import math
import time
from dataclasses import dataclass
from difflib import SequenceMatcher

import cairo
import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GtkLayerShell", "0.1")
from gi.repository import Gdk, GLib, Gtk, GtkLayerShell, Pango  # noqa: E402


def ease(value):
    value = max(0.0, min(1.0, value))
    return value * value * (3 - 2 * value)


@dataclass
class Letter:
    appeared: float
    confirmed: float | None = None


class AnimatedTranscript(Gtk.Label):
    """Preserve letter animations through provisional edits and finalization."""

    def __init__(self):
        super().__init__(xalign=0)
        self.set_name("dictation-text")
        self.set_line_wrap(True)
        self.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
        self.set_width_chars(52)
        self.set_max_width_chars(52)
        self.text = ""
        self.letters = []
        self.tick = None
        self.connect("unmap", self.stop_animation)

    def stop_animation(self, *_):
        if self.tick is not None:
            self.remove_tick_callback(self.tick)
            self.tick = None

    def placeholder(self, text):
        self.stop_animation()
        self.text = ""
        self.letters = []
        self.set_attributes(None)
        self.set_text(text)

    def update_transcript(self, final, partial):
        raw = final + partial
        if not raw:
            self.placeholder("")
            return
        cut = max(0, len(raw) - 420)
        text = ("…" if cut else "") + raw[cut:]
        confirmed_length = max(0, len(final) - cut) + bool(cut)
        now = time.monotonic()
        letters = [None] * len(text)
        for match in SequenceMatcher(
            None, self.text, text, autojunk=False
        ).get_matching_blocks():
            for offset in range(match.size):
                letters[match.b + offset] = self.letters[match.a + offset]
        new_count = letters.count(None)
        stagger = min(0.014, 0.22 / max(1, new_count - 1))
        start = max(
            now,
            min(
                now + 0.06,
                max((letter.appeared for letter in self.letters), default=now),
            ),
        )
        order = 0
        for index, letter in enumerate(letters):
            if letter is None:
                # New letters that are already final use the normal text color.
                letter = Letter(
                    start + order * stagger,
                    now - 0.3 if index < confirmed_length else None,
                )
                letters[index] = letter
                order += 1
            elif index < confirmed_length and letter.confirmed is None:
                letter.confirmed = now
            elif index >= confirmed_length:
                letter.confirmed = None
        self.text, self.letters = text, letters
        self.set_text(text)
        self.paint_letters(now)
        if self.tick is None:
            self.tick = self.add_tick_callback(self.animate)

    def paint_letters(self, now):
        attrs = Pango.AttrList()
        position = 0
        moving = False
        for char, letter in zip(self.text, self.letters, strict=True):
            reveal = ease((now - letter.appeared) / 0.22)
            confidence = (
                ease((now - letter.confirmed) / 0.3)
                if letter.confirmed is not None
                else 0
            )
            moving |= reveal < 1 or (letter.confirmed is not None and confidence < 1)
            # Muted slate for provisional words; warm white once confirmed.
            color = [
                round((dark + (light - dark) * confidence) * 257)
                for dark, light in zip((108, 114, 129), (239, 241, 247), strict=True)
            ]
            end = position + len(char.encode("utf-8"))
            for attr in (
                Pango.attr_foreground_new(*color),
                Pango.attr_foreground_alpha_new(max(1, round(reveal * 65535))),
            ):
                attr.start_index, attr.end_index = position, end
                attrs.insert(attr)
            position = end
        self.set_attributes(attrs)
        return moving

    def animate(self, _widget, _clock):
        if self.paint_letters(time.monotonic()):
            return True
        self.tick = None
        return False


class VoiceIcon(Gtk.DrawingArea):
    """Colored dots gather into a waveform, orbit, then settle for delivery."""

    def __init__(self):
        super().__init__()
        self.set_size_request(40, 40)
        self.set_valign(Gtk.Align.CENTER)
        self.phase = "listening"
        self.started = time.monotonic()
        self.last_frame = self.started
        self.processing = 0.0
        self.sending = 0.0
        self.tick = None
        self.connect("draw", self.draw_icon)
        self.connect("map", self.start_animation)
        self.connect("unmap", self.stop_animation)

    def set_phase(self, phase):
        self.phase = phase
        self.get_accessible().set_name(phase)
        if phase == "listening":
            self.started = time.monotonic()
            self.processing = self.sending = 0.0
        self.queue_draw()

    def start_animation(self, *_):
        self.last_frame = time.monotonic()
        if self.tick is None:
            self.tick = self.add_tick_callback(self.animate)

    def stop_animation(self, *_):
        if self.tick is not None:
            self.remove_tick_callback(self.tick)
            self.tick = None

    def animate(self, *_):
        now = time.monotonic()
        delta = now - self.last_frame
        if delta < 1 / 60:
            return True
        self.last_frame = now
        blend = 1 - math.exp(-delta * 10)
        self.processing += ((self.phase == "finishing") - self.processing) * blend
        self.sending += ((self.phase == "pasting") - self.sending) * blend
        self.queue_draw()
        return True

    def draw_icon(self, _widget, cr):
        elapsed = time.monotonic() - self.started
        entrance = ease(elapsed / 0.5)
        cr.translate(20, 20)
        scale = (0.65 + 0.35 * entrance) * (1 - 0.12 * self.sending)
        cr.scale(scale, scale)
        glow = cairo.RadialGradient(0, 0, 2, 0, 0, 20)
        glow.add_color_stop_rgba(
            0, 0.57, 0.43, 1, 0.16 + 0.025 * math.sin(elapsed * 1.8)
        )
        glow.add_color_stop_rgba(1, 0.57, 0.43, 1, 0)
        cr.set_source(glow)
        cr.arc(0, 0, 20, 0, math.tau)
        cr.fill()
        cr.set_line_cap(cairo.LINE_CAP_ROUND)
        if self.phase == "error":
            cr.set_source_rgb(0.94, 0.57, 0.59)
            cr.set_line_width(2)
            cr.move_to(-4, -4)
            cr.line_to(4, 4)
            cr.move_to(4, -4)
            cr.line_to(-4, 4)
            cr.stroke()
            return False
        colors = (
            (0.43, 0.70, 1),
            (0.58, 0.57, 1),
            (0.79, 0.55, 0.97),
            (0.96, 0.60, 0.76),
            (0.98, 0.75, 0.63),
        )
        for index, color in enumerate(colors):
            wave = (math.sin(elapsed * 3.2 - index * 0.8) + 1) / 2
            height = 3 + (1 - abs(index - 2) / 3) * (5 + 12 * wave)
            angle = elapsed * 2.4 + index * math.tau / 5
            x = (index - 2) * 5 * (1 - self.processing) + math.cos(
                angle
            ) * 10 * self.processing
            y = math.sin(angle) * 8 * self.processing
            height = height * (1 - self.processing) * (1 - self.sending)
            # Stagger the arrival of five dots along a curling path, then
            # unfurl them into bars. Blend out naturally on an early release.
            arrival = elapsed - index * 0.035
            gather = ease(arrival / 0.5)
            unfurl = ease((arrival - 0.3) / 0.65)
            opening = (1 - unfurl) * (1 - self.processing) * (1 - self.sending)
            radius = 17 - 8 * gather
            opening_angle = index * math.tau / 5 - 1.1 + gather * 1.6
            x = x * (1 - opening) + math.cos(opening_angle) * radius * opening
            y = y * (1 - opening) + math.sin(opening_angle) * radius * opening
            height *= 1 - opening
            opacity = ease(arrival / 0.25)
            cr.set_source_rgba(*color, (0.8 + 0.2 * wave) * entrance * opacity)
            cr.set_line_width(2.8)
            cr.move_to(x, y - height / 2)
            cr.line_to(x, y + max(0.01, height / 2))
            cr.stroke()
        return False


class DictationOverlay:
    def __init__(self):
        self.window = window = Gtk.Window()
        window.set_name("voice-input")
        window.set_app_paintable(True)
        window.set_visual(window.get_screen().get_rgba_visual())
        GtkLayerShell.init_for_window(window)
        GtkLayerShell.set_namespace(window, "voice-input")
        GtkLayerShell.set_layer(window, GtkLayerShell.Layer.OVERLAY)
        GtkLayerShell.set_anchor(window, GtkLayerShell.Edge.BOTTOM, True)
        GtkLayerShell.set_margin(window, GtkLayerShell.Edge.BOTTOM, 64)
        GtkLayerShell.set_exclusive_zone(window, -1)
        GtkLayerShell.set_keyboard_mode(window, GtkLayerShell.KeyboardMode.NONE)
        window.set_accept_focus(False)
        window.connect(
            "realize",
            lambda widget: widget.get_window().input_shape_combine_region(
                cairo.Region(), 0, 0
            ),
        )
        card = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        card.set_name("dictation-card")
        window.add(card)
        self.icon = VoiceIcon()
        card.pack_start(self.icon, False, False, 0)
        self.text = AnimatedTranscript()
        self.text.set_valign(Gtk.Align.CENTER)
        card.pack_start(self.text, True, True, 0)
        css = Gtk.CssProvider()
        css.load_from_data(b"""
            #voice-input { background: transparent; }
            #dictation-card { background: #1c1c1e; border: none;
              border-radius: 24px; padding: 12px 18px 12px 12px; }
            #dictation-card label { font-family: sans-serif; }
            #dictation-text { color: #acb0bd; font-size: 15px; }
        """)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )
        self.hide_timer = None

    def hide_error(self):
        self.hide_timer = None
        self.window.hide()
        return False

    def update(self, action, value):
        if action in {"show", "hide", "error"} and self.hide_timer:
            GLib.source_remove(self.hide_timer)
            self.hide_timer = None
        if action == "show":
            self.text.placeholder("")
            self.icon.set_phase("listening")
            self.window.show_all()
        elif action == "text":
            self.text.update_transcript(*value)
        elif action == "status":
            self.icon.set_phase("pasting" if value == "Pasting…" else "finishing")
        elif action == "hide":
            self.window.hide()
        elif action == "error":
            self.text.placeholder(value)
            self.icon.set_phase("error")
            self.window.show_all()
            self.hide_timer = GLib.timeout_add_seconds(6, self.hide_error)
        return False
