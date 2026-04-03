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
const Config = @import("Config.zig").Config;
const Keybinding = @import("Config.zig").Keybinding;
const layouts = @import("layouts/index.zig");
const Tiling = @import("layouts/Tiling.zig").Tiling;
const TilingNode = @import("layouts/Tiling.zig").TilingNode;
const McpServer = @import("Mcp.zig").McpServer;
const Screenshot = @import("Screenshot.zig").Screenshot;
const LayerSurface = @import("LayerShell.zig").LayerSurface;

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
    server.bar_timer.timerUpdate(10000) catch {}; // Every 10 seconds
    return 0;
}

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
    top_tree: *wlr.SceneTree,
    overlay_tree: *wlr.SceneTree,
    shm: *wlr.Shm,
    new_output: wl.Listener(*wlr.Output) = .init(Server.newOutput),

    xdg_shell: *wlr.XdgShell,
    xdg_activation: *wlr.XdgActivationV1,
    xdg_decoration: *wlr.XdgDecorationManagerV1,
    new_xdg_toplevel: wl.Listener(*wlr.XdgToplevel) = .init(Server.newXdgToplevel),
    new_xdg_popup: wl.Listener(*wlr.XdgPopup) = .init(Server.newXdgPopup),
    
    layer_shell: *wlr.LayerShellV1,
    new_layer_surface: wl.Listener(*wlr.LayerSurfaceV1) = .init(Server.newLayerSurface),

    workspaces: [10]*Workspace = undefined,
    focused_workspace: *Workspace = undefined,

    seat: *wlr.Seat,
    new_input: wl.Listener(*wlr.InputDevice) = .init(Server.newInput),
    request_set_cursor: wl.Listener(*wlr.Seat.event.RequestSetCursor) = .init(Server.requestSetCursor),
    request_set_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) = .init(Server.requestSetSelection),
    keyboards: wl.list.Head(KeyboardDevice, .link) = undefined,
    outputs: wl.list.Head(@import("Output.zig").Output, .link) = undefined,
    toplevels: wl.list.Head(View.Toplevel, .link) = undefined,
    layer_surfaces: wl.list.Head(LayerSurface, .link) = undefined,

    cursor: *wlr.Cursor,
    cursor_mgr: *wlr.XcursorManager,
    cursor_motion: wl.Listener(*wlr.Pointer.event.Motion) = .init(Server.cursorMotion),
    cursor_motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = .init(Server.cursorMotionAbsolute),
    cursor_button: wl.Listener(*wlr.Pointer.event.Button) = .init(Server.cursorButton),
    cursor_axis: wl.Listener(*wlr.Pointer.event.Axis) = .init(Server.cursorAxis),
    cursor_frame: wl.Listener(*wlr.Cursor) = .init(Server.cursorFrame),

    config: std.json.Parsed(Config) = undefined,
    display_mode: @import("Config.zig").DisplayMode = .discrete,
    bg_color: [4]f32 = .{ 1.0, 0.0, 0.0, 1.0 },

    current_sequence: std.ArrayListUnmanaged(KeyMatch) = .{},
    sequence_timer: *wl.EventSource = undefined,
    bar_timer: *wl.EventSource = undefined,

    // For modifier tap detection
    last_mod_tap_ready: bool = false,
    last_mod_sym: ?xkb.Keysym = null,
    last_mod_timestamp: u32 = 0,

    cursor_mode: enum { passthrough, move, resize } = .passthrough,
    grabbed_view: ?*Toplevel = null,
    grab_x: f64 = 0,
    grab_y: f64 = 0,
    grab_box: wlr.Box = undefined,
    resize_edges: wlr.Edges = .{},
    socket_name: []const u8 = "",
    socket_name_buf: [11]u8 = undefined,
    bar_height: i32 = 24,
    mcp: ?*McpServer = null,

    pub fn init(server: *Server) !void {
        // Initialize listeners and fields with defaults explicitly to avoid garbage
        server.new_output = .init(Server.newOutput);
        server.new_xdg_toplevel = .init(Server.newXdgToplevel);
        server.new_xdg_popup = .init(Server.newXdgPopup);
        server.new_input = .init(Server.newInput);
        server.request_set_cursor = .init(Server.requestSetCursor);
        server.request_set_selection = .init(Server.requestSetSelection);
        server.new_layer_surface = .init(Server.newLayerSurface);
        server.cursor_motion = .init(Server.cursorMotion);
        server.cursor_motion_absolute = .init(Server.cursorMotionAbsolute);
        server.cursor_button = .init(Server.cursorButton);
        server.cursor_axis = .init(Server.cursorAxis);
        server.cursor_frame = .init(Server.cursorFrame);
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
        server.last_mod_sym = null;
        server.last_mod_timestamp = 0;
        server.grab_x = 0;
        server.grab_y = 0;
        server.resize_edges = .{};
        server.bg_color = .{ 0.15, 0.17, 0.23, 1.0 }; // Elegant dark gray

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
        server.top_tree = try server.scene.tree.createSceneTree();
        server.overlay_tree = try server.scene.tree.createSceneTree();
        
        server.bg_tree.node.setEnabled(true);
        server.seat = try wlr.Seat.create(wl_server, "seat0");
        server.xdg_shell = try wlr.XdgShell.create(wl_server, 3);
        server.xdg_activation = try wlr.XdgActivationV1.create(wl_server);
        server.xdg_decoration = try wlr.XdgDecorationManagerV1.create(wl_server);
        server.cursor = try wlr.Cursor.create();
        server.cursor.attachOutputLayout(server.output_layout);
        server.cursor_mgr = try wlr.XcursorManager.create(null, 24);
        
        server.layer_shell = try wlr.LayerShellV1.create(wl_server, 4);

        server.backend.events.new_output.add(&server.new_output);
        server.xdg_shell.events.new_toplevel.add(&server.new_xdg_toplevel);
        server.xdg_shell.events.new_popup.add(&server.new_xdg_popup);
        server.backend.events.new_input.add(&server.new_input);
        server.seat.events.request_set_cursor.add(&server.request_set_cursor);
        server.seat.events.request_set_selection.add(&server.request_set_selection);
        server.layer_shell.events.new_surface.add(&server.new_layer_surface);

        server.cursor.events.motion.add(&server.cursor_motion);
        server.cursor.events.motion_absolute.add(&server.cursor_motion_absolute);
        server.cursor.events.button.add(&server.cursor_button);
        server.cursor.events.axis.add(&server.cursor_axis);
        server.cursor.events.frame.add(&server.cursor_frame);

        server.sequence_timer = try loop.addTimer(*Server, handleSequenceTimeout, server);
        server.sequence_timer.timerUpdate(0) catch {};

        server.bar_timer = try loop.addTimer(*Server, handleBarTimer, server);
        server.bar_timer.timerUpdate(1000) catch {}; // First update in 1s

        try server.renderer.initServer(wl_server);
        _ = try wlr.Compositor.create(server.wl_server, 6, server.renderer);
        _ = try wlr.Subcompositor.create(server.wl_server);
        _ = try wlr.DataDeviceManager.create(server.wl_server);
        server.shm = try wlr.Shm.createWithRenderer(server.wl_server, 1, server.renderer);
        _ = try wlr.ScreencopyManagerV1.create(server.wl_server);
        _ = try wlr.XdgOutputManagerV1.create(server.wl_server, server.output_layout);

        // Initialize 10 workspaces
        for (&server.workspaces, 0..) |*ws, i| {
            var name_buf: [3]u8 = undefined;
            const name_str = std.fmt.bufPrint(&name_buf, "{d}", .{i + 1}) catch unreachable;
            const name = try std.heap.c_allocator.dupe(u8, name_str);
            ws.* = try Workspace.init(server, name);
        }
        server.focused_workspace = server.workspaces[0];

        server.config = Config.load(std.heap.c_allocator) catch |err| blk: {
            std.log.err("failed to load config: {}, using default", .{err});
            break :blk Config.default(std.heap.c_allocator) catch unreachable;
        };

        server.socket_name = try wl_server.addSocketAuto(&server.socket_name_buf);
        std.log.info("Running compositor on WAYLAND_DISPLAY={s}", .{server.socket_name});

        server.mcp = McpServer.init(server, std.heap.c_allocator) catch |err| blk: {
            std.log.err("failed to initialize MCP server: {}", .{err});
            break :blk null;
        };
    }

    pub fn getLayerTree(server: *Server, layer: anytype) *wlr.SceneTree {
        return switch (layer) {
            .background => server.bg_tree,
            .bottom => server.bottom_tree,
            .top => server.top_tree,
            .overlay => server.overlay_tree,
            else => server.top_tree,
        };
    }

    fn newLayerSurface(listener: *wl.Listener(*wlr.LayerSurfaceV1), wlr_layer_surface: *wlr.LayerSurfaceV1) void {
        const server: *Server = @fieldParentPtr("new_layer_surface", listener);
        const surface = LayerSurface.create(server, wlr_layer_surface) catch |err| {
            std.log.err("failed to create layer surface: {}", .{err});
            return;
        };
        server.layer_surfaces.prepend(surface);
    }

    pub fn handleNewXdgPopup(server: *Server, xdg_popup: *wlr.XdgPopup, parent_tree: *wlr.SceneTree) void {
        const xdg_surface = xdg_popup.base;
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
            .scene_tree = scene_tree,
        };

        xdg_surface.surface.events.commit.add(&popup.commit);
        xdg_popup.events.destroy.add(&popup.destroy);
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

    pub fn spawn(server: *Server, cmd: []const u8) void {
        std.log.info("Compositor spawning command: {s}", .{cmd});

        const xdg = std.process.getEnvVarOwned(std.heap.c_allocator, "XDG_RUNTIME_DIR") catch null;
        if (xdg) |dir| {
            std.log.debug("Child XDG_RUNTIME_DIR: {s}", .{dir});
            std.heap.c_allocator.free(dir);
        } else {
            std.log.warn("Child XDG_RUNTIME_DIR is NOT SET!", .{});
        }

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
                    ws.scene_tree.node.setEnabled(ws == server.focused_workspace);
                } else {
                    ws.scene_tree.node.setEnabled(true);
                }
                ws.arrange();
            } else if (server.display_mode != .discrete and ws == server.focused_workspace) {
                // Spanned/Mirror: focused workspace is always visible at origin
                ws.scene_tree.node.setPosition(0, 0);
                ws.scene_tree.node.setEnabled(true);
                ws.arrange();
            } else {
                ws.scene_tree.node.setEnabled(false);
            }
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
        server.new_layer_surface.link.remove();

        server.current_sequence.deinit(std.heap.c_allocator);
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
            wlr_output.destroy();
            return;
        };

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
        const server: *Server = @fieldParentPtr("new_xdg_toplevel", listener);
        const xdg_surface = xdg_toplevel.base;

        const toplevel = std.heap.c_allocator.create(Toplevel) catch {
            std.log.err("failed to allocate new toplevel", .{});
            return;
        };

        const ws = server.focused_workspace;
        toplevel.server = server;
        const container = ws.scene_tree.createSceneTree() catch {
            std.heap.c_allocator.destroy(toplevel);
            std.log.err("failed to allocate container scene tree", .{});
            return;
        };

        const xdg_surface_tree = container.createSceneXdgSurface(xdg_surface) catch {
            container.node.destroy();
            std.heap.c_allocator.destroy(toplevel);
            std.log.err("failed to allocate xdg surface scene tree", .{});
            return;
        };

        toplevel.* = .{
            .server = server,
            .workspace = ws,
            .xdg_toplevel = xdg_toplevel,
            .scene_tree = container,
            .xdg_surface_tree = xdg_surface_tree,
        };

        // Initialize border rects
        toplevel.border_top = container.createSceneRect(0, 0, &toplevel.inactive_border_color) catch null;
        toplevel.border_bottom = container.createSceneRect(0, 0, &toplevel.inactive_border_color) catch null;
        toplevel.border_left = container.createSceneRect(0, 0, &toplevel.inactive_border_color) catch null;
        toplevel.border_right = container.createSceneRect(0, 0, &toplevel.inactive_border_color) catch null;

        container.node.data = toplevel;
        xdg_surface.data = container;

        // Add to workspace list immediately so link is valid for remove() later
        ws.views.prepend(toplevel);

        if (ws.layout == .tiling) {
            if (ws.layout.tiling.root) |root| {
                root.split(std.heap.c_allocator, toplevel) catch |err| {
                    std.log.err("failed to split tiling node: {}", .{err});
                };
            } else {
                ws.layout.tiling.root = TilingNode.createLeaf(std.heap.c_allocator, toplevel) catch null;
            }
        }

        ws.arrange();
        xdg_surface.surface.events.commit.add(&toplevel.commit);
        xdg_surface.surface.events.map.add(&toplevel.map);
        xdg_surface.surface.events.unmap.add(&toplevel.unmap);
        xdg_toplevel.events.destroy.add(&toplevel.destroy);
        xdg_toplevel.events.request_move.add(&toplevel.request_move);
        xdg_toplevel.events.request_resize.add(&toplevel.request_resize);
    }

    fn newXdgPopup(listener: *wl.Listener(*wlr.XdgPopup), xdg_popup: *wlr.XdgPopup) void {
        const parent = wlr.XdgSurface.tryFromWlrSurface(xdg_popup.parent.?) orelse return;
        const parent_tree = @as(?*wlr.SceneTree, @ptrCast(@alignCast(parent.data))) orelse return;

        const server: *Server = @fieldParentPtr("new_xdg_popup", listener);
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
                // We use node.data to identify toplevels.
                // We must be careful to only cast if it looks like a Toplevel.
                if (n.node.data) |data| {
                    // Check if it's actually a Toplevel by verifying it's in our toplevels list?
                    // Or just assume it is if data is set, but ensure LayerShell sets it to null.
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

    pub fn focusView(server: *Server, toplevel: *Toplevel, surface: *wlr.Surface) void {
        if (server.seat.keyboard_state.focused_surface) |previous_surface| {
            if (previous_surface == surface) return;
            if (wlr.XdgSurface.tryFromWlrSurface(previous_surface)) |xdg_surface| {
                if (xdg_surface.role_data.toplevel) |prev_t| {
                    _ = wlr.XdgToplevel.setActivated(prev_t, false);
                    if (View.fromXdgSurface(xdg_surface)) |v| {
                        v.updateBorderColor(&v.inactive_border_color);
                    }
                }
            }
        }

        // Sync focused workspace to the view's workspace
        server.focused_workspace = toplevel.workspace;
        toplevel.workspace.ensureViewVisible(toplevel);
        toplevel.updateBorderColor(&toplevel.active_border_color);

        // Keep physical order stable for Ribbon navigation.
        // We only raise the scene node for visual priority.
        toplevel.scene_tree.node.raiseToTop();
        // Skip: toplevel.workspace.views.prepend(toplevel);

        _ = wlr.XdgToplevel.setActivated(toplevel.xdg_toplevel, true);

        if (server.seat.keyboard_state.keyboard) |kbd| {
            wlr.Seat.keyboardNotifyEnter(server.seat, surface, kbd.keycodes[0..kbd.num_keycodes], &kbd.modifiers);
        } else {
            wlr.Seat.keyboardNotifyEnter(server.seat, surface, &[_]u32{}, &wlr.Keyboard.Modifiers{
                .depressed = 0,
                .latched = 0,
                .locked = 0,
                .group = 0,
            });
        }

        // Niri style scrolling
        const ws = toplevel.workspace;
        const s = server;
        if (s.display_mode == .discrete) {
            if (ws.visible_on) |output| {
                var box: wlr.Box = undefined;
                s.output_layout.getBox(output.wlr_output, &box);
                const view_width = @divTrunc(box.width * toplevel.width_percent, 100);
                ws.scroll_offset_x = @as(i32, @divTrunc(box.width - view_width, 2)) - toplevel.x;
            }
        } else {
            // Spanned or Mirror: use monitor where cursor is
            var output = s.output_layout.outputAt(s.cursor.x, s.cursor.y);
            if (output == null) {
                // Fallback to first output
                if (s.outputs.link.next != &s.outputs.link) {
                    output = (@as(*Output, @fieldParentPtr("link", s.outputs.link.next.?))).wlr_output;
                }
            }

            if (output) |o| {
                var box: wlr.Box = undefined;
                s.output_layout.getBox(o, &box);
                const view_width = @divTrunc(box.width * toplevel.width_percent, 100);
                // Snap to this monitor's coordinates within the workspace
                ws.scroll_offset_x = @as(i32, @divTrunc(box.width - view_width, 2)) - (toplevel.x - box.x);
            }
        }
        ws.arrange();
        server.refreshBars();
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
                var sx: f64 = undefined;
                var sy: f64 = undefined;
                const node = server.scene.tree.node.at(server.cursor.x, server.cursor.y, &sx, &sy);

                // Only clear focus if we hit nothing (outside all outputs) or the background (rect)
                if (node == null or node.?.type == .rect) {
                    server.cursor.setXcursor(server.cursor_mgr, "default");
                    wlr.Seat.pointerClearFocus(server.seat);
                }
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
        _ = server.seat.pointerNotifyButton(event.time_msec, event.button, event.state);

        // --- NEW: Handle bar workspace clicks FIRST ---
        if (event.state == .pressed and event.button == 0x110) { // BTN_LEFT
            if (server.output_layout.outputAt(server.cursor.x, server.cursor.y)) |wlr_out| {
                var it = server.outputs.link.next;
                while (it != &server.outputs.link) : (it = it.?.next) {
                    const output: *Output = @fieldParentPtr("link", it.?);

                    if (output.wlr_output == wlr_out) {
                        if (output.bar) |bar| {
                            if (bar.hitTestWorkspace(server.cursor.x, server.cursor.y)) |idx| {
                                server.switchToWorkspace(@intCast(idx));
                                return; // 🚨 IMPORTANT: stop normal click handling
                            }
                        }
                        break;
                    }
                }
            }
        }
        if (event.state == .released) {
            server.cursor_mode = .passthrough;
        } else if (server.viewAt(server.cursor.x, server.cursor.y)) |res| {
            server.focusView(res.toplevel, res.surface);
        } else if (server.output_layout.outputAt(server.cursor.x, server.cursor.y)) |wlr_out| {
            for (server.workspaces) |ws| {
                if (ws.visible_on != null and ws.visible_on.?.wlr_output == wlr_out) {
                    server.focused_workspace = ws;
                    server.seat.keyboardNotifyClearFocus();
                    break;
                }
            }
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
    }

    fn executeAction(server: *Server, kb: Keybinding) void {
        const action = kb.action orelse return;
        switch (action) {
            .toggle_layout => {
                const ws = server.focused_workspace;
                if (ws.layout == .ribbon) {
                    var tiling = Tiling{};
                    var it = ws.views.link.prev;
                    while (it != &ws.views.link) : (it = it.?.prev) {
                        const view: *Toplevel = @fieldParentPtr("link", it.?);
                        if (tiling.root) |root| {
                            root.split(std.heap.c_allocator, view) catch {};
                        } else {
                            tiling.root = TilingNode.createLeaf(std.heap.c_allocator, view) catch null;
                        }
                    }
                    ws.layout = .{ .tiling = tiling };
                } else {
                    ws.layout = .{ .ribbon = .{} };
                }
                ws.arrange();
            },
            .smart_view => {
                const ws = server.focused_workspace;
                ws.layout = if (ws.layout == .smart_view) .{ .ribbon = .{} } else .{ .smart_view = .{} };
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
            .toggle_locked, .toggle_sticky, .toggle_private, .toggle_marked, .toggle_hidden, .toggle_urgent => if (server.seat.keyboard_state.focused_surface) |surface| {
                if (wlr.XdgSurface.tryFromWlrSurface(surface)) |xdg_surface| {
                    if (View.fromXdgSurface(xdg_surface)) |t| {
                        switch (action) {
                            .toggle_locked => t.locked = !t.locked,
                            .toggle_sticky => t.sticky = !t.sticky,
                            .toggle_private => t.private = !t.private,
                            .toggle_marked => t.marked = !t.marked,
                            .toggle_hidden => t.hidden = !t.hidden,
                            .toggle_urgent => t.urgent = !t.urgent,
                            else => unreachable,
                        }
                        t.workspace.arrange();
                    }
                }
            },
        }
    }

    fn matchKey(kb: Keybinding, sym: xkb.Keysym, mods: wlr.Keyboard.ModifierMask, is_sequence_step: bool) bool {
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

        for (server.config.value.keybindings) |kb| {
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
                            server.executeAction(kb);
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
                    server.executeAction(kb);
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
        var it = server.outputs.link.next;
        while (it != &server.outputs.link) : (it = it.?.next) {
            const output: *Output = @fieldParentPtr("link", it.?);
            Screenshot.captureOutput(server.renderer, output.wlr_output, server.scene) catch |err| {
                std.log.err("Failed to capture screenshot for {s}: {}", .{ output.wlr_output.name, err });
            };
        }
    }
};
