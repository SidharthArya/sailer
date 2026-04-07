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
const ConfigFile = @import("Config.zig");
const Config = ConfigFile.Config;
const Action = ConfigFile.Action;
const Keybinding = ConfigFile.Keybinding;
const layouts = @import("layouts/index.zig");
const Tiling = @import("layouts/Tiling.zig").Tiling;
const McpServer = @import("Mcp.zig").McpServer;
const IpcServer = @import("Ipc.zig").IpcServer;
const Screenshot = @import("Screenshot.zig").Screenshot;
const LayerSurface = @import("LayerShell.zig").LayerSurface;
const Menu = @import("Menu.zig").Menu;
const SessionLock = @import("SessionLock.zig").SessionLock;
const Bar = @import("Bar.zig").Bar;
const LayoutState = @import("LayoutState.zig");
const c = @import("c.zig").c;

pub const KeyMatch = struct {
    sym: xkb.Keysym,
    mods: wlr.Keyboard.ModifierMask,
};
pub const MatchResult = enum { none, partial, full };

fn handleSequenceTimeout(server: *Server) c_int {
    server.current_sequence.clearRetainingCapacity();
    return 0;
}

fn handleBarTimer(server: *Server) c_int {
    server.refreshBars();
    server.bar_timer.timerUpdate(@intCast(server.config.bar.refresh_interval)) catch {};
    return 0;
}

pub const PendingScratchpad = struct {
    search_id: []const u8,
    kb_ptr: usize,
};

pub const Server = struct {
    wl_server: *wl.Server,
    backend: *wlr.Backend,
    renderer: *wlr.Renderer,
    allocator: *wlr.Allocator,
    session: ?*wlr.Session = null,
    scene: *wlr.Scene,

    output_layout: *wlr.OutputLayout,
    scene_output_layout: *wlr.SceneOutputLayout,
    bg_tree: *wlr.SceneTree,
    bottom_tree: *wlr.SceneTree,
    window_tree: *wlr.SceneTree,
    top_tree: *wlr.SceneTree,
    overlay_tree: *wlr.SceneTree,


    xdg_shell: *wlr.XdgShell,

    xdg_activation: *wlr.XdgActivationV1,
    xdg_decoration: *wlr.XdgDecorationManagerV1,
    layer_shell: *wlr.LayerShellV1,
    foreign_toplevel_mgr: *wlr.ForeignToplevelManagerV1,
    session_lock_mgr: *wlr.SessionLockManagerV1,
    virtual_keyboard_mgr: *wlr.VirtualKeyboardManagerV1 = undefined,

    workspaces: [10]*Workspace = undefined,
    focused_workspace: *Workspace = undefined,

    seat: *wlr.Seat,
    keyboards: wl.list.Head(KeyboardDevice, .link) = undefined,
    outputs: wl.list.Head(@import("Output.zig").Output, .link) = undefined,
    toplevels: wl.list.Head(View.Toplevel, .link) = undefined,
    layer_surfaces: wl.list.Head(LayerSurface, .link) = undefined,

    cursor: *wlr.Cursor,
    cursor_mgr: *wlr.XcursorManager,
    shm: *wlr.Shm = undefined,

    config: Config = undefined,
    display_mode: @import("Config.zig").DisplayMode = .discrete,
    bg_color: [4]f32 = .{ 1.0, 0.0, 0.0, 1.0 },

    current_sequence: std.ArrayListUnmanaged(KeyMatch) = .{},
    sequence_timer: *wl.EventSource = undefined,
    bar_timer: *wl.EventSource = undefined,
    sigchld_source: *wl.EventSource = undefined,
    device_map: std.AutoHashMapUnmanaged(*wlr.InputDevice, void) = .{},

    last_mod_tap_ready: bool = false,
    last_mod_sym: ?xkb.Keysym = null,
    last_mod_timestamp: u32 = 0,
    pending_scratchpads: std.ArrayListUnmanaged(PendingScratchpad) = .{},

    cursor_mode: enum { passthrough, move, resize } = .passthrough,
    grabbed_view: ?*Toplevel = null,
    grab_x: f64 = 0,
    grab_y: f64 = 0,
    grab_box: wlr.Box = undefined,
    grab_percent: i32 = 50,
    resize_edges: wlr.Edges = .{},
    socket_name: []const u8 = "",
    socket_name_buf: [11]u8 = undefined,
    bar_height: i32 = 0,
    mcp: ?*McpServer = null,
    ipc: ?*IpcServer = null,
    active_menu: ?*Menu = null,
    active_session_lock: ?*SessionLock = null,
    listeners: Listeners,

    pub const Listeners = extern struct {
        new_output: wl.Listener(*wlr.Output),
        new_xdg_toplevel: wl.Listener(*wlr.XdgToplevel),
        new_xdg_popup: wl.Listener(*wlr.XdgPopup),
        new_layer_surface: wl.Listener(*wlr.LayerSurfaceV1),
        new_input: wl.Listener(*wlr.InputDevice),
        request_set_cursor: wl.Listener(*wlr.Seat.event.RequestSetCursor),
        request_set_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection),
        cursor_motion: wl.Listener(*wlr.Pointer.event.Motion),
        cursor_motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute),
        cursor_button: wl.Listener(*wlr.Pointer.event.Button),
        cursor_axis: wl.Listener(*wlr.Pointer.event.Axis),
        cursor_frame: wl.Listener(*wlr.Cursor),
        new_session_lock: wl.Listener(*wlr.SessionLockV1),
        new_virtual_keyboard: wl.Listener(*wlr.VirtualKeyboardV1),
    };



    pub fn init(server: *Server) !void {
        // Initialize listeners and fields with defaults explicitly to avoid garbage
        server.listeners.new_output = .init(Server.newOutput);
        server.listeners.new_xdg_toplevel = .init(Server.newXdgToplevel);
        server.listeners.new_xdg_popup = .init(Server.newXdgPopup);
        server.listeners.new_input = .init(Server.newInput);
        server.listeners.request_set_cursor = .init(Server.requestSetCursor);
        server.listeners.request_set_selection = .init(Server.requestSetSelection);
        server.listeners.new_layer_surface = .init(Server.newLayerSurface);
        server.listeners.cursor_motion = .init(Server.cursorMotion);
        server.listeners.cursor_motion_absolute = .init(Server.cursorMotionAbsolute);
        server.listeners.cursor_button = .init(Server.cursorButton);
        server.listeners.cursor_axis = .init(Server.cursorAxis);
        server.listeners.cursor_frame = .init(Server.cursorFrame);
        server.listeners.new_session_lock = .init(Server.newSessionLock);
        server.listeners.new_virtual_keyboard = .init(Server.newVirtualKeyboard);

        server.keyboards.init();
        server.outputs.init();
        server.toplevels.init();
        server.layer_surfaces.init();
        server.current_sequence = .{};
        server.session = null;
        server.cursor_mode = .passthrough;
        server.grabbed_view = null;
        server.display_mode = .discrete;
        server.socket_name = "";
        server.last_mod_tap_ready = false;
        server.pending_scratchpads = .{};
        server.last_mod_sym = null;
        server.last_mod_timestamp = 0;
        server.grab_x = 0;
        server.grab_y = 0;
        server.resize_edges = .{};
        server.bg_color = .{ 0.15, 0.17, 0.23, 1.0 }; // Elegant dark gray
        server.active_menu = null;
        server.active_session_lock = null;
        server.device_map = .{};

        server.keyboards.init();
        server.outputs.init();
        server.toplevels.init();
        server.layer_surfaces.init();

        const wl_server = try wl.Server.create();


        const loop = wl_server.getEventLoop();
        const backend = try wlr.Backend.autocreate(loop, @ptrCast(&server.session));
        const renderer = try wlr.Renderer.autocreate(backend);

        server.wl_server = wl_server;
        server.backend = backend;
        server.renderer = renderer;
        server.allocator = try wlr.Allocator.autocreate(backend, renderer);
        server.scene = try wlr.Scene.create();
        server.output_layout = try wlr.OutputLayout.create(wl_server);
        server.scene_output_layout = try server.scene.attachOutputLayout(server.output_layout);
        
        // Scene graph layers
        server.bg_tree = try server.scene.tree.createSceneTree();
        server.bottom_tree = try server.scene.tree.createSceneTree();
        server.window_tree = try server.scene.tree.createSceneTree();
        server.top_tree = try server.scene.tree.createSceneTree();
        server.overlay_tree = try server.scene.tree.createSceneTree();
        
        server.bg_tree.node.setEnabled(true);
        server.seat = try wlr.Seat.create(wl_server, "seat0");
        server.xdg_shell = try wlr.XdgShell.create(wl_server, 3);
        
        server.session_lock_mgr = try wlr.SessionLockManagerV1.create(wl_server);
        server.session_lock_mgr.events.new_lock.add(&server.listeners.new_session_lock);

        server.xdg_activation = try wlr.XdgActivationV1.create(wl_server);
        server.xdg_decoration = try wlr.XdgDecorationManagerV1.create(wl_server);
        server.cursor = try wlr.Cursor.create();
        server.cursor.attachOutputLayout(server.output_layout);
        server.cursor_mgr = try wlr.XcursorManager.create(null, 24);

        server.virtual_keyboard_mgr = try wlr.VirtualKeyboardManagerV1.create(wl_server);
        server.virtual_keyboard_mgr.events.new_virtual_keyboard.add(&server.listeners.new_virtual_keyboard);

        server.backend.events.new_output.add(&server.listeners.new_output);
        server.xdg_shell.events.new_toplevel.add(&server.listeners.new_xdg_toplevel);
        server.xdg_shell.events.new_popup.add(&server.listeners.new_xdg_popup);
        server.backend.events.new_input.add(&server.listeners.new_input);

        server.seat.events.request_set_cursor.add(&server.listeners.request_set_cursor);
        server.seat.events.request_set_selection.add(&server.listeners.request_set_selection);


        server.cursor.events.motion.add(&server.listeners.cursor_motion);
        server.cursor.events.motion_absolute.add(&server.listeners.cursor_motion_absolute);
        server.cursor.events.button.add(&server.listeners.cursor_button);
        server.cursor.events.axis.add(&server.listeners.cursor_axis);
        server.cursor.events.frame.add(&server.listeners.cursor_frame);

        server.sequence_timer = try loop.addTimer(*Server, handleSequenceTimeout, server);
        server.sequence_timer.timerUpdate(0) catch {};

        server.config = Config.load(std.heap.c_allocator) catch |err| blk: {
            std.log.err("failed to load config: {}, using default", .{err});
            break :blk Config.default(std.heap.c_allocator) catch unreachable;
        };
        // TODO: Watch config file for changes and hot-reload without restarting.
        server.display_mode = server.config.default_display_mode;
        server.bar_height = if (server.config.bar.enabled and server.config.bar.exclusive) server.config.bar.height else 0;

        server.bar_timer = try loop.addTimer(*Server, handleBarTimer, server);
        server.bar_timer.timerUpdate(1000) catch {}; // First update in 1s

        server.sigchld_source = try loop.addSignal(*Server, std.posix.SIG.CHLD, handleSigChld, server);

        try server.renderer.initServer(wl_server);
        _ = try wlr.Compositor.create(server.wl_server, 6, server.renderer);
        _ = try wlr.Subcompositor.create(server.wl_server);
        _ = try wlr.DataDeviceManager.create(server.wl_server);
        server.shm = try wlr.Shm.createWithRenderer(server.wl_server, 1, server.renderer);
        _ = try wlr.ScreencopyManagerV1.create(server.wl_server);
        _ = try wlr.XdgOutputManagerV1.create(server.wl_server, server.output_layout);
        _ = try wlr.ExportDmabufManagerV1.create(server.wl_server);
        _ = try wlr.LinuxDmabufV1.createWithRenderer(server.wl_server, 4, server.renderer);
        server.foreign_toplevel_mgr = try wlr.ForeignToplevelManagerV1.create(server.wl_server);
        
        _ = try wlr.PrimarySelectionDeviceManagerV1.create(server.wl_server);
        _ = try wlr.FractionalScaleManagerV1.create(server.wl_server, 1);
        _ = try wlr.Viewporter.create(server.wl_server);
        _ = try wlr.Presentation.create(server.wl_server, server.backend, 1);
        server.layer_shell = try wlr.LayerShellV1.create(wl_server, 4);
        server.layer_shell.events.new_surface.add(&server.listeners.new_layer_surface);

        // Initialize 10 workspaces
        for (&server.workspaces, 0..) |*ws, i| {
            var name_buf: [3]u8 = undefined;
            const name_str = std.fmt.bufPrint(&name_buf, "{d}", .{i + 1}) catch unreachable;
            // TODO: Allow workspace names to be configured (e.g. from config file).
            const name = try std.heap.c_allocator.dupe(u8, name_str);
            ws.* = try Workspace.init(server, name);
        }
        server.focused_workspace = server.workspaces[0];

        server.socket_name = try wl_server.addSocketAuto(&server.socket_name_buf);
        _ = c.setenv("WAYLAND_DISPLAY", server.socket_name.ptr, 1);
        _ = c.setenv("XDG_CURRENT_DESKTOP", "wlroots", 1);
        _ = c.setenv("XDG_SESSION_TYPE", "wayland", 1);

        // Synchronize environment with D-Bus and restart portal services
        // so they connect to *this* compositor's Wayland socket.
        // We do this asynchronously to avoid blocking the main server thread
        // particularly on a TTY where D-Bus/systemd might be unavailable or slow.
        // TODO: Make the portal service names configurable; not all distros use the same set.
        var portal_child = std.process.Child.init(&[_][]const u8{
            "/bin/sh", "-c",
            "dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE && " ++
                "systemctl --user stop xdg-desktop-portal-wlr xdg-desktop-portal-gnome xdg-desktop-portal && " ++
                "systemctl --user start xdg-desktop-portal-wlr && " ++
                "systemctl --user start xdg-desktop-portal",
        }, std.heap.c_allocator);

        var portal_env = std.process.getEnvMap(std.heap.c_allocator) catch null;
        if (portal_env) |*env| {
            defer env.deinit();
            env.put("WAYLAND_DISPLAY", server.socket_name) catch {};
            env.put("XDG_CURRENT_DESKTOP", "wlroots") catch {};
            env.put("XDG_SESSION_TYPE", "wayland") catch {};
            portal_child.env_map = env;
            _ = portal_child.spawn() catch |err| {
                std.log.err("Failed to spawn D-Bus/Portal synchronization script: {}", .{err});
            };
        } else {
            _ = portal_child.spawn() catch |err| {
                std.log.err("Failed to spawn D-Bus/Portal synchronization script: {}", .{err});
            };
        }

        std.log.info("Running compositor on WAYLAND_DISPLAY={s}", .{server.socket_name});

        server.mcp = McpServer.init(server, std.heap.c_allocator) catch |err| blk: {
            std.log.err("failed to initialize MCP server: {}", .{err});
            break :blk null;
        };
        // TODO: MCP server currently has no socket listener — it initializes but never accepts connections.
        //       Wire up a Unix socket or TCP listener so external tools can actually connect.

        server.ipc = blk: {
            const ipc = IpcServer.init(server, std.heap.c_allocator) catch |err| {
                std.log.err("failed to initialize IPC server: {}", .{err});
                break :blk null;
            };
            ipc.start() catch |err| {
                std.log.err("failed to start IPC server: {}", .{err});
                ipc.deinit();
                break :blk null;
            };
            break :blk ipc;
        };
    }

    pub fn getLayerTree(server: *Server, layer: anytype) *wlr.SceneTree {
        return switch (layer) {
            .background => server.bg_tree,
            .bottom => server.bottom_tree,
            .top => server.top_tree,
            .overlay => server.overlay_tree,
            else => unreachable,
        };
    }

    fn newLayerSurface(listener: *wl.Listener(*wlr.LayerSurfaceV1), wlr_layer_surface: *wlr.LayerSurfaceV1) void {
        const listeners: *Server.Listeners = @fieldParentPtr("new_layer_surface", listener);
        const server: *Server = @fieldParentPtr("listeners", listeners);

        _ = LayerSurface.create(server, wlr_layer_surface) catch |err| {
            std.log.err("failed to create layer surface: {}", .{err});
        };
    }

    pub fn handleNewXdgPopup(server: *Server, xdg_popup: *wlr.XdgPopup, parent_tree: *wlr.SceneTree) void {
        const xdg_surface = xdg_popup.base;
        const scene_tree = parent_tree.createSceneXdgSurface(xdg_surface) catch {
            std.log.err("failed to allocate xdg popup node", .{});
            return;
        };
        xdg_surface.data = scene_tree;
        _ = Popup.create(xdg_popup, scene_tree) catch {
            scene_tree.node.destroy();
            return;
        };
        _ = server;

    }

    pub fn warpCursorToOutput(server: *Server, wlr_output: *wlr.Output) void {
        var box: wlr.Box = undefined;
        server.output_layout.getBox(wlr_output, &box);
        server.cursor.warpAbsolute(null, @as(f64, @floatFromInt(box.x + @divTrunc(box.width, 2))), @as(f64, @floatFromInt(box.y + @divTrunc(box.height, 2))));
        server.processCursorMotion(0);
    }

    pub fn focusNextOutput(server: *Server) void {
        const current_wlr = server.output_layout.outputAt(server.cursor.x, server.cursor.y) orelse {
            if (server.outputs.link.next == &server.outputs.link) return;
            const first: *Output = @fieldParentPtr("link", server.outputs.link.next.?);
            server.warpCursorToOutput(first.wlr_output);
            return;
        };

        var it = server.outputs.link.next;
        while (it != &server.outputs.link) : (it = it.?.next) {
            const out: *Output = @fieldParentPtr("link", it.?);
            if (out.wlr_output == current_wlr) {
                const next_link = if (it.?.next != &server.outputs.link) it.?.next else server.outputs.link.next;
                const next_out: *Output = @fieldParentPtr("link", next_link.?);
                server.warpCursorToOutput(next_out.wlr_output);

                // Auto-focus the workspace/view on the new output
                if (server.viewAt(server.cursor.x, server.cursor.y)) |res| {
                    server.focusView(res.toplevel, res.surface);
                } else {
                    for (server.workspaces) |ws| {
                        if (ws.visible_on != null and ws.visible_on.?.wlr_output == next_out.wlr_output) {
                            server.focused_workspace = ws;
                            server.seat.keyboardNotifyClearFocus();
                            break;
                        }
                    }
                }
                return;
            }
        }
    }

    /// Inject text as key events into the focused surface using xkb keysym lookup.
    pub fn typeText(server: *Server, text: []const u8) void {
        const wlr_keyboard = server.seat.keyboard_state.keyboard orelse {
            std.log.warn("typeText: no keyboard attached to seat", .{});
            return;
        };
        const xkb_state = wlr_keyboard.xkb_state orelse {
            std.log.warn("typeText: no xkb state", .{});
            return;
        };
        const keymap = xkb_state.getKeymap();

        const now: u32 = @intCast(@divTrunc(std.time.milliTimestamp(), 1));

        var i: usize = 0;
        while (i < text.len) {
            // Handle \n escape sequence
            if (text[i] == '\\' and i + 1 < text.len and text[i + 1] == 'n') {
                // Send Return key (keycode 28 in evdev = xkb keycode 36)
                server.seat.keyboardNotifyKey(now, 28, .pressed);
                server.seat.keyboardNotifyKey(now, 28, .released);
                i += 2;
                continue;
            }

            const ch = text[i];
            i += 1;

            // Get keysym for this character using xkb C API
            const c_xkb = @import("c.zig").c;
            const sym_val = c_xkb.xkb_utf32_to_keysym(@as(u32, ch));
            if (sym_val == 0) continue;
            const sym: xkb.Keysym = @enumFromInt(sym_val);

            // Find a keycode that produces this keysym
            const min_keycode = keymap.minKeycode();
            const max_keycode = keymap.maxKeycode();
            var found_keycode: ?u32 = null;
            var found_shift = false;

            var kc = min_keycode;
            while (kc <= max_keycode) : (kc += 1) {
                const num_layouts = keymap.numLayoutsForKey(kc);
                var layout: u32 = 0;
                while (layout < num_layouts) : (layout += 1) {
                    const num_levels = keymap.numLevelsForKey(kc, layout);
                    var level: u32 = 0;
                    while (level < num_levels) : (level += 1) {
                        const syms = keymap.keyGetSymsByLevel(kc, layout, level);
                        for (syms) |s| {
                            if (@intFromEnum(s) == @intFromEnum(sym)) {
                                found_keycode = kc;
                                found_shift = (level == 1);
                                break;
                            }
                        }
                        if (found_keycode != null) break;
                    }
                    if (found_keycode != null) break;
                }
                if (found_keycode != null) break;
            }

            if (found_keycode) |kc_found| {
                // evdev keycode = xkb keycode - 8
                const evdev_kc = kc_found - 8;
                const shift_evdev: u32 = 42; // KEY_LEFTSHIFT

                if (found_shift) {
                    server.seat.keyboardNotifyKey(now, shift_evdev, .pressed);
                }
                server.seat.keyboardNotifyKey(now, evdev_kc, .pressed);
                server.seat.keyboardNotifyKey(now, evdev_kc, .released);
                if (found_shift) {
                    server.seat.keyboardNotifyKey(now, shift_evdev, .released);
                }
            }
        }
    }

    pub fn spawn(server: *Server, cmd: []const u8) void {        std.log.info("Compositor spawning command: {s}", .{cmd});

        // TODO: Consider using posix.fork + posix.execve directly to avoid shell injection risk
        //       when cmd comes from untrusted sources (e.g. MCP tool calls).
        var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", cmd }, std.heap.c_allocator);
        var env_map = std.process.getEnvMap(std.heap.c_allocator) catch |err| {
            std.log.err("Failed to get environment map for spawn: {}", .{err});
            return;
        };
        defer env_map.deinit();

        env_map.put("WAYLAND_DISPLAY", server.socket_name) catch |err| {
            std.log.err("Failed to set WAYLAND_DISPLAY in child env: {}", .{err});
        };

        child.env_map = &env_map;
        _ = child.spawn() catch |err| {
            std.log.err("Failed to spawn command '{s}': {}", .{ cmd, err });
            return;
        };
        std.log.info("Successfully spawned command '{s}' with WAYLAND_DISPLAY={s}", .{ cmd, server.socket_name });
    }

    pub fn updateLayout(server: *Server) void {

        // 1. Ensure all outputs are in the layout and have a workspace assigned
        var it = server.outputs.link.next;
        while (it != &server.outputs.link) : (it = it.?.next) {
            const output: *Output = @fieldParentPtr("link", it.?);

            // Re-add to layout (required after TTY resume)
            switch (server.display_mode) {
                .discrete, .spanned => {
                    _ = server.output_layout.addAuto(output.wlr_output) catch {};
                },
                .mirror => {
                    _ = server.output_layout.add(output.wlr_output, 0, 0) catch {};
                },
            }

            // Re-assign workspace if none is visible on this output
            var has_ws = false;
            for (server.workspaces) |ws| {
                if (ws.visible_on == output) {
                    has_ws = true;
                    break;
                }
            }
            if (!has_ws) {
                for (server.workspaces) |ws| {
                    if (ws.visible_on == null) {
                        ws.visible_on = output;
                        break;
                    }
                }
            }
        }

        // 2. Update workspace positions and visibility
        for (server.workspaces) |ws| {
            if (ws.visible_on) |output| {
                if (server.display_mode == .discrete) {
                    var box: wlr.Box = undefined;
                    server.output_layout.getBox(output.wlr_output, &box);
                    ws.scene_tree.node.setPosition(box.x, box.y);
                } else {
                    ws.scene_tree.node.setPosition(0, 0);
                }
                // In Spanned/Mirror, only the focused workspace should be enabled globally
                if (server.display_mode != .discrete) {
                    const visible = (ws == server.focused_workspace);
                    ws.scene_tree.node.setEnabled(visible);
                } else {
                    ws.scene_tree.node.setEnabled(true);
                }
                ws.arrange();
            } else {
                // HIDDEN WORKSPACE: Disable and move to off-screen limbo to avoid bleeding
                ws.scene_tree.node.setEnabled(false);
                ws.scene_tree.node.setPosition(-32000, -32000);
            }
        }

        // Re-configure layer surfaces
        var lit = server.layer_surfaces.link.next;
        while (lit != &server.layer_surfaces.link) : (lit = lit.?.next) {
            const layer: *LayerSurface = @fieldParentPtr("link", lit.?);
            layer.configure();
        }

        server.refreshBars();
    }

    pub fn refreshBars(server: *Server) void {
        var it = server.outputs.link.next;
        while (it != &server.outputs.link) : (it = it.?.next) {
            const out: *Output = @fieldParentPtr("link", it.?);
            if (out.bar) |bar| bar.update();
        }
    }

    fn handleSigChld(sig: i32, _: *Server) c_int {
        _ = sig;
        while (true) {
            var status: i32 = 0;
            // Use the low-level system call to avoid Zig's waitpid wrapper which panics on ECHILD (no more children)
            const rc = std.posix.system.waitpid(-1, &status, std.posix.W.NOHANG);
            if (rc <= 0) break;
        }
        return 0;
    }

    pub fn openMenu(self: *Server, toplevel: *Toplevel, gx: i32, gy: i32) void {
        if (self.active_menu) |menu| {
            menu.deinit();
        }
        self.active_menu = Menu.create(self, toplevel, gx, gy) catch |err| {
            std.log.err("Failed to open window menu: {}", .{err});
            return;
        };
    }

    pub fn closeMenu(self: *Server) void {
        if (self.active_menu) |menu| {
            menu.deinit();
            self.active_menu = null;
        }
    }

    pub fn reloadConfig(server: *Server) void {
        std.log.info("Reloading configuration...", .{});
        const new_config = @import("Config.zig").Config.load(std.heap.c_allocator) catch |err| {
            std.log.err("Failed to reload config: {}, keeping old config", .{err});
            return;
        };
        
        server.config = new_config;

        // Clear scratchpad associations as keybinding pointers are now invalid
        for (server.workspaces) |ws| {
            var it = ws.views.link.next;
            while (it != &ws.views.link) : (it = it.?.next) {
                const t: *Toplevel = @fieldParentPtr("link", it.?);
                t.scratchpad_id = 0;
            }
        }
        server.bar_height = if (server.config.bar.enabled and server.config.bar.exclusive) server.config.bar.height else 0;
        
        // Apply potentially changed settings like gaps
        server.updateLayout();
        server.refreshBars();
        std.log.info("Configuration reloaded successfully.", .{});
    }

    pub fn deinit(server: *Server) void {
        server.pending_scratchpads.deinit(std.heap.c_allocator);
        server.wl_server.destroyClients();

        server.listeners.new_input.link.remove();
        server.listeners.new_output.link.remove();
        server.listeners.new_xdg_toplevel.link.remove();
        server.listeners.new_xdg_popup.link.remove();
        server.listeners.request_set_cursor.link.remove();
        server.listeners.request_set_selection.link.remove();
        server.listeners.cursor_motion.link.remove();
        server.listeners.cursor_motion_absolute.link.remove();
        server.listeners.cursor_button.link.remove();
        server.listeners.cursor_axis.link.remove();
        server.listeners.cursor_frame.link.remove();
        server.listeners.new_layer_surface.link.remove();

        server.bar_timer.remove();
        server.sigchld_source.remove();

        // Stop IPC before destroying the event loop it registered with.
        if (server.ipc) |ipc| ipc.deinit();

        for (server.workspaces) |ws| ws.deinit();

        server.current_sequence.deinit(std.heap.c_allocator);
        server.backend.destroy();
        server.wl_server.destroy();
    }

    fn newOutput(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
        const listeners: *Server.Listeners = @fieldParentPtr("new_output", listener);
        const server: *Server = @fieldParentPtr("listeners", listeners);

        if (!wlr_output.initRender(server.allocator, server.renderer)) return;

        var state = wlr.Output.State.init();
        defer state.finish();

        state.setEnabled(true);
        if (wlr_output.preferredMode()) |mode| {
            state.setMode(mode);
        }
        if (!wlr_output.commitState(&state)) return;

        const output_ptr = Output.create(server, wlr_output) catch {
            wlr_output.destroy();
            return;
        };

        if (server.config.bar.enabled) {
            output_ptr.bar = Bar.create(server, output_ptr, server.config.font, server.config.bar) catch |err| blk: {
                std.log.err("Failed to create status bar for {s}: {}", .{ wlr_output.name, err });
                break :blk null;
            };
        }

        server.updateLayout();

        if (server.display_mode == .discrete) {
            // Assign this output to the first hidden workspace
            for (server.workspaces) |ws| {
                if (ws.visible_on == null) {
                    ws.setVisible(output_ptr);
                    break;
                }
            }
        }
    }

    fn newXdgToplevel(listener: *wl.Listener(*wlr.XdgToplevel), xdg_toplevel: *wlr.XdgToplevel) void {
        const listeners: *Server.Listeners = @fieldParentPtr("new_xdg_toplevel", listener);
        const server: *Server = @fieldParentPtr("listeners", listeners);

        // Assign new window to the workspace on the output under the cursor.
        const ws = blk: {
            if (server.display_mode == .discrete) {
                if (server.output_layout.outputAt(server.cursor.x, server.cursor.y)) |wlr_out| {
                    for (server.workspaces) |w| {
                        if (w.visible_on != null and w.visible_on.?.wlr_output == wlr_out) {
                            break :blk w;
                        }
                    }
                }
            }
            break :blk server.focused_workspace;
        };

        const toplevel = Toplevel.create(server, ws, xdg_toplevel) catch {
            return;
        };
        

        // Add to workspace list immediately so link is valid for remove() later
        ws.views.prepend(toplevel);
        ws.focus_history.prepend(toplevel);

        ws.arrange();
    }


    fn newXdgPopup(listener: *wl.Listener(*wlr.XdgPopup), xdg_popup: *wlr.XdgPopup) void {
        const parent = wlr.XdgSurface.tryFromWlrSurface(xdg_popup.parent.?) orelse return;
        const parent_tree = @as(?*wlr.SceneTree, @ptrCast(@alignCast(parent.data))) orelse return;

        const listeners: *Server.Listeners = @fieldParentPtr("new_xdg_popup", listener);
        const server: *Server = @fieldParentPtr("listeners", listeners);
        server.handleNewXdgPopup(xdg_popup, parent_tree);
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
                if (n.node.data) |data| {
                    const toplevel: *Toplevel = @ptrCast(@alignCast(data));
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

    fn newVirtualKeyboard(listener: *wl.Listener(*wlr.VirtualKeyboardV1), virtual_keyboard: *wlr.VirtualKeyboardV1) void {
        const listeners: *Server.Listeners = @fieldParentPtr("new_virtual_keyboard", listener);
        const server: *Server = @fieldParentPtr("listeners", listeners);

        const device = &virtual_keyboard.keyboard.base;

        if (server.device_map.get(device)) |_| {
            return;
        }
        server.device_map.put(std.heap.c_allocator, device, {}) catch {};

        KeyboardDevice.create(server, device) catch |err| {
            std.log.err("Failed to create keyboard for virtual device: {}", .{err});
        };
    }

    fn newSessionLock(listener: *wl.Listener(*wlr.SessionLockV1), wlr_lock: *wlr.SessionLockV1) void {
        const listeners: *Server.Listeners = @fieldParentPtr("new_session_lock", listener);
        const server: *Server = @fieldParentPtr("listeners", listeners);

        if (server.active_session_lock != null) {
            return;
        }

        server.active_session_lock = SessionLock.create(server, wlr_lock) catch |err| {
            std.log.err("Failed to create session lock: {}", .{err});
            wlr_lock.destroy();
            return;
        };
    }


    pub fn setOverlayEnabled(self: *Server, enabled: bool) void {
        const visible = !enabled;
        self.window_tree.node.setEnabled(visible);
        self.bottom_tree.node.setEnabled(visible);
        self.top_tree.node.setEnabled(visible);
        self.bg_tree.node.setEnabled(visible);
    }

    pub fn focusView(server: *Server, toplevel: *Toplevel, surface: *wlr.Surface) void {
        if (server.seat.keyboard_state.focused_surface) |previous_surface| {
            if (previous_surface == surface and !toplevel.hidden) return;
            if (wlr.XdgSurface.tryFromWlrSurface(previous_surface)) |xdg_surface| {
                if (xdg_surface.role_data.toplevel) |prev_t_wlr| {
                    _ = wlr.XdgToplevel.setActivated(prev_t_wlr, false);
                    if (View.fromXdgSurface(xdg_surface)) |prev_t| {
                        prev_t.updateBorderColor(&prev_t.inactive_border_color);
                        if (prev_t.foreign_toplevel) |handle| {
                            handle.setActivated(false);
                        }
                    }
                }
            }
        }

        server.focused_workspace = toplevel.workspace;
        toplevel.scene_tree.node.raiseToTop();
        toplevel.updateBorderColor(&toplevel.active_border_color);
        
        toplevel.focus_link.remove();
        toplevel.workspace.focus_history.prepend(toplevel);

        _ = wlr.XdgToplevel.setActivated(toplevel.xdg_toplevel, true);
        if (toplevel.foreign_toplevel) |handle| {
            handle.setActivated(true);
        }

        if (server.seat.keyboard_state.keyboard) |kbd| {
            wlr.Seat.keyboardNotifyEnter(server.seat, surface, kbd.keycodes[0..kbd.num_keycodes], &kbd.modifiers);
        } else {
            wlr.Seat.keyboardNotifyEnter(server.seat, surface, &[_]u32{}, &wlr.Keyboard.Modifiers{ .depressed = 0, .latched = 0, .locked = 0, .group = 0 });
        }

        const ws = toplevel.workspace;
        ws.arrange();
        ws.ensureViewVisible(toplevel);
        server.refreshBars();
    }

    pub fn focusLayer(server: *Server, layer: *LayerSurface) void {
        const surface = layer.wlr_layer_surface.surface;

        if (server.seat.keyboard_state.focused_surface) |previous_surface| {
            if (previous_surface == surface) return;
            if (wlr.XdgSurface.tryFromWlrSurface(previous_surface)) |xdg_surface| {
                if (xdg_surface.role_data.toplevel) |prev_t| {
                    _ = wlr.XdgToplevel.setActivated(prev_t, false);
                }
            }
        }

        if (server.seat.keyboard_state.keyboard) |kbd| {
            wlr.Seat.keyboardNotifyEnter(server.seat, surface, kbd.keycodes[0..kbd.num_keycodes], &kbd.modifiers);
        } else {
            wlr.Seat.keyboardNotifyEnter(server.seat, surface, &[_]u32{}, &wlr.Keyboard.Modifiers{ .depressed = 0, .latched = 0, .locked = 0, .group = 0 });
        }
    }

    pub fn focusTopWindow(server: *Server) void {
        const ws = server.focused_workspace;
        var it = ws.focus_history.link.next;
        while (it != &ws.focus_history.link) : (it = it.?.next) {
            const candidate: *Toplevel = @fieldParentPtr("focus_link", it.?);
            if (candidate.mapped and !candidate.hidden) {

                server.focusView(candidate, candidate.xdg_toplevel.base.surface);
                return;
            }
        }
        wlr.Seat.keyboardNotifyClearFocus(server.seat);
        server.refreshBars();
    }

    fn newInput(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
        const listeners: *Server.Listeners = @fieldParentPtr("new_input", listener);
        const server: *Server = @fieldParentPtr("listeners", listeners);

        std.debug.print("DEBUG: newInput device={*} type={}\n", .{device, device.type});

        if (server.device_map.get(device)) |_| {
            std.debug.print("DEBUG: device {*} already handled\n", .{device});
            return;
        }

        const name = if (device.name) |n| std.mem.span(n) else "unnamed";

        switch (device.type) {
            .keyboard => {
                // Deduplicate with VirtualKeyboard manager if possible
                if (device.getVirtualKeyboard() != null) {
                    std.debug.print("DEBUG: skipping virtual keyboard in newInput\n", .{});
                    return;
                }

                server.device_map.put(std.heap.c_allocator, device, {}) catch {};
                std.log.info("New keyboard {*}: {s}", .{ device, name });
                KeyboardDevice.create(server, device) catch |err| {
                    std.log.err("failed to create keyboard: {}", .{err});
                };
            },
            .pointer => {
                server.device_map.put(std.heap.c_allocator, device, {}) catch {};
                std.log.info("New pointer device {*}: {s}", .{ device, name });
                wlr.Cursor.attachInputDevice(server.cursor, device);
            },
            else => {
                std.log.info("New input device {*}: {s} (type={}) - UNHANDLED", .{ device, name, device.type });
            },
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
        const listeners: *Server.Listeners = @fieldParentPtr("request_set_cursor", listener);
        const server: *Server = @fieldParentPtr("listeners", listeners);

        if (event.seat_client == server.seat.pointer_state.focused_client)
            wlr.Cursor.setSurface(server.cursor, event.surface, event.hotspot_x, event.hotspot_y);
    }

    fn requestSetSelection(
        listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection),
        event: *wlr.Seat.event.RequestSetSelection,
    ) void {
        const listeners: *Server.Listeners = @fieldParentPtr("request_set_selection", listener);
        const server: *Server = @fieldParentPtr("listeners", listeners);

        wlr.Seat.setSelection(server.seat, event.source, event.serial);
    }

    fn cursorMotion(
        listener: *wl.Listener(*wlr.Pointer.event.Motion),
        event: *wlr.Pointer.event.Motion,
    ) void {
        const listeners: *Server.Listeners = @fieldParentPtr("cursor_motion", listener);
        const server: *Server = @fieldParentPtr("listeners", listeners);

        server.cursor.move(event.device, event.delta_x, event.delta_y);
        server.processCursorMotion(event.time_msec);
    }

    fn cursorMotionAbsolute(
        listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute),
        event: *wlr.Pointer.event.MotionAbsolute,
    ) void {
        const listeners: *Server.Listeners = @fieldParentPtr("cursor_motion_absolute", listener);
        const server: *Server = @fieldParentPtr("listeners", listeners);

        server.cursor.warpAbsolute(event.device, event.x, event.y);
        server.processCursorMotion(event.time_msec);
    }

    fn processCursorMotion(server: *Server, time_msec: u32) void {
        if (server.active_session_lock) |_| {
            var sx: f64 = undefined;
            var sy: f64 = undefined;
            if (server.scene.tree.node.at(server.cursor.x, server.cursor.y, &sx, &sy)) |node| {
                if (node.type != .buffer) return;
                const scene_buffer = wlr.SceneBuffer.fromNode(node);
                const scene_surface = wlr.SceneSurface.tryFromBuffer(scene_buffer) orelse return;
                wlr.Seat.pointerNotifyEnter(server.seat, scene_surface.surface, sx, sy);
                wlr.Seat.pointerNotifyMotion(server.seat, time_msec, sx, sy);
            }
            return;
        }

        // In discrete mode, update focused_workspace to follow the cursor across outputs.
        if (server.display_mode == .discrete) {
            if (server.output_layout.outputAt(server.cursor.x, server.cursor.y)) |wlr_out| {
                for (server.workspaces) |ws| {
                    if (ws.visible_on != null and ws.visible_on.?.wlr_output == wlr_out) {
                        if (server.focused_workspace != ws) {
                            server.focused_workspace = ws;
                            server.refreshBars();
                        }
                        break;
                    }
                }
            }
        }

        if (server.active_menu) |menu| {
            menu.handleMotion(server.cursor.x, server.cursor.y);
            return;
        }

        switch (server.cursor_mode) {
            .passthrough => {
                var sx: f64 = undefined;
                var sy: f64 = undefined;
                const node = server.scene.tree.node.at(server.cursor.x, server.cursor.y, &sx, &sy);
                
                if (node) |n| {
                    if (n.type == .buffer) {
                        const scene_buffer = wlr.SceneBuffer.fromNode(n);
                        if (wlr.SceneSurface.tryFromBuffer(scene_buffer)) |scene_surface| {
                            wlr.Seat.pointerNotifyEnter(server.seat, scene_surface.surface, sx, sy);
                            wlr.Seat.pointerNotifyMotion(server.seat, time_msec, sx, sy);
                            return;
                        }
                    }
                }

                // If we reach here, we hit nothing or something that isn't a surface (like a background rect)
                if (node == null or node.?.type == .rect) {
                    server.cursor.setXcursor(server.cursor_mgr, "default");
                    wlr.Seat.pointerClearFocus(server.seat);
                }
            },
            .move => {
                const toplevel = server.grabbed_view.?;
                var ws_box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
                if (toplevel.workspace.visible_on) |output| {
                    server.output_layout.getBox(output.wlr_output, &ws_box);
                }
                // In ribbon layout, scene tree is offset by scroll_offset_x.
                // We store unscrolled x in toplevel.x, so subtract scroll to get unscrolled position.
                const ws = toplevel.workspace;
                const scroll: i32 = if (ws.layout == .ribbon) ws.scroll_offset_x else 0;
                toplevel.x = @as(i32, @intFromFloat(server.cursor.x - server.grab_x)) - ws_box.x - scroll;
                toplevel.y = @as(i32, @intFromFloat(server.cursor.y - server.grab_y)) - ws_box.y;
                toplevel.scene_tree.node.setPosition(toplevel.x, toplevel.y);
            },
            .resize => {
                const toplevel = server.grabbed_view.?;
                if (!toplevel.is_floating) {
                    const box = server.focused_workspace.getUsableArea();
                    if (box.width > 0) {
                        const delta_x = if (server.resize_edges.right)
                            server.cursor.x - (@as(f64, @floatFromInt(server.grab_box.x + server.grab_box.width)) + server.grab_x)
                        else if (server.resize_edges.left)
                            (@as(f64, @floatFromInt(server.grab_box.x)) + server.grab_x) - server.cursor.x
                        else 0;

                        const percent_delta = @as(i32, @intFromFloat((delta_x / @as(f64, @floatFromInt(box.width))) * 100.0));
                        toplevel.width_percent = @max(10, @min(100, server.grab_percent + percent_delta));
                        server.focused_workspace.arrange();
                    }
                    return;
                }

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
                toplevel.updateLayout(new_width, new_height);
            },
        }
    }

    fn cursorButton(
        listener: *wl.Listener(*wlr.Pointer.event.Button),
        event: *wlr.Pointer.event.Button,
    ) void {
        const listeners: *Server.Listeners = @fieldParentPtr("cursor_button", listener);
        const server: *Server = @fieldParentPtr("listeners", listeners);

        if (server.active_session_lock) |_| {
            _ = server.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
            return;
        }

        if (server.active_menu) |menu| {
            if (event.state == .pressed) {
                if (menu.hitTest(server.cursor.x, server.cursor.y)) {
                    if (menu.handleButton(server.cursor.x, server.cursor.y)) |action| {
                        const target = menu.toplevel;
                        server.closeMenu();
                        server.executeAction(action, .{}, target);
                    }
                } else {
                    server.closeMenu();
                }
            }
            return;
        }

        if (event.state == .pressed and event.button == 0x110) { // BTN_LEFT
            if (server.output_layout.outputAt(server.cursor.x, server.cursor.y)) |wlr_out| {
                var it = server.outputs.link.next;
                while (it != &server.outputs.link) : (it = it.?.next) {
                    const output: *Output = @fieldParentPtr("link", it.?);

                    if (output.wlr_output == wlr_out) {
                        if (output.bar) |bar| {
                            if (bar.hitTestWorkspace(server.cursor.x, server.cursor.y)) |idx| {
                                server.switchToWorkspace(@intCast(idx));
                                return;
                            }
                        }
                        break;
                    }
                }
            }
        }

        var is_ctrl = false;
        if (wlr.Seat.getKeyboard(server.seat)) |kb| {
            const mods = wlr.Keyboard.getModifiers(kb);
            if (mods.logo) is_ctrl = true;
        }

        if (event.state == .released) {
            if (server.cursor_mode == .move) {
                if (server.grabbed_view) |toplevel| {
                    const ws = toplevel.workspace;
                    if (ws.layout == .ribbon) {
                        const area = ws.getUsableArea();
                        const drop_x = server.cursor.x - @as(f64, @floatFromInt(area.x + ws.scroll_offset_x));

                        toplevel.link.remove();
                        var placed = false;
                        var it = ws.views.link.prev;
                        while (it != &ws.views.link) : (it = it.?.prev) {
                            const view: *View.Toplevel = @fieldParentPtr("link", it.?);
                            const target_width: i32 = if (area.width > 0) @divTrunc(area.width * view.width_percent, 100) else 100;
                            const center_x = view.x + @divTrunc(target_width, 2);

                            if (drop_x < @as(f64, @floatFromInt(center_x))) {
                                it.?.insert(&toplevel.link);
                                placed = true;
                                break;
                            }
                        }
                        if (!placed) ws.views.link.insert(&toplevel.link);
                        server.grabbed_view = null;
                        ws.arrange();
                    }
                }
            }
            server.cursor_mode = .passthrough;
        } else if (server.viewAt(server.cursor.x, server.cursor.y)) |res| {
            server.focusView(res.toplevel, res.surface);

            if (is_ctrl) {
                server.grabbed_view = res.toplevel;
                if (event.button == 0x110) { // BTN_LEFT
                    server.cursor_mode = .move;
                    // In ribbon layout the scene tree is offset by scroll_offset_x,
                    // so the window's screen x = toplevel.x + scroll_offset_x
                    const ws = res.toplevel.workspace;
                    const scroll: i32 = if (ws.layout == .ribbon) ws.scroll_offset_x else 0;
                    server.grab_x = server.cursor.x - @as(f64, @floatFromInt(res.toplevel.x + scroll));
                    server.grab_y = server.cursor.y - @as(f64, @floatFromInt(res.toplevel.y));
                    return; // Intercept
                } else if (event.button == 0x111) { // BTN_RIGHT
                    server.cursor_mode = .resize;
                    
                    const box = res.toplevel.xdg_toplevel.base.geometry;
                    const center_x = @as(f64, @floatFromInt(res.toplevel.x + box.x + @divTrunc(box.width, 2)));
                    const center_y = @as(f64, @floatFromInt(res.toplevel.y + box.y + @divTrunc(box.height, 2)));

                    server.resize_edges = .{};
                    if (server.cursor.x < center_x) server.resize_edges.left = true else server.resize_edges.right = true;
                    if (server.cursor.y < center_y) server.resize_edges.top = true else server.resize_edges.bottom = true;

                    const border_x = res.toplevel.x + box.x + if (server.resize_edges.right) box.width else 0;
                    const border_y = res.toplevel.y + box.y + if (server.resize_edges.bottom) box.height else 0;

                    server.grab_x = server.cursor.x - @as(f64, @floatFromInt(border_x));
                    server.grab_y = server.cursor.y - @as(f64, @floatFromInt(border_y));

                    server.grab_box = box;
                    server.grab_box.x += res.toplevel.x;
                    server.grab_box.y += res.toplevel.y;

                    server.grab_percent = res.toplevel.width_percent;
                    return; // Intercept
                }
            }
        } else if (server.output_layout.outputAt(server.cursor.x, server.cursor.y)) |wlr_out| {
            for (server.workspaces) |ws| {
                if (ws.visible_on != null and ws.visible_on.?.wlr_output == wlr_out) {
                    server.focused_workspace = ws;
                    _ = server.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
                    break;
                }
            }
        }

        // Only explicitly notify to client if we didn't return early to consume the event
        _ = server.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
    }

    fn cursorAxis(
        listener: *wl.Listener(*wlr.Pointer.event.Axis),
        event: *wlr.Pointer.event.Axis,
    ) void {
        const listeners: *Server.Listeners = @fieldParentPtr("cursor_axis", listener);
        const server: *Server = @fieldParentPtr("listeners", listeners);

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

    fn cursorFrame(
        listener: *wl.Listener(*wlr.Cursor),
        _: *wlr.Cursor,
    ) void {
        const listeners: *Server.Listeners = @fieldParentPtr("cursor_frame", listener);
        const server: *Server = @fieldParentPtr("listeners", listeners);
        wlr.Seat.pointerNotifyFrame(server.seat);
    }

    pub fn switchToWorkspace(server: *Server, index: u32) void {
        if (index >= server.workspaces.len) return;
        const target_ws = server.workspaces[index];

        // In discrete mode, switch the workspace on the output under the cursor,
        // not necessarily the keyboard-focused output.
        const current_ws = blk: {
            if (server.display_mode == .discrete) {
                if (server.output_layout.outputAt(server.cursor.x, server.cursor.y)) |wlr_out| {
                    for (server.workspaces) |ws| {
                        if (ws.visible_on != null and ws.visible_on.?.wlr_output == wlr_out) {
                            break :blk ws;
                        }
                    }
                }
            }
            break :blk server.focused_workspace;
        };

        if (current_ws == target_ws) return;

        const focused_output = current_ws.visible_on;

        if (target_ws.visible_on) |other_output| {
            // Target is already visible on another output — swap
            current_ws.setVisible(other_output);
            target_ws.setVisible(focused_output);
        } else if (focused_output) |output| {
            // Target is currently invisible. Clear old visibility to ensure mutual exclusivity.
            current_ws.setVisible(null);
            target_ws.setVisible(output);
        } else {
            // If the current monitor didn't have a workspace (rare), just force it
            if (server.output_layout.outputAt(server.cursor.x, server.cursor.y)) |wlr_out| {
                var oit = server.outputs.link.next;
                while (oit != &server.outputs.link) : (oit = oit.?.next) {
                    const out: *Output = @fieldParentPtr("link", oit.?);
                    if (out.wlr_output == wlr_out) {
                        target_ws.setVisible(out);
                        break;
                    }
                }
            }
        }
        
        // Ensure no other workspace thinks it's on the target's new output
        if (target_ws.visible_on) |new_out| {
            for (server.workspaces) |ws| {
                if (ws != target_ws and ws.visible_on == new_out) {
                    ws.visible_on = null;
                }
            }
        }

        // Move sticky windows from current to target
        var it = current_ws.views.link.next;
        while (it != &current_ws.views.link) {
            const next = it.?.next;
            const toplevel: *Toplevel = @fieldParentPtr("link", it.?);
            if (toplevel.sticky) {
                toplevel.link.remove();
                target_ws.views.prepend(toplevel);
                toplevel.workspace = target_ws;
                toplevel.scene_tree.node.reparent(target_ws.scene_tree);
            }
            it = next;
        }

        server.focused_workspace = target_ws;
        server.updateLayout();

        // Focus topmost window in new workspace
        if (target_ws.views.link.next != &target_ws.views.link) {
            const head = target_ws.views.link.next.?;
            const toplevel: *Toplevel = @fieldParentPtr("link", head);
            server.focusView(toplevel, toplevel.xdg_toplevel.base.surface);
        } else {
            wlr.Seat.keyboardNotifyClearFocus(server.seat);
        }
        server.refreshBars();
    }

    fn executeAction(server: *Server, action: Action, kb: Keybinding, target: ?*Toplevel) void {
        const toplevel = target orelse if (server.seat.keyboard_state.focused_surface) |surface| blk: {
            if (wlr.XdgSurface.tryFromWlrSurface(surface)) |xdg_surface| {
                break :blk View.fromXdgSurface(xdg_surface);
            }
            break :blk null;
        } else null;

        switch (action) {
            .toggle_layout => {
                const ws = server.focused_workspace;
                const outgoing = ws.layout;
                const new_layout: @import("layouts/index.zig").Layout = if (ws.layout == .ribbon)
                    .{ .tiling = .{} }
                else
                    .{ .ribbon = .{} };
                if (std.meta.activeTag(outgoing) != std.meta.activeTag(new_layout)) {
                    LayoutState.saveState(std.heap.c_allocator, ws, outgoing);
                    ws.layout = new_layout;
                    LayoutState.restoreState(std.heap.c_allocator, ws, new_layout);
                }
                ws.arrange();
            },
            .toggle_floating_layout => {
                const ws = server.focused_workspace;
                const outgoing = ws.layout;
                if (ws.layout == .floating) {
                    const new_layout = ws.prev_layout orelse @import("layouts/index.zig").Layout{ .ribbon = .{} };
                    ws.prev_layout = null;
                    ws.scroll_offset_x = 0;
                    LayoutState.saveState(std.heap.c_allocator, ws, outgoing);
                    ws.layout = new_layout;
                    LayoutState.restoreState(std.heap.c_allocator, ws, new_layout);
                } else {
                    ws.prev_layout = ws.layout;
                    const new_layout = @import("layouts/index.zig").Layout{ .floating = .{} };
                    const box = ws.getUsableArea();
                    var offset: i32 = 0;
                    var it = ws.views.link.next;
                    while (it != &ws.views.link) : (it = it.?.next) {
                        const view: *View.Toplevel = @fieldParentPtr("link", it.?);
                        if (!view.mapped) continue;
                        if (view.x == 0 and view.y == 0) {
                            view.x = box.x + offset;
                            view.y = box.y + offset;
                            offset += 30;
                        }
                    }
                    LayoutState.saveState(std.heap.c_allocator, ws, outgoing);
                    ws.layout = new_layout;
                    LayoutState.restoreState(std.heap.c_allocator, ws, new_layout);
                }
                ws.arrange();
            },
            .toggle_tiling_layout => {
                const ws = server.focused_workspace;
                const outgoing = ws.layout;
                if (ws.layout == .tiling) {
                    const new_layout = ws.prev_layout orelse @import("layouts/index.zig").Layout{ .ribbon = .{} };
                    ws.prev_layout = null;
                    ws.scroll_offset_x = 0;
                    LayoutState.saveState(std.heap.c_allocator, ws, outgoing);
                    ws.layout = new_layout;
                    LayoutState.restoreState(std.heap.c_allocator, ws, new_layout);
                } else {
                    ws.prev_layout = ws.layout;
                    const new_layout = @import("layouts/index.zig").Layout{ .tiling = .{} };
                    LayoutState.saveState(std.heap.c_allocator, ws, outgoing);
                    ws.layout = new_layout;
                    LayoutState.restoreState(std.heap.c_allocator, ws, new_layout);
                }
                ws.arrange();
            },
            .toggle_ribbon_layout => {
                const ws = server.focused_workspace;
                const outgoing = ws.layout;
                if (ws.layout == .ribbon) {
                    const new_layout = ws.prev_layout orelse @import("layouts/index.zig").Layout{ .tiling = .{} };
                    ws.prev_layout = null;
                    LayoutState.saveState(std.heap.c_allocator, ws, outgoing);
                    ws.layout = new_layout;
                    LayoutState.restoreState(std.heap.c_allocator, ws, new_layout);
                } else {
                    ws.prev_layout = ws.layout;
                    const new_layout = @import("layouts/index.zig").Layout{ .ribbon = .{} };
                    ws.scroll_offset_x = 0;
                    LayoutState.saveState(std.heap.c_allocator, ws, outgoing);
                    ws.layout = new_layout;
                    LayoutState.restoreState(std.heap.c_allocator, ws, new_layout);
                }
                ws.arrange();
            },
            .smart_view => {
                const ws = server.focused_workspace;
                const outgoing = ws.layout;
                const new_layout: @import("layouts/index.zig").Layout = if (ws.layout == .smart_view)
                    .{ .ribbon = .{} }
                else
                    .{ .smart_view = .{} };
                if (std.meta.activeTag(outgoing) != std.meta.activeTag(new_layout)) {
                    LayoutState.saveState(std.heap.c_allocator, ws, outgoing);
                    ws.layout = new_layout;
                    LayoutState.restoreState(std.heap.c_allocator, ws, new_layout);
                }
                ws.arrange();
            },
            .terminate => {
                server.wl_server.terminate();
            },
            .spawn => if (kb.command) |cmd| {
                server.spawn(cmd);
            },
            .focus_left => server.focused_workspace.focusRelative(-1),
            .focus_right => server.focused_workspace.focusRelative(1),
            .resize_shrink => if (toplevel) |t| t.workspace.resizeView(t, -10),
            .resize_expand => if (toplevel) |t| t.workspace.resizeView(t, 10),
            .move_left => if (toplevel) |t| t.workspace.moveView(t, -1),
            .move_right => if (toplevel) |t| t.workspace.moveView(t, 1),
            .move_up => if (toplevel) |t| t.workspace.moveView(t, -2),
            .move_down => if (toplevel) |t| t.workspace.moveView(t, 2),
            .reorder_left => if (toplevel) |t| t.workspace.reorderView(t, -1),
            .reorder_right => if (toplevel) |t| t.workspace.reorderView(t, 1),
            .switch_workspace => if (kb.workspace_index) |idx| {
                server.switchToWorkspace(idx - 1);
            },
            .get_screenshot, .screenshot => server.takeScreenshot(),
            .set_display_mode => if (kb.display_mode) |mode| {
                server.display_mode = mode;
                server.updateLayout();
            },
            .cycle_display_mode => {
                server.display_mode = switch (server.display_mode) {
                    .discrete => .spanned,
                    .spanned => .mirror,
                    .mirror => .discrete,
                };
                server.updateLayout();
            },
            .focus_output => server.focusNextOutput(),
            .toggle_locked, .toggle_sticky, .toggle_private, .toggle_marked, .toggle_hidden, .toggle_urgent, .close, .toggle_maximize, .toggle_fullscreen, .toggle_floating => if (toplevel) |t| {
                switch (action) {
                    .toggle_locked => t.locked = !t.locked,
                    .toggle_sticky => t.sticky = !t.sticky,
                    .toggle_private => t.private = !t.private,
                    .toggle_marked => t.marked = !t.marked,
                    .toggle_hidden => t.hidden = !t.hidden,
                    .toggle_urgent => t.urgent = !t.urgent,
                    .close => t.close(),
                    .toggle_maximize => t.setMaximized(!t.is_maximized),
                    .toggle_fullscreen => t.setFullscreen(!t.is_fullscreen),
                    .toggle_floating => {
                        // In floating layout mode, all windows are already floating — no-op
                        if (t.workspace.layout != .floating) {
                            t.is_floating = !t.is_floating;
                            if (t.is_floating) {
                                t.scene_tree.node.raiseToTop();
                            }
                        }
                    },
                    else => unreachable,
                }
                t.workspace.arrange();
            },
            .toggle_scratchpad => {
                const search_id = kb.app_id orelse kb.command orelse return;
                const kb_ptr = @intFromPtr(&kb);
                var found: ?*Toplevel = null;

                // 1. Search for a window already claimed by this specific keybinding
                for (server.workspaces) |ws| {
                    var it = ws.views.link.next;
                    while (it != &ws.views.link) : (it = it.?.next) {
                        const t: *Toplevel = @fieldParentPtr("link", it.?);
                        if (t.scratchpad_id == kb_ptr) {
                            found = t;
                            break;
                        }
                    }
                    if (found != null) break;
                }

                if (found) |t| {
                    const current_ws = server.focused_workspace;
                    std.log.debug("toggle_scratchpad: found existing window for kb_ptr 0x{x} on workspace '{s}'", .{ 
                        kb_ptr, t.workspace.name 
                    });

                    if (t.workspace != current_ws) {
                        std.log.debug("toggle_scratchpad: moving to current workspace '{s}'", .{ current_ws.name });
                        t.link.remove();
                        current_ws.views.append(t);
                        t.workspace = current_ws;
                        t.scene_tree.node.reparent(current_ws.scene_tree);
                    }

                    t.hidden = !t.hidden;
                    std.log.debug("toggle_scratchpad: toggled hidden to: {}", .{ t.hidden });

                    if (!t.hidden) {
                        server.focusView(t, t.xdg_toplevel.base.surface);
                    } else {
                        // If we just hid the focused window, clear focus
                        if (server.seat.keyboard_state.focused_surface == t.xdg_toplevel.base.surface) {
                            std.log.debug("toggle_scratchpad: clearing focus from hidden scratchpad", .{});
                            wlr.Seat.keyboardNotifyClearFocus(server.seat);
                        }
                    }
                    current_ws.arrange();
                } else if (kb.command) |cmd| {
                    std.log.info("toggle_scratchpad: not found, spawning: {s}", .{ cmd });
                    // Register pending scratchpad before spawning
                    server.pending_scratchpads.append(std.heap.c_allocator, .{ 
                        .search_id = search_id, 
                        .kb_ptr = kb_ptr 
                    }) catch |err| {
                        std.log.err("Failed to register pending scratchpad: {}", .{err});
                    };
                    server.spawn(cmd);
                }
            },
            .reload_config => server.reloadConfig(),
        }
    }

    fn matchKey(kb: anytype, sym: xkb.Keysym, mods: wlr.Keyboard.ModifierMask, is_sequence_step: bool) bool {
        const kb_sym = kb.getKeysym();
        const kb_mods = kb.getModifiers();

        const s = @intFromEnum(sym);
        const k = @intFromEnum(kb_sym);

        var sym_match = (s == k);
        if (!sym_match) {
            // Case-insensitive match for a-z/A-Z
            if (s >= 'A' and s <= 'Z' and k >= 'a' and k <= 'z') {
                if (s - 'A' == k - 'a') sym_match = true;
            } else if (s >= 'a' and s <= 'z' and k >= 'A' and k <= 'Z') {
                if (s - 'a' == k - 'A') sym_match = true;
            }
        }

        if (sym_match) {
            const mod_match = mods.ctrl == kb_mods.ctrl and
                mods.shift == kb_mods.shift and
                mods.alt == kb_mods.alt and
                mods.logo == kb_mods.logo;

            if (mod_match) {
                std.log.debug("Key match SUCCESS: sym={}, mods={} (is_seq={})", .{ s, mods, is_sequence_step });
                return true;
            } else {
                std.log.debug("Sym match but modifiers mismatch: expected (ctrl={}, shift={}, alt={}, logo={}), got (ctrl={}, shift={}, alt={}, logo={})", .{
                    kb_mods.ctrl, kb_mods.shift, kb_mods.alt, kb_mods.logo,
                    mods.ctrl,    mods.shift,    mods.alt,    mods.logo,
                });
            }
        }

        return false;
    }

    pub fn handleKeybind(server: *Server, syms: []const xkb.Keysym, mods: wlr.Keyboard.ModifierMask) bool {
        // We try to match each sym. If any sym results in a partial or full match, we keep that state.
        // We only append to the sequence ONCE per event.
        // Usually, we just pick the first sym for now to keep it simple but correct.
        if (syms.len == 0) return false;
        const key = syms[0];

        server.current_sequence.append(std.heap.c_allocator, .{ .sym = key, .mods = mods }) catch return false;
        server.sequence_timer.timerUpdate(1000) catch {};

        const current = server.current_sequence.items;
        std.log.debug("Check bind: sym={}, mods={}, sequence_len={}", .{ key, mods, current.len });

        var any_match = false;
        var full_match = false;

        for (server.config.keybindings) |kb| {
            if (kb.sequence) |seq| {
                if (current.len <= seq.len) {
                    var match = true;
                    for (current, 0..) |step, i| {
                        if (!matchKey(seq[i], step.sym, step.mods, true)) {
                            match = false;
                            break;
                        }
                    }
                    if (match) {
                        any_match = true;
                        if (current.len == seq.len) {
                            std.log.debug("Full sequence match found!", .{});
                        if (kb.action) |action| {
                            server.executeAction(action, kb, null);
                        }
                            full_match = true;
                            break;
                        } else {
                            std.log.debug("Partial sequence match (prefix).", .{});
                        }
                    }
                }
            } else {
                if (current.len == 1 and matchKey(kb, key, mods, false)) {
                    std.log.debug("Single keybind match found!", .{});
                    if (kb.action) |action| {
                        server.executeAction(action, kb, null);
                    }
                    any_match = true;
                    full_match = true;
                    break;
                }
            }
        }

        if (full_match) {
            server.current_sequence.clearRetainingCapacity();
            server.sequence_timer.timerUpdate(0) catch {};
            return true;
        }

        if (any_match) {
            return true;
        }

        // If no match was found, but it could be a prefix of some other sequence, keep it.
        // Otherwise, if this was the first key and no match/prefix, clear and let it through.
        if (current.len == 1) {
            std.log.debug("No match for first key in sequence, clearing.", .{});
            server.current_sequence.clearRetainingCapacity();
            server.sequence_timer.timerUpdate(0) catch {};
            return false;
        }

        std.log.debug("Sequence mismatch mid-flight, clearing.", .{});
        server.current_sequence.clearRetainingCapacity();
        server.sequence_timer.timerUpdate(0) catch {};
        return false;
    }

    fn takeScreenshot(server: *Server) void {
        const timestamp = std.time.timestamp();
        var name_buf: [128]u8 = undefined;
        const filename = std.fmt.bufPrint(&name_buf, "/tmp/sailer-screenshot-{d}.jpg", .{timestamp}) catch return;

        // Use grim which speaks wlr-screencopy — the compositor already exposes that protocol.
        var child = std.process.Child.init(
            &[_][]const u8{ "grim", filename },
            std.heap.c_allocator,
        );
        var env_map = std.process.getEnvMap(std.heap.c_allocator) catch return;
        defer env_map.deinit();
        env_map.put("WAYLAND_DISPLAY", server.socket_name) catch {};
        child.env_map = &env_map;
        _ = child.spawn() catch |err| {
            std.log.err("Failed to spawn grim: {}", .{err});
            return;
        };
        std.log.info("Screenshot saved to {s}", .{filename});
    }
};
