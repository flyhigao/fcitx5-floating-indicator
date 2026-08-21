#!/usr/bin/python3
"""Small X11 indicator for the current Fcitx5/Rime Chinese-English state.

Shows while the mouse is moving and hides 1 second after it stops.
"""

import dbus
import dbus.mainloop.glib
import gi
import re
import subprocess
import threading
import time

gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")

from gi.repository import Gdk, GLib, Gtk


FCITX_SERVICE = "org.fcitx.Fcitx5"
IC_INTERFACE = "org.fcitx.Fcitx.InputContext1"
CONTROLLER_INTERFACE = "org.fcitx.Fcitx.Controller1"
RIME_INTERFACE = "org.fcitx.Fcitx.Rime1"
IC_PREFIX = "/org/freedesktop/portal/inputcontext/"


class Indicator:
    def __init__(self):
        self.bus = dbus.SessionBus()
        self.controller = dbus.Interface(
            self.bus.get_object(FCITX_SERVICE, "/controller"),
            CONTROLLER_INTERFACE,
        )
        self.rime = dbus.Interface(
            self.bus.get_object(FCITX_SERVICE, "/rime"), RIME_INTERFACE
        )
        self.focused_context = None
        self.cursor_rect = None
        self.has_composition = False
        self.typing = False
        self.idle_serial = 0
        self.visible = False
        self.last_state = None

        # 鼠标移动即显示、停止 1 秒后隐藏
        self.last_mouse_pos = None
        self.last_mouse_move = time.monotonic()  # 启动时视为刚移动过
        self.mouse_hide_source = None
        self.mouse_idle_timeout = 1.0

        # A borderless top-level window is more reliable than Gtk.POPUP on
        # DDE/KWin, while the hints below keep it non-focusable and out of
        # task switching.
        self.window = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
        self.window.set_decorated(False)
        self.window.set_resizable(False)
        self.window.set_keep_above(True)
        self.window.set_skip_taskbar_hint(True)
        self.window.set_skip_pager_hint(True)
        self.window.set_accept_focus(False)
        self.window.set_focus_on_map(False)
        self.window.set_can_focus(False)
        self.window.set_type_hint(Gdk.WindowTypeHint.NOTIFICATION)
        self.window.set_opacity(0.94)

        self.label = Gtk.Label(label="中")
        self.label.set_margin_top(2)
        self.label.set_margin_bottom(2)
        self.label.set_margin_start(6)
        self.label.set_margin_end(6)
        self.window.add(self.label)

        css = Gtk.CssProvider()
        css.load_from_data(
            b"""
            window { background-color: rgba(32, 106, 190, 0.94); border-radius: 5px; }
            label { color: white; font-weight: bold; font-size: 11pt; }
            """
        )
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        self.bus.add_match_string_non_blocking(
            "type='signal',interface='org.fcitx.Fcitx.InputContext1'"
        )
        self.bus.add_message_filter(self._message_filter)

        monitor_rule = (
            "eavesdrop='true',type='method_call',"
            "interface='org.fcitx.Fcitx.InputContext1'"
        )
        self.monitor = subprocess.Popen(
            ["/usr/bin/dbus-monitor", "--session", monitor_rule],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
        threading.Thread(target=self._read_monitor, daemon=True).start()

        self.window.connect("destroy", self._quit)
        # WindTerm uses a fullscreen X11 window. Make the indicator an
        # unmanaged tooltip-like window so the window manager cannot place it
        # underneath that fullscreen surface.
        self.window.realize()
        gdk_window = self.window.get_window()
        if gdk_window and hasattr(gdk_window, "set_override_redirect"):
            gdk_window.set_override_redirect(True)
        self._set_input_passthrough()
        self.window.show_all()
        GLib.timeout_add(120, self._poll_state)
        GLib.timeout_add(250, self._poll_position)
        GLib.timeout_add(600, self._initial_show)

    def _quit(self, *_args):
        if self.monitor.poll() is None:
            self.monitor.terminate()
        Gtk.main_quit()

    @staticmethod
    def _parse_monitor_value(line):
        line = line.strip()
        match = re.match(r"(?:u?int32|int32|uint64|int64) (-?\d+)$", line)
        if match:
            return int(match.group(1))
        match = re.match(r"boolean (true|false)$", line)
        if match:
            return match.group(1) == "true"
        match = re.match(r"double (-?[0-9.]+)$", line)
        if match:
            return float(match.group(1))
        return None

    def _read_monitor(self):
        header_re = re.compile(r"path=(\S+).*member=(\w+)")
        pending = None
        args = []
        expected = {
            "SetCursorRect": 4,
            "SetCursorRectV2": 5,
            "ProcessKeyEvent": 5,
            "ProcessKeyEventBatch": 5,
            "SelectCandidate": 1,
        }
        for raw_line in self.monitor.stdout:
            line = raw_line.rstrip("\n")
            header = header_re.search(line)
            if header:
                pending = (header.group(1).rstrip(";"), header.group(2))
                args = []
                if pending[1] in ("FocusIn", "FocusOut", "DestroyIC", "Reset"):
                    GLib.idle_add(self._handle_monitored_event, pending[1], pending[0], [])
                    pending = None
                continue
            if pending is None:
                continue
            value = self._parse_monitor_value(line)
            if value is None:
                continue
            args.append(value)
            count = expected.get(pending[1])
            if count and len(args) >= count:
                member, path = pending[1], pending[0]
                GLib.idle_add(self._handle_monitored_event, member, path, args[:count])
                pending = None

    def _handle_monitored_event(self, member, path, args):
        if member == "FocusIn":
            self.focused_context = path
            self.typing = False
            self.has_composition = False
            self._show()
        elif member in ("FocusOut", "DestroyIC"):
            if path == self.focused_context:
                self.focused_context = None
                self.typing = False
                self.has_composition = False
                # Some applications, including WindTerm, do not create a
                # new Fcitx input context. Keep the global indicator visible
                # while falling back to mouse position.
                self._show()
        elif member == "SetCursorRect" and len(args) >= 4:
            self.cursor_rect = tuple(int(v) for v in args[:4])
            if path == self.focused_context and not self.has_composition:
                self._move()
        elif member == "SetCursorRectV2" and len(args) >= 5:
            x, y, width, height, scale = args[:5]
            scale = float(scale) or 1.0
            self.cursor_rect = (
                int(x * scale), int(y * scale),
                int(width * scale), int(height * scale),
            )
            if path == self.focused_context and not self.has_composition:
                self._move()
        elif member in ("ProcessKeyEvent", "ProcessKeyEventBatch") and len(args) >= 4:
            keyval, _keycode, _state, is_release = args[:4]
            if not is_release:
                keyval = int(keyval)
                if keyval in (65505, 65506):
                    self._schedule_state_refresh()
                elif self._is_typing_key(keyval):
                    self.typing = True
                    self._hide()
                    self._schedule_show_after_idle()
                elif self.typing and int(keyval) in (65293, 65289, 65307):
                    self._schedule_show_after_idle(180)
        elif member in ("Reset", "SelectCandidate"):
            self.typing = False
            self._schedule_show_after_idle(120)
        return False

    def _set_input_passthrough(self):
        gdk_window = self.window.get_window()
        if gdk_window and hasattr(gdk_window, "set_pass_through"):
            gdk_window.set_pass_through(True)

    def _message_filter(self, _bus, message):
        path = message.get_path() or ""
        if not path.startswith(IC_PREFIX):
            return

        interface = message.get_interface()
        member = message.get_member()
        if interface == IC_INTERFACE and message.get_type() == dbus.lowlevel.MESSAGE_TYPE_SIGNAL:
            if member == "FocusIn":
                self.focused_context = path
                self.has_composition = False
                self._show()
            elif member in ("FocusOut", "NotifyFocusOut"):
                if path == self.focused_context:
                    self.focused_context = None
                    self.has_composition = False
                    self._show()
            elif member == "UpdateClientSideUI" and path == self.focused_context:
                args = message.get_args_list()
                if len(args) >= 8:
                    preedit, _cursor, aux_up, aux_down, candidates = args[:5]
                    self.has_composition = bool(preedit or aux_up or aux_down or candidates)
                    if self.has_composition:
                        self._hide()
                    elif self.typing:
                        self._schedule_show_after_idle()
                    else:
                        self._show()
            elif member == "CommitString" and path == self.focused_context:
                self.has_composition = False
                GLib.timeout_add(80, self._show_if_idle)
        elif interface == IC_INTERFACE and message.get_type() == dbus.lowlevel.MESSAGE_TYPE_METHOD_CALL:
            args = message.get_args_list()
            if member == "FocusIn":
                self.focused_context = path
                self.typing = False
                self.has_composition = False
                self._show()
            elif member in ("FocusOut", "DestroyIC"):
                if path == self.focused_context:
                    self.focused_context = None
                    self.typing = False
                    self.has_composition = False
                    self._show()
            elif member == "SetCursorRect" and len(args) >= 4:
                x, y, width, height = [int(v) for v in args[:4]]
                self.cursor_rect = (x, y, width, height)
                if path == self.focused_context and not self.has_composition:
                    self._move()
            elif member == "SetCursorRectV2" and len(args) >= 5:
                x, y, width, height, scale = args[:5]
                scale = float(scale) or 1.0
                self.cursor_rect = (
                    int(float(x) * scale),
                    int(float(y) * scale),
                    int(float(width) * scale),
                    int(float(height) * scale),
                )
                if path == self.focused_context and not self.has_composition:
                    self._move()
            elif member in ("ProcessKeyEvent", "ProcessKeyEventBatch") and len(args) >= 4:
                keyval = int(args[0])
                is_release = bool(args[3])
                if not is_release:
                    if keyval in (65505, 65506):
                        self._schedule_state_refresh()
                    elif self._is_typing_key(keyval):
                        self.typing = True
                        self._hide()
                        self._schedule_show_after_idle()
                    elif self.typing and keyval in (65293, 65289, 65307):
                        self._schedule_show_after_idle(180)
            elif member in ("Reset", "SelectCandidate"):
                self.typing = False
                self._schedule_show_after_idle(120)
        return dbus.lowlevel.HANDLER_RESULT_NOT_YET_HANDLED

    @staticmethod
    def _is_typing_key(keyval):
        # Printable keys plus editing keys. Modifier-only keys, including
        # Shift used for Chinese/English switching, do not hide the label.
        return 32 <= keyval <= 126 or keyval in (65288, 65535)

    def _schedule_show_after_idle(self, delay=800):
        self.idle_serial += 1
        serial = self.idle_serial

        def show_if_current():
            if serial != self.idle_serial:
                return False
            if self.has_composition or self._candidate_window_visible():
                GLib.timeout_add(200, show_if_current)
                return False
            self.typing = False
            self._show()
            return False

        GLib.timeout_add(delay, show_if_current)

    def _schedule_state_refresh(self):
        """Refresh immediately after Shift toggles Rime's ASCII mode."""
        GLib.timeout_add(80, self._refresh_state_after_switch)

    def _refresh_state_after_switch(self):
        self._poll_state()
        if not self.has_composition and not self._candidate_window_visible():
            self.typing = False
            self._show()
        return False

    @staticmethod
    def _candidate_window_visible():
        """Fcitx5 ClassicUI is an X11 window while a candidate/preedit is up."""
        try:
            found = subprocess.run(
                ["/usr/bin/xdotool", "search", "--name", "Fcitx5 Input Window"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=0.15,
                check=False,
            )
            window_id = found.stdout.splitlines()[0].strip()
            state = subprocess.run(
                ["/usr/bin/xwininfo", "-id", window_id],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=0.15,
                check=False,
            )
            return "Map State: IsViewable" in state.stdout
        except (IndexError, subprocess.SubprocessError, OSError):
            return False

    def _poll_state(self):
        try:
            current_im = str(self.controller.CurrentInputMethod())
            ascii_mode = bool(self.rime.IsAsciiMode()) if current_im == "rime" else True
        except Exception:
            current_im, ascii_mode = "rime", False
        state = "英" if ascii_mode else "中"
        if state != self.last_state:
            self.last_state = state
            self.label.set_text(state)
            self._set_color(ascii_mode)
            if self.visible:
                self._move()
        return True

    def _set_color(self, ascii_mode):
        color = "#777777" if ascii_mode else "#206abe"
        css = Gtk.CssProvider()
        css.load_from_data(
            ("window { background-color: %s; border-radius: 5px; }" % color).encode()
        )
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

    def _poll_position(self):
        display = Gdk.Display.get_default()
        _screen, x, y = display.get_default_seat().get_pointer().get_position()
        moved = (
            self.last_mouse_pos is None
            or abs(x - self.last_mouse_pos[0]) > 0
            or abs(y - self.last_mouse_pos[1]) > 0
        )
        self.last_mouse_pos = (x, y)
        if moved:
            self._on_mouse_moved()
        if self.visible and not self.has_composition:
            self._move()
        return True

    def _on_mouse_moved(self):
        """鼠标动了：重置 1 秒隐藏计时器；隐藏期间若未在输入则重新显示。"""
        self.last_mouse_move = time.monotonic()
        if self.mouse_hide_source is not None:
            GLib.source_remove(self.mouse_hide_source)
        self.mouse_hide_source = GLib.timeout_add(
            int(self.mouse_idle_timeout * 1000), self._hide_when_mouse_idle
        )
        if not self.visible and not self.typing and not self.has_composition \
                and not self._candidate_window_visible():
            self._show()

    def _hide_when_mouse_idle(self):
        """鼠标停止移动 1 秒后隐藏窗口。"""
        self.mouse_hide_source = None
        self._hide()
        return False

    @property
    def _mouse_active(self):
        return time.monotonic() - self.last_mouse_move < self.mouse_idle_timeout

    def _initial_show(self):
        self._show()
        return False

    def _show_if_idle(self):
        if not self.has_composition:
            self._show()
        return False

    def _show(self):
        # 只在鼠标近期移动过时显示（移动中持续显示，停止 1 秒后隐藏）
        if not self._mouse_active:
            return
        if not self.visible:
            self.window.show()
            self._set_input_passthrough()
            self.visible = True
        self._move()

    def _hide(self):
        if self.visible:
            self.window.hide()
            self.visible = False

    def _move(self):
        if not self.visible:
            return
        # Follow the mouse rather than the text cursor. This also works in
        # applications that do not expose an Fcitx cursor rectangle.
        display = Gdk.Display.get_default()
        screen = display.get_default_screen()
        pointer = display.get_default_seat().get_pointer()
        _screen, target_x, target_y = pointer.get_position()
        target_x += 24
        target_y += 28

        self.window.show_all()
        _minimum, natural = self.window.get_preferred_size()
        width, height = natural.width, natural.height
        screen = Gdk.Screen.get_default()
        monitor = screen.get_monitor_at_point(target_x, target_y)
        geometry = screen.get_monitor_geometry(monitor)
        target_x = min(max(target_x, geometry.x + 2), geometry.x + geometry.width - width - 2)
        target_y = min(max(target_y, geometry.y + 2), geometry.y + geometry.height - height - 2)
        self.window.move(target_x, target_y)


def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    Gtk.init([])
    Indicator()
    Gtk.main()


if __name__ == "__main__":
    main()
