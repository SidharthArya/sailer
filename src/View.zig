const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("Server.zig").Server;

pub const Toplevel = struct {
    server: *Server,
    workspace: *@import("Workspace.zig").Workspace,
    link: wl.list.Link = undefined,
    xdg_toplevel: *wlr.XdgToplevel,
    scene_tree: *wlr.SceneTree,

    x: i32 = 0,
    y: i32 = 0,
    width_percent: i32 = 70,
    mapped: bool = false,

    commit: wl.Listener(*wlr.Surface) = .init(Toplevel.handleCommit),
    map: wl.Listener(void) = .init(Toplevel.handleMap),
    unmap: wl.Listener(void) = .init(Toplevel.handleUnmap),
    destroy: wl.Listener(void) = .init(Toplevel.handleDestroy),
    request_move: wl.Listener(*wlr.XdgToplevel.event.Move) = .init(Toplevel.handleRequestMove),
    request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) = .init(Toplevel.handleRequestResize),

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
        toplevel.mapped = false;
        if (ws.layout_mode == .tiling) {
            if (ws.tiling_root) |root| {
                if (root.findNodeForView(toplevel)) |node| {
                    node.remove(std.heap.c_allocator, &ws.tiling_root);
                }
            }
        }

        toplevel.link.remove();
        toplevel.workspace.arrange();
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("destroy", listener);

        toplevel.commit.link.remove();
        toplevel.map.link.remove();
        toplevel.unmap.link.remove();
        toplevel.destroy.link.remove();
        toplevel.request_move.link.remove();
        toplevel.request_resize.link.remove();

        std.heap.c_allocator.destroy(toplevel);
    }

    fn handleRequestMove(
        listener: *wl.Listener(*wlr.XdgToplevel.event.Move),
        _: *wlr.XdgToplevel.event.Move,
    ) void {
        const toplevel: *Toplevel = @fieldParentPtr("request_move", listener);
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
};

pub const Popup = struct {
    xdg_popup: *wlr.XdgPopup,

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

        std.heap.c_allocator.destroy(popup);
    }
};

pub fn fromXdgSurface(xdg_surface: *wlr.XdgSurface) ?*Toplevel {
    const scene_tree = @as(?*wlr.SceneTree, @ptrCast(@alignCast(xdg_surface.data))) orelse return null;
    return @as(?*Toplevel, @ptrCast(@alignCast(scene_tree.node.data)));
}
