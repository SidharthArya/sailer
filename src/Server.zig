const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const Output = @import("Output.zig").Output;
const View = @import("View.zig");
const Toplevel = View.Toplevel;
const Popup = View.Popup;
const KeyboardDevice = @import("Keyboard.zig").KeyboardDevice;
const Workspace = @import("Workspace.zig").Workspace;

pub const Server = struct {
    wl_server: *wl.Server,
    backend: *wlr.Backend,
    renderer: *wlr.Renderer,
    allocator: *wlr.Allocator,
    scene: *wlr.Scene,

    output_layout: *wlr.OutputLayout,
    scene_output_layout: *wlr.SceneOutputLayout,
    new_output: wl.Listener(*wlr.Output) = .init(Server.newOutput),

    xdg_shell: *wlr.XdgShell,
    new_xdg_toplevel: wl.Listener(*wlr.XdgToplevel) = .init(Server.newXdgToplevel),
    new_xdg_popup: wl.Listener(*wlr.XdgPopup) = .init(Server.newXdgPopup),

    workspaces: [9]*Workspace = undefined,
    focused_workspace: *Workspace = undefined,

    seat: *wlr.Seat,
    new_input: wl.Listener(*wlr.InputDevice) = .init(Server.newInput),
    request_set_cursor: wl.Listener(*wlr.Seat.event.RequestSetCursor) = .init(Server.requestSetCursor),
    request_set_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) = .init(Server.requestSetSelection),
    keyboards: wl.list.Head(KeyboardDevice, .link) = undefined,

    cursor: *wlr.Cursor,
    cursor_mgr: *wlr.XcursorManager,
    cursor_motion: wl.Listener(*wlr.Pointer.event.Motion) = .init(Server.cursorMotion),
    cursor_motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = .init(Server.cursorMotionAbsolute),
    cursor_button: wl.Listener(*wlr.Pointer.event.Button) = .init(Server.cursorButton),
    cursor_axis: wl.Listener(*wlr.Pointer.event.Axis) = .init(Server.cursorAxis),
    cursor_frame: wl.Listener(*wlr.Cursor) = .init(Server.cursorFrame),

    config: std.json.Parsed(@import("Config.zig").Config) = undefined,

    cursor_mode: enum { passthrough, move, resize } = .passthrough,
    grabbed_view: ?*Toplevel = null,
    grab_x: f64 = 0,
    grab_y: f64 = 0,
    grab_box: wlr.Box = undefined,
    resize_edges: wlr.Edges = .{},
    socket_name: []const u8 = "",

    pub fn init(server: *Server) !void {
        const wl_server = try wl.Server.create();
        const loop = wl_server.getEventLoop();
        const backend = try wlr.Backend.autocreate(loop, null);
        const renderer = try wlr.Renderer.autocreate(backend);
        const output_layout = try wlr.OutputLayout.create(wl_server);
        const scene = try wlr.Scene.create();
        server.* = .{
            .wl_server = wl_server,
            .backend = backend,
            .renderer = renderer,
            .allocator = try wlr.Allocator.autocreate(backend, renderer),
            .scene = scene,
            .output_layout = output_layout,
            .scene_output_layout = try scene.attachOutputLayout(output_layout),
            .xdg_shell = try wlr.XdgShell.create(wl_server, 2),
            .seat = try wlr.Seat.create(wl_server, "default"),
            .cursor = try wlr.Cursor.create(),
            .cursor_mgr = try wlr.XcursorManager.create(null, 24),
        };

        try server.renderer.initServer(wl_server);

        _ = try wlr.Compositor.create(server.wl_server, 6, server.renderer);
        _ = try wlr.Subcompositor.create(server.wl_server);
        // data device manager signature in zig-wlroots 0.19 requires only server
        _ = try wlr.DataDeviceManager.create(server.wl_server);

        server.backend.events.new_output.add(&server.new_output);

        server.xdg_shell.events.new_toplevel.add(&server.new_xdg_toplevel);
        server.xdg_shell.events.new_popup.add(&server.new_xdg_popup);

        // Initialize 9 workspaces
        for (&server.workspaces, 0..) |*ws, i| {
            var name_buf: [2]u8 = undefined;
            const name_str = std.fmt.bufPrint(&name_buf, "{d}", .{i + 1}) catch unreachable;
            const name = try std.heap.c_allocator.dupe(u8, name_str);
            ws.* = try Workspace.init(server, name);
        }
        server.focused_workspace = server.workspaces[0];

        server.backend.events.new_input.add(&server.new_input);
        server.seat.events.request_set_cursor.add(&server.request_set_cursor);
        server.seat.events.request_set_selection.add(&server.request_set_selection);
        server.keyboards.init();

        server.cursor.attachOutputLayout(server.output_layout);
        try server.cursor_mgr.load(1);
        server.cursor.events.motion.add(&server.cursor_motion);
        server.cursor.events.motion_absolute.add(&server.cursor_motion_absolute);
        server.cursor.events.button.add(&server.cursor_button);
        server.cursor.events.axis.add(&server.cursor_axis);
        server.cursor.events.frame.add(&server.cursor_frame);

        const Config = @import("Config.zig").Config;
        server.config = Config.load(std.heap.c_allocator) catch |err| blk: {
            std.log.err("failed to load config: {}, using default", .{err});
            break :blk Config.default(std.heap.c_allocator) catch unreachable;
        };
    }

    pub fn deinit(server: *Server) void {
        server.wl_server.destroyClients();

        server.new_input.link.remove();
        server.new_output.link.remove();

        server.new_xdg_toplevel.link.remove();
        server.new_xdg_popup.link.remove();
        server.request_set_cursor.link.remove();
        server.request_set_selection.link.remove();
        server.cursor_motion.link.remove();
        server.cursor_motion_absolute.link.remove();
        server.cursor_button.link.remove();
        server.cursor_axis.link.remove();
        server.cursor_frame.link.remove();

        server.backend.destroy();
        server.wl_server.destroy();
    }

    fn newOutput(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
        const server: *Server = @fieldParentPtr("new_output", listener);

        if (!wlr_output.initRender(server.allocator, server.renderer)) return;

        var state = wlr.Output.State.init();
        defer state.finish();

        state.setEnabled(true);
        if (wlr_output.preferredMode()) |mode| {
            state.setMode(mode);
        }
        if (!wlr_output.commitState(&state)) return;

        const output_ptr = Output.create(server, wlr_output) catch {
            std.log.err("failed to allocate new output", .{});
            wlr_output.destroy();
            return;
        };

        // Assign this output to the first hidden workspace
        for (&server.workspaces) |*ws| {
            if (ws.*.visible_on == null) {
                ws.*.setVisible(output_ptr);
                if (server.focused_workspace == ws.*) {
                    // Update focus if this is the first monitor initializing our focused workspace
                    break;
                }
                break;
            }
        }
    }

    fn newXdgToplevel(listener: *wl.Listener(*wlr.XdgToplevel), xdg_toplevel: *wlr.XdgToplevel) void {
        const server: *Server = @fieldParentPtr("new_xdg_toplevel", listener);
        const xdg_surface = xdg_toplevel.base;

        const toplevel = std.heap.c_allocator.create(Toplevel) catch {
            std.log.err("failed to allocate new toplevel", .{});
            return;
        };

        toplevel.* = .{
            .server = server,
            .workspace = server.focused_workspace,
            .xdg_toplevel = xdg_toplevel,
            .scene_tree = server.focused_workspace.scene_tree.createSceneXdgSurface(xdg_surface) catch {
                std.heap.c_allocator.destroy(toplevel);
                std.log.err("failed to allocate new toplevel scene tree", .{});
                return;
            },
        };
        toplevel.scene_tree.node.data = toplevel;
        xdg_surface.data = toplevel.scene_tree;

        xdg_surface.surface.events.commit.add(&toplevel.commit);
        xdg_surface.surface.events.map.add(&toplevel.map);
        xdg_surface.surface.events.unmap.add(&toplevel.unmap);
        xdg_toplevel.events.destroy.add(&toplevel.destroy);
        xdg_toplevel.events.request_move.add(&toplevel.request_move);
        xdg_toplevel.events.request_resize.add(&toplevel.request_resize);
    }

    fn newXdgPopup(_: *wl.Listener(*wlr.XdgPopup), xdg_popup: *wlr.XdgPopup) void {
        const xdg_surface = xdg_popup.base;

        const parent = wlr.XdgSurface.tryFromWlrSurface(xdg_popup.parent.?) orelse return;
        const parent_tree = @as(?*wlr.SceneTree, @ptrCast(@alignCast(parent.data))) orelse return;

        const scene_tree = parent_tree.createSceneXdgSurface(xdg_surface) catch {
            std.log.err("failed to allocate xdg popup node", .{});
            return;
        };
        xdg_surface.data = scene_tree;

        const popup = std.heap.c_allocator.create(Popup) catch {
            std.log.err("failed to allocate new popup", .{});
            return;
        };
        popup.* = .{
            .xdg_popup = xdg_popup,
        };

        xdg_surface.surface.events.commit.add(&popup.commit);
        xdg_popup.events.destroy.add(&popup.destroy);
    }

    pub const ViewAtResult = struct {
        toplevel: *Toplevel,
        surface: *wlr.Surface,
        sx: f64,
        sy: f64,
    };

    pub fn viewAt(server: *Server, lx: f64, ly: f64) ?ViewAtResult {
        var sx: f64 = undefined;
        var sy: f64 = undefined;
        if (server.scene.tree.node.at(lx, ly, &sx, &sy)) |node| {
            if (node.type != .buffer) return null;
            const scene_buffer = wlr.SceneBuffer.fromNode(node);
            const scene_surface = wlr.SceneSurface.tryFromBuffer(scene_buffer) orelse return null;

            var it: ?*wlr.SceneTree = node.parent;
            while (it) |n| : (it = n.node.parent) {
                if (@as(?*Toplevel, @ptrCast(@alignCast(n.node.data)))) |toplevel| {
                    return ViewAtResult{
                        .toplevel = toplevel,
                        .surface = scene_surface.surface,
                        .sx = sx,
                        .sy = sy,
                    };
                }
            }
        }
        return null;
    }

    pub fn focusView(server: *Server, toplevel: *Toplevel, surface: *wlr.Surface) void {
        if (server.seat.keyboard_state.focused_surface) |previous_surface| {
            if (previous_surface == surface) return;
            if (wlr.XdgSurface.tryFromWlrSurface(previous_surface)) |xdg_surface| {
                _ = wlr.XdgToplevel.setActivated(xdg_surface.role_data.toplevel.?, false);
            }
        }

        toplevel.scene_tree.node.raiseToTop();
        toplevel.link.remove();
        server.focused_workspace.views.prepend(toplevel);

        _ = wlr.XdgToplevel.setActivated(toplevel.xdg_toplevel, true);

        if (server.seat.keyboard_state.keyboard) |kbd| {
            wlr.Seat.keyboardNotifyEnter(server.seat, surface, kbd.keycodes[0..kbd.num_keycodes], &kbd.modifiers);
        }

        // Niri style scrolling: Center the focused view on its workspace visible output
        if (toplevel.workspace.visible_on) |output| {
            if (server.output_layout.get(output.wlr_output)) |l_output| {
                var box: wlr.Box = undefined;
                server.output_layout.getBox(l_output.output, &box);
                const view_width = @divTrunc(box.width * toplevel.width_percent, 100);
                toplevel.workspace.scroll_offset_x = toplevel.x - @divTrunc(box.width - view_width, 2);
                toplevel.workspace.arrange();
            }
        }
    }

    fn newInput(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
        const server: *Server = @fieldParentPtr("new_input", listener);
        switch (device.type) {
            .keyboard => KeyboardDevice.create(server, device) catch |err| {
                std.log.err("failed to create keyboard: {}", .{err});
                return;
            },
            .pointer => wlr.Cursor.attachInputDevice(server.cursor, device),
            else => {},
        }

        const has_keyboard = server.keyboards.link.next != &server.keyboards.link;

        wlr.Seat.setCapabilities(server.seat, .{
            .pointer = true,
            .keyboard = has_keyboard,
        });
    }

    fn requestSetCursor(
        listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor),
        event: *wlr.Seat.event.RequestSetCursor,
    ) void {
        const server: *Server = @fieldParentPtr("request_set_cursor", listener);
        if (event.seat_client == server.seat.pointer_state.focused_client)
            wlr.Cursor.setSurface(server.cursor, event.surface, event.hotspot_x, event.hotspot_y);
    }

    fn requestSetSelection(
        listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection),
        event: *wlr.Seat.event.RequestSetSelection,
    ) void {
        const server: *Server = @fieldParentPtr("request_set_selection", listener);
        wlr.Seat.setSelection(server.seat, event.source, event.serial);
    }

    fn cursorMotion(
        listener: *wl.Listener(*wlr.Pointer.event.Motion),
        event: *wlr.Pointer.event.Motion,
    ) void {
        const server: *Server = @fieldParentPtr("cursor_motion", listener);
        server.cursor.move(event.device, event.delta_x, event.delta_y);
        server.processCursorMotion(event.time_msec);
    }

    fn cursorMotionAbsolute(
        listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute),
        event: *wlr.Pointer.event.MotionAbsolute,
    ) void {
        const server: *Server = @fieldParentPtr("cursor_motion_absolute", listener);
        server.cursor.warpAbsolute(event.device, event.x, event.y);
        server.processCursorMotion(event.time_msec);
    }

    fn processCursorMotion(server: *Server, time_msec: u32) void {
        switch (server.cursor_mode) {
            .passthrough => if (server.viewAt(server.cursor.x, server.cursor.y)) |res| {
                wlr.Seat.pointerNotifyEnter(server.seat, res.surface, res.sx, res.sy);
                wlr.Seat.pointerNotifyMotion(server.seat, time_msec, res.sx, res.sy);
            } else {
                server.cursor.setXcursor(server.cursor_mgr, "default");
                wlr.Seat.pointerClearFocus(server.seat);
            },
            .move => {
                const toplevel = server.grabbed_view.?;
                toplevel.x = @as(i32, @intFromFloat(server.cursor.x - server.grab_x));
                toplevel.y = @as(i32, @intFromFloat(server.cursor.y - server.grab_y));
                toplevel.scene_tree.node.setPosition(toplevel.x, toplevel.y);
            },
            .resize => {
                const toplevel = server.grabbed_view.?;
                const border_x = @as(i32, @intFromFloat(server.cursor.x - server.grab_x));
                const border_y = @as(i32, @intFromFloat(server.cursor.y - server.grab_y));

                var new_left = server.grab_box.x;
                var new_right = server.grab_box.x + server.grab_box.width;
                var new_top = server.grab_box.y;
                var new_bottom = server.grab_box.y + server.grab_box.height;

                if (server.resize_edges.top) {
                    new_top = border_y;
                    if (new_top >= new_bottom) new_top = new_bottom - 1;
                } else if (server.resize_edges.bottom) {
                    new_bottom = border_y;
                    if (new_bottom <= new_top) new_bottom = new_top + 1;
                }

                if (server.resize_edges.left) {
                    new_left = border_x;
                    if (new_left >= new_right) new_left = new_right - 1;
                } else if (server.resize_edges.right) {
                    new_right = border_x;
                    if (new_right <= new_left) new_right = new_left + 1;
                }

                toplevel.x = new_left - toplevel.xdg_toplevel.base.geometry.x;
                toplevel.y = new_top - toplevel.xdg_toplevel.base.geometry.y;
                toplevel.scene_tree.node.setPosition(toplevel.x, toplevel.y);

                const new_width = new_right - new_left;
                const new_height = new_bottom - new_top;
                _ = toplevel.xdg_toplevel.setSize(new_width, new_height);
            },
        }
    }

    fn cursorButton(
        listener: *wl.Listener(*wlr.Pointer.event.Button),
        event: *wlr.Pointer.event.Button,
    ) void {
        const server: *Server = @fieldParentPtr("cursor_button", listener);
        _ = wlr.Seat.pointerNotifyButton(server.seat, event.time_msec, event.button, event.state);
        if (event.state == .released) {
            server.cursor_mode = .passthrough;
        } else if (server.viewAt(server.cursor.x, server.cursor.y)) |res| {
            server.focusView(res.toplevel, res.surface);
        }
    }

    fn cursorAxis(
        listener: *wl.Listener(*wlr.Pointer.event.Axis),
        event: *wlr.Pointer.event.Axis,
    ) void {
        const server: *Server = @fieldParentPtr("cursor_axis", listener);
        wlr.Seat.pointerNotifyAxis(
            server.seat,
            event.time_msec,
            event.orientation,
            event.delta,
            event.delta_discrete,
            event.source,
            event.relative_direction,
        );
    }

    fn cursorFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
        const server: *Server = @fieldParentPtr("cursor_frame", listener);
        wlr.Seat.pointerNotifyFrame(server.seat);
    }

    pub fn switchToWorkspace(server: *Server, index: u32) void {
        if (index >= server.workspaces.len) return;
        const target_ws = server.workspaces[index];
        if (server.focused_workspace == target_ws) return;

        const current_ws = server.focused_workspace;
        const focused_output = current_ws.visible_on;

        if (target_ws.visible_on) |other_output| {
            // Swap workspaces between outputs
            current_ws.setVisible(other_output);
            target_ws.setVisible(focused_output);
        } else if (focused_output) |output| {
            current_ws.setVisible(null);
            target_ws.setVisible(output);
        }

        server.focused_workspace = target_ws;

        // Focus topmost window in new workspace
        if (target_ws.views.link.next != &target_ws.views.link) {
            const head = target_ws.views.link.next.?;
            const toplevel: *Toplevel = @fieldParentPtr("link", head);
            server.focusView(toplevel, toplevel.xdg_toplevel.base.surface);
        } else {
            wlr.Seat.keyboardNotifyClearFocus(server.seat);
        }
    }

    pub fn handleKeybind(server: *Server, key: xkb.Keysym, mods: wlr.Keyboard.ModifierMask) bool {
        // Log all keypresses to help debugging config issues
        std.log.info("KeyPress: sym={d}, mods(c={}, s={}, a={}, l={})", .{ @intFromEnum(key), mods.ctrl, mods.shift, mods.alt, mods.logo });

        for (server.config.value.keybindings) |kb| {
            const kb_sym = kb.getKeysym();
            const kb_mods = kb.getModifiers();

            // Log what we are checking against
            std.log.info("Checking against: sym={d}, mods(c={}, s={}, a={}, l={})", .{ @intFromEnum(kb_sym), kb_mods.ctrl, kb_mods.shift, kb_mods.alt, kb_mods.logo });

            if (@intFromEnum(key) == @intFromEnum(kb_sym) and
                mods.ctrl == kb_mods.ctrl and
                mods.shift == kb_mods.shift and
                mods.alt == kb_mods.alt and
                mods.logo == kb_mods.logo)
            {
                std.log.info("Keybinding Match Found: action={any}", .{kb.action});
                switch (kb.action) {
                    .spawn => if (kb.command) |cmd| {
                        std.log.info("Spawning: {s}", .{cmd});
                        var child = std.process.Child.init(&[_][]const u8{ "sh", "-c", cmd }, std.heap.c_allocator);

                        var env = std.process.getEnvMap(std.heap.c_allocator) catch {
                            return true;
                        };
                        defer env.deinit();
                        env.put("WAYLAND_DISPLAY", server.socket_name) catch {};
                        child.env_map = &env;

                        _ = child.spawn() catch |err| {
                            std.log.err("failed to spawn command '{s}': {any}", .{ cmd, err });
                        };
                    },
                    .focus_left => server.focused_workspace.focusRelative(-1),
                    .focus_right => server.focused_workspace.focusRelative(1),
                    .resize_shrink => if (server.seat.keyboard_state.focused_surface) |surface| {
                        if (wlr.XdgSurface.tryFromWlrSurface(surface)) |xdg_surface| {
                            if (View.fromXdgSurface(xdg_surface)) |t| {
                                t.width_percent = @max(10, t.width_percent - 5);
                                t.workspace.arrange();
                            }
                        }
                    },
                    .resize_expand => if (server.seat.keyboard_state.focused_surface) |surface| {
                        if (wlr.XdgSurface.tryFromWlrSurface(surface)) |xdg_surface| {
                            if (View.fromXdgSurface(xdg_surface)) |t| {
                                t.width_percent = @min(100, t.width_percent + 5);
                                t.workspace.arrange();
                            }
                        }
                    },
                    .reorder_left => if (server.seat.keyboard_state.focused_surface) |surface| {
                        if (wlr.XdgSurface.tryFromWlrSurface(surface)) |xdg_surface| {
                            if (View.fromXdgSurface(xdg_surface)) |t| {
                                t.workspace.reorderView(t, -1);
                            }
                        }
                    },
                    .reorder_right => if (server.seat.keyboard_state.focused_surface) |surface| {
                        if (wlr.XdgSurface.tryFromWlrSurface(surface)) |xdg_surface| {
                            if (View.fromXdgSurface(xdg_surface)) |t| {
                                t.workspace.reorderView(t, 1);
                            }
                        }
                    },
                    .switch_workspace => if (kb.workspace_index) |idx| {
                        server.switchToWorkspace(idx - 1);
                    },
                    .terminate => server.wl_server.terminate(),
                }
                return true;
            }
        }
        return false;
    }
};
