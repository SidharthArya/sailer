const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("Server.zig").Server;
const c = @import("c.zig").c;

pub const Toplevel = struct {
    server: *Server,
    workspace: *@import("Workspace.zig").Workspace,
    link: wl.list.Link = undefined,
    focus_link: wl.list.Link = undefined,
    all_link: wl.list.Link = undefined,
    xdg_toplevel: *wlr.XdgToplevel,
    scene_tree: *wlr.SceneTree,
    xdg_surface_tree: *wlr.SceneTree,
    foreign_toplevel: ?*wlr.ForeignToplevelHandleV1 = null,
    ext_foreign_toplevel_handle: ?*c.wlr_ext_foreign_toplevel_handle_v1 = null,
    last_output: ?*wlr.Output = null,

    x: i32 = 0,
    y: i32 = 0,
    width_percent: i32 = 50,
    is_maximized: bool = false,
    is_fullscreen: bool = false,
    is_floating: bool = false,
    saved_x: i32 = 0,
    saved_y: i32 = 0,
    saved_width_percent: i32 = 50,
    mapped: bool = false,
    locked: bool = false,
    sticky: bool = false,
    private: bool = false,
    marked: bool = false,
    hidden: bool = false,
    urgent: bool = false,
    scratchpad_id: usize = 0, // Associating with a keybinding pointer
    needs_centering: bool = false, // Set when scratchpad first shown; consumed on first commit with real geometry
    border_width: i32 = 2,
    active_border_color: [4]f32 = .{ 0.38, 0.44, 0.60, 1.0 },
    inactive_border_color: [4]f32 = .{ 0.15, 0.17, 0.23, 1.0 },
    marked_border_color: [4]f32 = .{ 0.90, 0.70, 0.30, 1.0 },
    urgent_border_color: [4]f32 = .{ 1.0, 0.35, 0.1, 1.0 },
    identifier: [20]u8 = undefined, // Unique hex identifier
    border_top: ?*wlr.SceneRect = null,
    border_bottom: ?*wlr.SceneRect = null,
    border_left: ?*wlr.SceneRect = null,
    border_right: ?*wlr.SceneRect = null,
    listeners: Listeners,

    pub const Listeners = struct {
        commit: wl.Listener(*wlr.Surface),
        map: wl.Listener(void),
        unmap: wl.Listener(void),
        destroy: wl.Listener(void),
        request_move: wl.Listener(*wlr.XdgToplevel.event.Move),
        request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize),
        request_maximize: wl.Listener(void),
        request_fullscreen: wl.Listener(void),
        request_show_window_menu: wl.Listener(*wlr.XdgToplevel.event.ShowWindowMenu),
        foreign_request_maximize: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Maximized),
        foreign_request_minimize: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Minimized),
        foreign_request_activate: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Activated),
        foreign_request_fullscreen: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Fullscreen),
        foreign_request_close: wl.Listener(*wlr.ForeignToplevelHandleV1),
        foreign_destroy: wl.Listener(*wlr.ForeignToplevelHandleV1),
    };

    pub fn create(server: *Server, workspace: *@import("Workspace.zig").Workspace, xdg_toplevel: *wlr.XdgToplevel) !*Toplevel {
        const toplevel = try std.heap.c_allocator.create(Toplevel);
        toplevel.* = .{
            .server = server,
            .workspace = workspace,
            .xdg_toplevel = xdg_toplevel,
            .scene_tree = undefined,
            .xdg_surface_tree = undefined,
            .listeners = undefined,
            .border_width = 2,
            .active_border_color = .{ 0.38, 0.44, 0.60, 1.0 },
            .inactive_border_color = .{ 0.15, 0.17, 0.23, 1.0 },
            .marked_border_color = .{ 0.90, 0.70, 0.30, 1.0 },
            .urgent_border_color = .{ 1.0, 0.35, 0.1, 1.0 },
        };

        const scene_tree = workspace.scene_tree.createSceneTree() catch return error.SceneTreeCreationFailed;
        toplevel.scene_tree = scene_tree;
        toplevel.xdg_surface_tree = scene_tree.createSceneXdgSurface(xdg_toplevel.base) catch return error.SceneTreeCreationFailed;

        toplevel.border_top = scene_tree.createSceneRect(0, 0, &toplevel.inactive_border_color) catch null;
        toplevel.border_bottom = scene_tree.createSceneRect(0, 0, &toplevel.inactive_border_color) catch null;
        toplevel.border_left = scene_tree.createSceneRect(0, 0, &toplevel.inactive_border_color) catch null;
        toplevel.border_right = scene_tree.createSceneRect(0, 0, &toplevel.inactive_border_color) catch null;

        toplevel.listeners.commit = .init(handleCommit);
        toplevel.listeners.map = .init(handleMap);
        toplevel.listeners.unmap = .init(handleUnmap);
        toplevel.listeners.destroy = .init(handleDestroy);
        toplevel.listeners.request_move = .init(handleRequestMove);
        toplevel.listeners.request_resize = .init(handleRequestResize);
        toplevel.listeners.request_maximize = .init(handleRequestMaximize);
        toplevel.listeners.request_fullscreen = .init(handleRequestFullscreen);
        toplevel.listeners.request_show_window_menu = .init(handleRequestShowWindowMenu);
        toplevel.listeners.foreign_request_maximize = .init(handleForeignRequestMaximize);
        toplevel.listeners.foreign_request_minimize = .init(handleForeignRequestMinimize);
        toplevel.listeners.foreign_request_activate = .init(handleForeignRequestActivate);
        toplevel.listeners.foreign_request_fullscreen = .init(handleForeignRequestFullscreen);
        toplevel.listeners.foreign_request_close = .init(handleForeignRequestClose);
        toplevel.listeners.foreign_destroy = .init(handleForeignDestroy);

        xdg_toplevel.base.surface.events.commit.add(&toplevel.listeners.commit);
        xdg_toplevel.base.surface.events.map.add(&toplevel.listeners.map);
        xdg_toplevel.base.surface.events.unmap.add(&toplevel.listeners.unmap);
        xdg_toplevel.events.destroy.add(&toplevel.listeners.destroy);
        xdg_toplevel.events.request_move.add(&toplevel.listeners.request_move);
        xdg_toplevel.events.request_resize.add(&toplevel.listeners.request_resize);
        xdg_toplevel.events.request_maximize.add(&toplevel.listeners.request_maximize);
        xdg_toplevel.events.request_fullscreen.add(&toplevel.listeners.request_fullscreen);
        xdg_toplevel.events.request_show_window_menu.add(&toplevel.listeners.request_show_window_menu);

        _ = std.fmt.bufPrint(&toplevel.identifier, "0x{x}", .{@intFromPtr(toplevel)}) catch {
            @memcpy(toplevel.identifier[0..7], "unknown");
            toplevel.identifier[7] = 0;
        };

        toplevel.xdg_toplevel.base.data = toplevel.scene_tree;
        toplevel.scene_tree.node.data = toplevel;

        return toplevel;
    }

    pub fn updateBorderColor(self: *Toplevel, color: [4]f32) void {
        if (self.border_top) |r| r.setColor(&color);
        if (self.border_bottom) |r| r.setColor(&color);
        if (self.border_left) |r| r.setColor(&color);
        if (self.border_right) |r| r.setColor(&color);
    }

    pub fn refreshBorderColor(self: *Toplevel, focused: bool) void {
        const color = if (self.marked)
            self.marked_border_color
        else if (focused)
            self.active_border_color
        else if (self.urgent)
            self.urgent_border_color
        else
            self.inactive_border_color;

        self.updateBorderColor(color);
    }

    pub fn updateLayout(self: *Toplevel, width: i32, height: i32) void {
        const bw = if (self.is_fullscreen) 0 else self.border_width;

        self.xdg_surface_tree.node.setPosition(bw, bw);

        if (self.border_top) |r| {
            r.setSize(width - 2 * bw, bw);
            r.node.setPosition(bw, 0);
        }
        if (self.border_bottom) |r| {
            r.setSize(width - 2 * bw, bw);
            r.node.setPosition(bw, height - bw);
        }
        if (self.border_left) |r| {
            r.setSize(bw, height);
            r.node.setPosition(0, 0);
        }
        if (self.border_right) |r| {
            r.setSize(bw, height);
            r.node.setPosition(width - bw, 0);
        }
    }

    fn handleCommit(listener: *wl.Listener(*wlr.Surface), surface: *wlr.Surface) void {
        const listeners: *Listeners = @fieldParentPtr("commit", listener);
        const toplevel: *Toplevel = @fieldParentPtr("listeners", listeners);

        if (toplevel.xdg_toplevel.base.initial_commit) {
            std.log.debug("Initial commit for: {s}", .{@as([*:0]const u8, @ptrCast(toplevel.xdg_toplevel.title orelse "unnamed"))});
            _ = toplevel.xdg_toplevel.base.scheduleConfigure();
        }

        if (toplevel.mapped) {
            // For scratchpad (floating) windows, arrange() skips updateLayout.
            // Update borders directly using the committed geometry so they wrap
            // the actual window size rather than the 800×600 fallback from handleMap.
            if (toplevel.scratchpad_id != 0) {
                const geo = toplevel.xdg_toplevel.base.geometry;
                if (geo.width > 0 and geo.height > 0) {
                    const bw = toplevel.border_width;
                    toplevel.updateLayout(geo.width + 2 * bw, geo.height + 2 * bw);

                    // Center on first show — deferred here because the real size
                    // is only available after the client's first commit.
                    if (toplevel.needs_centering) {
                        toplevel.needs_centering = false;
                        const area = toplevel.workspace.getUsableArea();
                        const outer_w = geo.width + 2 * bw;
                        const outer_h = geo.height + 2 * bw;
                        toplevel.x = area.x + @divTrunc(area.width - outer_w, 2);
                        toplevel.y = area.y + @divTrunc(area.height - outer_h, 2);
                        toplevel.scene_tree.node.setPosition(toplevel.x, toplevel.y);
                    }
                }
            }
            toplevel.workspace.arrange();
        }

        if (toplevel.foreign_toplevel) |handle| {
            if (toplevel.xdg_toplevel.title) |title| handle.setTitle(title);
            if (toplevel.xdg_toplevel.app_id) |app_id| handle.setAppId(app_id);
            handle.setMaximized(toplevel.is_maximized);
            handle.setFullscreen(toplevel.is_fullscreen);
            handle.setActivated(toplevel.server.seat.keyboard_state.focused_surface == surface);
            if (toplevel.workspace.visible_on) |output| {
                if (toplevel.last_output != output.wlr_output) {
                    if (toplevel.last_output) |lo| handle.outputLeave(lo);
                    handle.outputEnter(output.wlr_output);
                }
            } else if (toplevel.last_output) |lo| {
                handle.outputLeave(lo);
            }
        }

        if (toplevel.ext_foreign_toplevel_handle) |handle| {
            const state = c.wlr_ext_foreign_toplevel_handle_v1_state{
                .title = if (toplevel.xdg_toplevel.title) |title| title else null,
                .app_id = if (toplevel.xdg_toplevel.app_id) |app_id| app_id else null,
            };
            c.wlr_ext_foreign_toplevel_handle_v1_update_state(handle, &state);
        }

        if (toplevel.workspace.visible_on) |output| {
            if (toplevel.last_output != output.wlr_output) {
                toplevel.last_output = output.wlr_output;
            }
        } else {
            toplevel.last_output = null;
        }
    }

    fn handleMap(listener: *wl.Listener(void)) void {
        const listeners: *Listeners = @fieldParentPtr("map", listener);
        const toplevel: *Toplevel = @fieldParentPtr("listeners", listeners);

        std.log.debug("View map: {s}", .{@as([*:0]const u8, @ptrCast(toplevel.xdg_toplevel.title orelse "unnamed"))});

        // Claim as scratchpad if it matches a pending request
        if (toplevel.xdg_toplevel.app_id) |id| {
            const app_id = std.mem.span(id);
            var i: usize = 0;
            while (i < toplevel.server.pending_scratchpads.items.len) {
                const pending = toplevel.server.pending_scratchpads.items[i];
                if (std.mem.eql(u8, pending.search_id, app_id)) {
                    std.log.debug("View map: claiming '{s}' as scratchpad for kb_ptr 0x{x}", .{ app_id, pending.kb_ptr });
                    toplevel.scratchpad_id = pending.kb_ptr;
                    toplevel.is_floating = true;
                    toplevel.needs_centering = true; // center on first commit when real geometry is available
                    _ = toplevel.server.pending_scratchpads.orderedRemove(i);
                    break;
                }
                i += 1;
            }
        }
        toplevel.mapped = true;
        toplevel.refreshBorderColor(false);
        if (toplevel.border_top) |r| r.node.raiseToTop();
        if (toplevel.border_bottom) |r| r.node.raiseToTop();
        if (toplevel.border_left) |r| r.node.raiseToTop();
        if (toplevel.border_right) |r| r.node.raiseToTop();

        // Size border rects before the first frame for scratchpad windows.
        // The layout's arrange() skips updateLayout for floating windows, so
        // border rects would remain 0×0 until the first handleCommit fires.
        if (toplevel.scratchpad_id != 0) {
            const w = if (toplevel.xdg_toplevel.current.width > 0) toplevel.xdg_toplevel.current.width else 800;
            const h = if (toplevel.xdg_toplevel.current.height > 0) toplevel.xdg_toplevel.current.height else 600;
            toplevel.updateLayout(w, h);
        }

        // Create foreign toplevel handle
        if (toplevel.foreign_toplevel == null) {
            if (wlr.ForeignToplevelHandleV1.create(toplevel.server.foreign_toplevel_mgr) catch null) |handle| {
                toplevel.foreign_toplevel = handle;
                handle.events.request_activate.add(&toplevel.listeners.foreign_request_activate);
                handle.events.request_maximize.add(&toplevel.listeners.foreign_request_maximize);
                handle.events.request_minimize.add(&toplevel.listeners.foreign_request_minimize);
                handle.events.request_fullscreen.add(&toplevel.listeners.foreign_request_fullscreen);
                handle.events.request_close.add(&toplevel.listeners.foreign_request_close);
                handle.events.destroy.add(&toplevel.listeners.foreign_destroy);

                if (toplevel.xdg_toplevel.title) |title| handle.setTitle(title);
                if (toplevel.xdg_toplevel.app_id) |app_id| handle.setAppId(app_id);
                handle.setMaximized(toplevel.is_maximized);
                handle.setFullscreen(toplevel.is_fullscreen);
                if (toplevel.workspace.visible_on) |output| {
                    handle.outputEnter(output.wlr_output);
                    toplevel.last_output = output.wlr_output;
                }
            }
        }

        if (toplevel.ext_foreign_toplevel_handle == null) {
            const state = c.wlr_ext_foreign_toplevel_handle_v1_state{
                .title = if (toplevel.xdg_toplevel.title) |title| title else null,
                .app_id = if (toplevel.xdg_toplevel.app_id) |app_id| app_id else null,
            };
            if (c.wlr_ext_foreign_toplevel_handle_v1_create(toplevel.server.ext_foreign_toplevel_list_v1_mgr, &state)) |handle| {
                toplevel.ext_foreign_toplevel_handle = handle;
                // Identifier is not in the state struct in this wlroots version, 
                // and the handle struct might be treated as opaque by Zig's C-import.
                // We'll skip setting it directly to avoid compilation errors.
            }
        }

        toplevel.workspace.arrange();
        toplevel.server.focusView(toplevel, toplevel.xdg_toplevel.base.surface);
    }

    fn handleUnmap(listener: *wl.Listener(void)) void {
        const listeners: *Listeners = @fieldParentPtr("unmap", listener);
        const toplevel: *Toplevel = @fieldParentPtr("listeners", listeners);

        std.log.debug("View unmap: {s}", .{@as([*:0]const u8, @ptrCast(toplevel.xdg_toplevel.title orelse "unnamed"))});
        if (toplevel.server.grabbed_view == toplevel) {
            toplevel.server.grabbed_view = null;
        }

        const ws = toplevel.workspace;
        const server = toplevel.server;
        const was_focused = if (server.seat.keyboard_state.focused_surface) |surface| surface == toplevel.xdg_toplevel.base.surface else false;

        var next_focus: ?*Toplevel = null;
        if (was_focused) {
            switch (server.config.focus_on_close) {
                .previous => {
                    if (toplevel.link.next != &ws.views.link) {
                        next_focus = @fieldParentPtr("link", toplevel.link.next.?);
                    } else if (toplevel.link.prev != &ws.views.link) {
                        next_focus = @fieldParentPtr("link", toplevel.link.prev.?);
                    }
                },
                .last => {
                    var it = ws.focus_history.link.next;
                    while (it != &ws.focus_history.link) : (it = it.?.next) {
                        const candidate: *Toplevel = @fieldParentPtr("focus_link", it.?);

                        if (candidate != toplevel) {
                            next_focus = candidate;
                            break;
                        }
                    }
                },
            }
        }

        toplevel.mapped = false;

        toplevel.link.remove();
        toplevel.focus_link.remove();
        toplevel.all_link.remove();
        toplevel.scene_tree.node.setEnabled(false);
        toplevel.workspace.arrange();

        if (was_focused) {
            if (next_focus) |nf| {
                server.focusView(nf, nf.xdg_toplevel.base.surface);
            } else if (server.output_layout.outputAt(server.cursor.x, server.cursor.y)) |wlr_out| {
                for (server.workspaces) |ws_iter| {
                    if (ws_iter.visible_on != null and ws_iter.visible_on.?.wlr_output == wlr_out) {
                        server.focused_workspace = ws_iter;
                        wlr.Seat.keyboardNotifyClearFocus(server.seat);
                        break;
                    }
                }
            }
        }

        if (toplevel.foreign_toplevel) |_| {
            toplevel.detachForeignToplevel();
        }
        if (toplevel.ext_foreign_toplevel_handle) |handle| {
            c.wlr_ext_foreign_toplevel_handle_v1_destroy(handle);
            toplevel.ext_foreign_toplevel_handle = null;
        }
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const listeners: *Listeners = @fieldParentPtr("destroy", listener);
        const toplevel: *Toplevel = @fieldParentPtr("listeners", listeners);

        // Only remove if not already unmapped
        if (toplevel.link.next != null) toplevel.link.remove();
        if (toplevel.focus_link.next != null) toplevel.focus_link.remove();

        toplevel.listeners.commit.link.remove();
        toplevel.listeners.map.link.remove();
        toplevel.listeners.unmap.link.remove();
        toplevel.listeners.destroy.link.remove();
        toplevel.listeners.request_move.link.remove();
        toplevel.listeners.request_resize.link.remove();
        toplevel.listeners.request_maximize.link.remove();
        toplevel.listeners.request_fullscreen.link.remove();
        toplevel.listeners.request_show_window_menu.link.remove();

        if (toplevel.foreign_toplevel) |_| toplevel.detachForeignToplevel();
        toplevel.scene_tree.node.destroy();
        std.heap.c_allocator.destroy(toplevel);
    }

    fn handleRequestMove(
        listener: *wl.Listener(*wlr.XdgToplevel.event.Move),
        _: *wlr.XdgToplevel.event.Move,
    ) void {
        const listeners: *Listeners = @fieldParentPtr("request_move", listener);
        const toplevel: *Toplevel = @fieldParentPtr("listeners", listeners);

        if (toplevel.locked) return;
        const server = toplevel.server;
        server.grabbed_view = toplevel;
        server.cursor_mode = .move;

        // Account for workspace offset in grab calculation.
        // Absolute window x = workspace.x + toplevel.x
        var ws_box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        if (toplevel.workspace.visible_on) |output| {
            server.output_layout.getBox(output.wlr_output, &ws_box);
        }

        server.grab_x = server.cursor.x - @as(f64, @floatFromInt(ws_box.x + toplevel.x));
        server.grab_y = server.cursor.y - @as(f64, @floatFromInt(ws_box.y + toplevel.y));
    }

    fn handleRequestResize(
        listener: *wl.Listener(*wlr.XdgToplevel.event.Resize),
        event: *wlr.XdgToplevel.event.Resize,
    ) void {
        const listeners: *Listeners = @fieldParentPtr("request_resize", listener);
        const toplevel: *Toplevel = @fieldParentPtr("listeners", listeners);

        if (toplevel.locked) return;
        const server = toplevel.server;

        server.grabbed_view = toplevel;
        server.cursor_mode = .resize;
        server.resize_edges = event.edges;

        const box = toplevel.xdg_toplevel.base.geometry;

        var ws_box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        if (toplevel.workspace.visible_on) |output| {
            server.output_layout.getBox(output.wlr_output, &ws_box);
        }

        const border_x = ws_box.x + toplevel.x + box.x + if (event.edges.right) box.width else 0;
        const border_y = ws_box.y + toplevel.y + box.y + if (event.edges.bottom) box.height else 0;
        server.grab_x = server.cursor.x - @as(f64, @floatFromInt(border_x));
        server.grab_y = server.cursor.y - @as(f64, @floatFromInt(border_y));

        server.grab_box = box;
        server.grab_box.x += toplevel.x;
        server.grab_box.y += toplevel.y;
    }

    pub fn close(self: *Toplevel) void {
        _ = self.xdg_toplevel.sendClose();
    }

    pub fn setMaximized(self: *Toplevel, requested: bool) void {
        if (self.is_maximized == requested) return;

        if (requested) {
            self.saved_x = self.x;
            self.saved_y = self.y;
            self.saved_width_percent = self.width_percent;
        } else {
            self.x = self.saved_x;
            self.y = self.saved_y;
            self.width_percent = self.saved_width_percent;
        }

        self.is_maximized = requested;
        _ = self.xdg_toplevel.setMaximized(requested);
        self.workspace.arrange();
    }

    pub fn setFullscreen(self: *Toplevel, requested: bool) void {
        if (self.is_fullscreen == requested) return;

        if (requested) {
            if (!self.is_maximized) {
                self.saved_x = self.x;
                self.saved_y = self.y;
                self.saved_width_percent = self.width_percent;
            }
        } else {
            if (!self.is_maximized) {
                self.x = self.saved_x;
                self.y = self.saved_y;
                self.width_percent = self.saved_width_percent;
            }
        }

        self.is_fullscreen = requested;
        _ = self.xdg_toplevel.setFullscreen(requested);
        self.workspace.arrange();
    }

    fn handleRequestMaximize(listener: *wl.Listener(void)) void {
        const listeners: *Listeners = @fieldParentPtr("request_maximize", listener);
        const toplevel: *Toplevel = @fieldParentPtr("listeners", listeners);

        toplevel.setMaximized(toplevel.xdg_toplevel.requested.maximized);
    }

    fn handleRequestFullscreen(listener: *wl.Listener(void)) void {
        const listeners: *Listeners = @fieldParentPtr("request_fullscreen", listener);
        const toplevel: *Toplevel = @fieldParentPtr("listeners", listeners);

        toplevel.setFullscreen(toplevel.xdg_toplevel.requested.fullscreen);
    }

    fn handleRequestShowWindowMenu(
        listener: *wl.Listener(*wlr.XdgToplevel.event.ShowWindowMenu),
        event: *wlr.XdgToplevel.event.ShowWindowMenu,
    ) void {
        const listeners: *Listeners = @fieldParentPtr("request_show_window_menu", listener);
        const toplevel: *Toplevel = @fieldParentPtr("listeners", listeners);

        const server = toplevel.server;

        const gx = toplevel.x + event.x;
        const gy = toplevel.y + event.y;

        server.openMenu(toplevel, gx, gy);
    }

    pub fn detachForeignToplevel(self: *Toplevel) void {
        const handle = self.foreign_toplevel orelse return;
        self.listeners.foreign_request_activate.link.remove();
        self.listeners.foreign_request_maximize.link.remove();
        self.listeners.foreign_request_minimize.link.remove();
        self.listeners.foreign_request_fullscreen.link.remove();
        self.listeners.foreign_request_close.link.remove();
        self.listeners.foreign_destroy.link.remove();
        handle.destroy();
        self.foreign_toplevel = null;
    }

    fn handleForeignRequestMaximize(listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Maximized), event: *wlr.ForeignToplevelHandleV1.event.Maximized) void {
        const listeners: *Listeners = @fieldParentPtr("foreign_request_maximize", listener);
        const toplevel: *Toplevel = @fieldParentPtr("listeners", listeners);
        toplevel.setMaximized(event.maximized);
    }

    fn handleForeignRequestMinimize(listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Minimized), event: *wlr.ForeignToplevelHandleV1.event.Minimized) void {
        const listeners: *Listeners = @fieldParentPtr("foreign_request_minimize", listener);
        const toplevel: *Toplevel = @fieldParentPtr("listeners", listeners);
        if (event.minimized) {
            toplevel.hidden = true;
            toplevel.workspace.arrange();
        } else {
            toplevel.hidden = false;
            toplevel.workspace.arrange();
        }
    }

    fn handleForeignRequestActivate(listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Activated), event: *wlr.ForeignToplevelHandleV1.event.Activated) void {
        _ = event;
        const listeners: *Listeners = @fieldParentPtr("foreign_request_activate", listener);
        const toplevel: *Toplevel = @fieldParentPtr("listeners", listeners);
        toplevel.server.activateWorkspace(toplevel.workspace);
        toplevel.server.focusView(toplevel, toplevel.xdg_toplevel.base.surface);
    }

    fn handleForeignRequestFullscreen(listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Fullscreen), event: *wlr.ForeignToplevelHandleV1.event.Fullscreen) void {
        const listeners: *Listeners = @fieldParentPtr("foreign_request_fullscreen", listener);
        const toplevel: *Toplevel = @fieldParentPtr("listeners", listeners);
        toplevel.setFullscreen(event.fullscreen);
    }

    fn handleForeignRequestClose(listener: *wl.Listener(*wlr.ForeignToplevelHandleV1), _: *wlr.ForeignToplevelHandleV1) void {
        const listeners: *Listeners = @fieldParentPtr("foreign_request_close", listener);
        const toplevel: *Toplevel = @fieldParentPtr("listeners", listeners);
        toplevel.close();
    }

    fn handleForeignDestroy(listener: *wl.Listener(*wlr.ForeignToplevelHandleV1), _: *wlr.ForeignToplevelHandleV1) void {
        const listeners: *Listeners = @fieldParentPtr("foreign_destroy", listener);
        const toplevel: *Toplevel = @fieldParentPtr("listeners", listeners);
        toplevel.foreign_toplevel = null;
    }
};

pub const Popup = struct {
    xdg_popup: *wlr.XdgPopup,
    scene_tree: *wlr.SceneTree,
    listeners: Listeners,

    pub const Listeners = struct {
        commit: wl.Listener(*wlr.Surface),
        destroy: wl.Listener(void),
    };

    pub fn create(xdg_popup: *wlr.XdgPopup, scene_tree: *wlr.SceneTree) !*Popup {
        const popup = try std.heap.c_allocator.create(Popup);
        popup.xdg_popup = xdg_popup;
        popup.scene_tree = scene_tree;

        popup.listeners.commit = .init(handleCommit);
        popup.listeners.destroy = .init(handleDestroy);

        xdg_popup.base.surface.events.commit.add(&popup.listeners.commit);
        xdg_popup.events.destroy.add(&popup.listeners.destroy);

        return popup;
    }

    fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const listeners: *Listeners = @fieldParentPtr("commit", listener);
        const popup: *Popup = @fieldParentPtr("listeners", listeners);

        if (popup.xdg_popup.base.initial_commit) {
            _ = popup.xdg_popup.base.scheduleConfigure();
        }
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const listeners: *Listeners = @fieldParentPtr("destroy", listener);
        const popup: *Popup = @fieldParentPtr("listeners", listeners);

        popup.listeners.commit.link.remove();
        popup.listeners.destroy.link.remove();

        popup.scene_tree.node.destroy();
        std.heap.c_allocator.destroy(popup);
    }
};

pub fn fromXdgSurface(xdg_surface: *wlr.XdgSurface) ?*Toplevel {
    const scene_tree = @as(?*wlr.SceneTree, @ptrCast(@alignCast(xdg_surface.data))) orelse return null;
    return @as(?*Toplevel, @ptrCast(@alignCast(scene_tree.node.data)));
}
