const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
// No Server import to break circular dependency

pub const KeyboardDevice = struct {
    server: *anyopaque,
    link: wl.list.Link = undefined,
    device: *wlr.InputDevice,

    modifiers: wl.Listener(*wlr.Keyboard) = undefined,
    key: wl.Listener(*wlr.Keyboard.event.Key) = undefined,
    destroy: wl.Listener(*wlr.InputDevice) = undefined,

    pub fn create(server: *anyopaque, device: *wlr.InputDevice) !void {
        const keyboard = try std.heap.c_allocator.create(KeyboardDevice);
        errdefer std.heap.c_allocator.destroy(keyboard);

        keyboard.* = .{
            .server = server,
            .device = device,
        };

        const context = xkb.Context.new(.no_flags) orelse return error.ContextFailed;
        defer context.unref();
        const keymap = xkb.Keymap.newFromNames(context, null, .no_flags) orelse return error.KeymapFailed;
        defer keymap.unref();

        const wlr_keyboard = device.toKeyboard();
        if (!wlr_keyboard.setKeymap(keymap)) return error.SetKeymapFailed;
        wlr_keyboard.setRepeatInfo(25, 600);

        keyboard.modifiers = .{ .notify = @ptrCast(&handleModifiersC), .link = undefined };
        keyboard.key = .{ .notify = @ptrCast(&handleKeyC), .link = undefined };
        keyboard.destroy = .{ .notify = @ptrCast(&handleDestroyC), .link = undefined };

        wlr_keyboard.events.modifiers.add(&keyboard.modifiers);
        wlr_keyboard.events.key.add(&keyboard.key);
        device.events.destroy.add(&keyboard.destroy);

        const Server = @import("Server.zig").Server;
        const s: *Server = @ptrCast(@alignCast(server));
        wlr.Seat.setKeyboard(s.seat, wlr_keyboard);
        s.keyboards.append(keyboard);
    }
};

fn handleModifiersC(listener: *wl.Listener(*wlr.Keyboard), data: ?*anyopaque) callconv(.c) void {
    const wlr_keyboard: *wlr.Keyboard = @ptrCast(@alignCast(data.?));
    handleModifiers(listener, wlr_keyboard);
}

fn handleModifiers(listener: *wl.Listener(*wlr.Keyboard), wlr_keyboard: *wlr.Keyboard) void {
    const Server = @import("Server.zig").Server;
    const keyboard: *KeyboardDevice = @fieldParentPtr("modifiers", listener);
    const server: *Server = @ptrCast(@alignCast(keyboard.server));
    wlr.Seat.setKeyboard(server.seat, wlr_keyboard);
    wlr.Seat.keyboardNotifyModifiers(server.seat, &wlr_keyboard.modifiers);
}

fn handleKeyC(listener: *wl.Listener(*wlr.Keyboard.event.Key), data: ?*anyopaque) callconv(.c) void {
    const event: *wlr.Keyboard.event.Key = @ptrCast(@alignCast(data.?));
    handleKey(listener, event);
}

fn handleKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
    const Server = @import("Server.zig").Server;
    const keyboard: *KeyboardDevice = @fieldParentPtr("key", listener);
    const server: *Server = @ptrCast(@alignCast(keyboard.server));
    const wlr_keyboard = keyboard.device.toKeyboard();

    // Translate libinput keycode -> xkbcommon
    const keycode = event.keycode + 8;

    var handled = false;
    const wlr_keyboard_ptr = wlr_keyboard; // help with capture
    if (event.state == .pressed) {
        if (wlr_keyboard.xkb_state) |state| {
            const mods = wlr_keyboard.getModifiers();
            const syms = state.keyGetSyms(keycode);

            var is_mod = false;
            for (syms) |sym| {
                if (isModifier(sym)) {
                    is_mod = true;
                    break;
                }
                const s = @intFromEnum(sym);
                if (s >= 0x1008FE01 and s <= 0x1008FE0C) { // XF86Switch_VT_1 through XF86Switch_VT_12
                    if (server.session) |session| {
                        session.changeVt(@intCast(s - 0x1008FE01 + 1)) catch {};
                        return;
                    }
                }
            }

            if (is_mod) {
                if (server.active_session_lock == null) {
                    server.last_mod_tap_ready = true;
                    if (syms.len > 0) server.last_mod_sym = syms[0];
                }
            } else {
                server.last_mod_tap_ready = false;
                server.last_mod_sym = null;
                if (server.active_session_lock == null) {
                    if (server.handleKeybind(syms, mods)) {
                        handled = true;
                    }
                }
            }
        }
    } else { // .released
        if (wlr_keyboard.xkb_state) |state| {
            if (server.active_session_lock == null) {
                const mods = wlr_keyboard.getModifiers();
                const syms = state.keyGetSyms(keycode);
                if (server.last_mod_tap_ready) {
                    if (server.last_mod_sym) |last_sym| {
                        for (syms) |sym| {
                            if (@intFromEnum(sym) == @intFromEnum(last_sym)) {
                                if (server.current_sequence.items.len == 0) {
                                    std.log.debug("Modifier Tap detected: sym={}", .{sym});
                                    _ = server.handleKeybind(syms, mods);
                                }
                                break;
                            }
                        }
                    }
                }
            }
            server.last_mod_tap_ready = false;
            server.last_mod_sym = null;
        }
    }

    if (!handled) {
        wlr.Seat.setKeyboard(server.seat, wlr_keyboard_ptr);
        server.seat.keyboardNotifyKey(event.time_msec, event.keycode, event.state);
    }
}

fn isModifier(sym: xkb.Keysym) bool {
    const s = @intFromEnum(sym);
    return s == xkb.Keysym.Control_L or s == xkb.Keysym.Control_R or
        s == xkb.Keysym.Shift_L or s == xkb.Keysym.Shift_R or
        s == xkb.Keysym.Alt_L or s == xkb.Keysym.Alt_R or
        s == xkb.Keysym.Super_L or s == xkb.Keysym.Super_R;
}

fn handleDestroyC(listener: *wl.Listener(*wlr.InputDevice), data: ?*anyopaque) callconv(.c) void {
    const device: *wlr.InputDevice = @ptrCast(@alignCast(data.?));
    handleDestroy(listener, device);
}

fn handleDestroy(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
    const keyboard: *KeyboardDevice = @fieldParentPtr("destroy", listener);

    keyboard.link.remove();

    keyboard.modifiers.link.remove();
    keyboard.key.link.remove();
    keyboard.destroy.link.remove();

    std.heap.c_allocator.destroy(keyboard);
}
