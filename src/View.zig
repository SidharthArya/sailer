const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("Server.zig").Server;

pub const Toplevel = struct {
    server: *Server,
    workspace: *@import("Workspace.zig").Workspace,
    link: wl.list.Link = undefined,
    focus_link: wl.list.Link = undefined,
    xdg_toplevel: *wlr.XdgToplevel,
    scene_tree: *wlr.SceneTree,
    xdg_surface_tree: *wlr.SceneTree,

    x: i32 = 0,
    y: i32 = 0,
    width_percent: i32 = 50,
    is_maximized: bool = false,
    is_fullscreen: bool = false,
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
    border_width: i32 = 2,
    active_border_color: [4]f32 = .{ 0.38, 0.44, 0.60, 1.0 },
    inactive_border_color: [4]f32 = .{ 0.15, 0.17, 0.23, 1.0 },
    border_top: ?*wlr.SceneRect = null,
    border_bottom: ?*wlr.SceneRect = null,
    border_left: ?*wlr.SceneRect = null,
    border_right: ?*wlr.SceneRect = null,
    

    commit: wl.Listener(*wlr.Surface) = .init(Toplevel.handleCommit),
    map: wl.Listener(void) = .init(Toplevel.handleMap),
    unmap: wl.Listener(void) = .init(Toplevel.handleUnmap),
    destroy: wl.Listener(void) = .init(Toplevel.handleDestroy),
    request_move: wl.Listener(*wlr.XdgToplevel.event.Move) = .init(Toplevel.handleRequestMove),
    request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) = .init(Toplevel.handleRequestResize),
    request_maximize: wl.Listener(void) = .init(Toplevel.handleRequestMaximize),
    request_fullscreen: wl.Listener(void) = .init(Toplevel.handleRequestFullscreen),
    request_show_window_menu: wl.Listener(*wlr.XdgToplevel.event.ShowWindowMenu) = .init(Toplevel.handleRequestShowWindowMenu),

    pub fn updateBorderColor(self: *Toplevel, color: *const [4]f32) void {
        if (self.border_top) |r| r.node.data = @as(?*anyopaque, @constCast(color));
        if (self.border_bottom) |r| r.node.data = @as(?*anyopaque, @constCast(color));
        if (self.border_left) |r| r.node.data = @as(?*anyopaque, @constCast(color));
        if (self.border_right) |r| r.node.data = @as(?*anyopaque, @constCast(color));
        // Wait, setColor is the correct way, let's keep it if it exists.
        if (self.border_top) |r| r.setColor(color);
        if (self.border_bottom) |r| r.setColor(color);
        if (self.border_left) |r| r.setColor(color);
        if (self.border_right) |r| r.setColor(color);
    }

    pub fn updateLayout(self: *Toplevel, width: i32, height: i32) void {
        const bw = if (self.is_fullscreen) 0 else self.border_width;

        // Position surface inside borders
        self.xdg_surface_tree.node.setPosition(bw, bw);

        // Update borders positions and sizes
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
        const toplevel: *Toplevel = @fieldParentPtr("commit", listener);
        if (toplevel.xdg_toplevel.base.initial_commit) {
            std.log.debug("Initial commit for: {s}", .{@as([*:0]const u8, @ptrCast(toplevel.xdg_toplevel.title orelse "unnamed"))});
            _ = toplevel.xdg_toplevel.base.scheduleConfigure();
        }
        _ = surface;
    }

    fn handleMap(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("map", listener);
        std.log.debug("View map: {s}", .{@as([*:0]const u8, @ptrCast(toplevel.xdg_toplevel.title orelse "unnamed"))});
        toplevel.mapped = true;
        toplevel.workspace.arrange();
        toplevel.server.focusView(toplevel, toplevel.xdg_toplevel.base.surface);
    }

    fn handleUnmap(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("unmap", listener);
        std.log.debug("View unmap: {s}", .{@as([*:0]const u8, @ptrCast(toplevel.xdg_toplevel.title orelse "unnamed"))});
        if (toplevel.server.grabbed_view == toplevel) {
            toplevel.server.grabbed_view = null;
        }

        const ws = toplevel.workspace;
        const server = toplevel.server;
        const was_focused = if (server.seat.keyboard_state.focused_surface) |surface| surface == toplevel.xdg_toplevel.base.surface else false;
        
        var next_focus: ?*Toplevel = null;
        if (was_focused) {
            switch (server.config.value.focus_on_close) {
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
                }
            }
        }

        toplevel.mapped = false;
        if (ws.layout == .tiling) {
            if (ws.layout.tiling.root) |root| {
                if (root.findNodeForView(toplevel)) |node| {
                    node.remove(std.heap.c_allocator, &ws.layout.tiling.root);
                }
            }
        }

        toplevel.link.remove();
        toplevel.focus_link.remove();
        toplevel.scene_tree.node.setEnabled(false);
        toplevel.workspace.arrange();

        if (was_focused) {
            if (next_focus) |nf| {
                server.focusView(nf, nf.xdg_toplevel.base.surface);
            } else {
                wlr.Seat.keyboardNotifyClearFocus(server.seat);
            }
        }
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("destroy", listener);

        toplevel.commit.link.remove();
        toplevel.map.link.remove();
        toplevel.unmap.link.remove();
        toplevel.destroy.link.remove();
        toplevel.request_move.link.remove();
        toplevel.request_resize.link.remove();
        toplevel.request_maximize.link.remove();
        toplevel.request_fullscreen.link.remove();
        toplevel.request_show_window_menu.link.remove();

        toplevel.scene_tree.node.destroy();
        std.heap.c_allocator.destroy(toplevel);
    }

    fn handleRequestMove(
        listener: *wl.Listener(*wlr.XdgToplevel.event.Move),
        _: *wlr.XdgToplevel.event.Move,
    ) void {
        const toplevel: *Toplevel = @fieldParentPtr("request_move", listener);
        if (toplevel.locked) return;
        const server = toplevel.server;
        server.grabbed_view = toplevel;
        server.cursor_mode = .move;
        server.grab_x = server.cursor.x - @as(f64, @floatFromInt(toplevel.x));
        server.grab_y = server.cursor.y - @as(f64, @floatFromInt(toplevel.y));
    }

    fn handleRequestResize(
        listener: *wl.Listener(*wlr.XdgToplevel.event.Resize),
        event: *wlr.XdgToplevel.event.Resize,
    ) void {
        const toplevel: *Toplevel = @fieldParentPtr("request_resize", listener);
        if (toplevel.locked) return;
        const server = toplevel.server;

        server.grabbed_view = toplevel;
        server.cursor_mode = .resize;
        server.resize_edges = event.edges;

        const box = toplevel.xdg_toplevel.base.geometry;

        const border_x = toplevel.x + box.x + if (event.edges.right) box.width else 0;
        const border_y = toplevel.y + box.y + if (event.edges.bottom) box.height else 0;
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
        const toplevel: *Toplevel = @fieldParentPtr("request_maximize", listener);
        toplevel.setMaximized(toplevel.xdg_toplevel.requested.maximized);
    }

    fn handleRequestFullscreen(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("request_fullscreen", listener);
        toplevel.setFullscreen(toplevel.xdg_toplevel.requested.fullscreen);
    }

    fn handleRequestShowWindowMenu(
        listener: *wl.Listener(*wlr.XdgToplevel.event.ShowWindowMenu),
        event: *wlr.XdgToplevel.event.ShowWindowMenu,
    ) void {
        const toplevel: *Toplevel = @fieldParentPtr("request_show_window_menu", listener);
        const server = toplevel.server;

        // request_show_window_menu provides coordinates relative to the surface.
        const gx = toplevel.x + event.x;
        const gy = toplevel.y + event.y;

        server.openMenu(toplevel, gx, gy);
    }
};

pub const Popup = struct {
    xdg_popup: *wlr.XdgPopup,
    scene_tree: *wlr.SceneTree,

    commit: wl.Listener(*wlr.Surface) = .init(Popup.handleCommit),
    destroy: wl.Listener(void) = .init(Popup.handleDestroy),

    fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const popup: *Popup = @fieldParentPtr("commit", listener);
        if (popup.xdg_popup.base.initial_commit) {
            _ = popup.xdg_popup.base.scheduleConfigure();
        }
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const popup: *Popup = @fieldParentPtr("destroy", listener);

        popup.commit.link.remove();
        popup.destroy.link.remove();

        popup.scene_tree.node.destroy();
        std.heap.c_allocator.destroy(popup);
    }
};

pub fn fromXdgSurface(xdg_surface: *wlr.XdgSurface) ?*Toplevel {
    const scene_tree = @as(?*wlr.SceneTree, @ptrCast(@alignCast(xdg_surface.data))) orelse return null;
    return @as(?*Toplevel, @ptrCast(@alignCast(scene_tree.node.data)));
}
