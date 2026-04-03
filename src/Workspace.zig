const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("Server.zig").Server;
const View = @import("View.zig");
const Layout = @import("layouts/index.zig").Layout;

pub const Workspace = struct {
    server: *Server,
    name: []const u8,

    // In a real tiling WM, we will use a tree or specific layout structures.
    // For now, we will maintain a list of views in this workspace.
    views: wl.list.Head(View.Toplevel, .link) = undefined,
    scene_tree: *wlr.SceneTree,
    visible_on: ?*@import("Output.zig").Output = null,
    scroll_offset_x: i32 = 0,

    layout: Layout,

    pub fn init(server: *Server, name: []const u8) !*Workspace {
        const workspace = try std.heap.c_allocator.create(Workspace);
        const scene_tree = try server.scene.tree.createSceneTree();
        scene_tree.node.setEnabled(true);
        workspace.* = .{
            .server = server,
            .name = name,
            // Create a dedicated scene tree for this workspace.
            // All windows in this workspace will be children of this tree.
            .scene_tree = scene_tree,
            .visible_on = null,
            .layout = .{ .ribbon = .{} },
        };
        workspace.views.init();
        return workspace;
    }

    pub fn arrange(self: *Workspace) void {
        var box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        if (self.server.display_mode == .spanned) {
            self.server.output_layout.getBox(null, &box);
        } else if (self.visible_on) |output| {
            self.server.output_layout.getBox(output.wlr_output, &box);
        } else return;

        // Skip arrangement if dimensions are garbage (e.g. from uninitialized output layout)
        if (box.width <= 0 or box.height <= 24 or box.height > 10000) return;

        var layout_box = box;
        layout_box.y += self.server.bar_height;
        layout_box.height -= self.server.bar_height;

        self.layout.arrange(self, layout_box);
    }




    pub fn ensureViewVisible(self: *Workspace, view: *View.Toplevel) void {
        switch (self.layout) {
            .ribbon => |*l| l.ensureViewVisible(self, view),
            else => {},
        }
    }

    pub fn focusRelative(self: *Workspace, delta: i32) void {
        if (self.views.link.next == &self.views.link) return;

        // Find focused view
        var focused: ?*View.Toplevel = null;
        if (self.server.seat.keyboard_state.focused_surface) |surf| {
            if (wlr.XdgSurface.tryFromWlrSurface(surf)) |xdg_surf| {
                focused = View.fromXdgSurface(xdg_surf);
            }
        }

        if (focused) |f| {
            var target_link: *wl.list.Link = undefined;
            if (delta > 0) {
                target_link = f.link.next.?;
                if (target_link == &self.views.link) target_link = self.views.link.next.?;
            } else {
                target_link = f.link.prev.?;
                if (target_link == &self.views.link) target_link = self.views.link.prev.?;
            }
            const next_v: *View.Toplevel = @fieldParentPtr("link", target_link);
            self.server.focusView(next_v, next_v.xdg_toplevel.base.surface);
        } else {
            // Just focus head
            const head = self.views.link.next.?;
            const toplevel: *View.Toplevel = @fieldParentPtr("link", head);
            self.server.focusView(toplevel, toplevel.xdg_toplevel.base.surface);
        }
    }

    pub fn reorderView(self: *Workspace, view: *View.Toplevel, delta: i32) void {
        const link = &view.link;
        if (delta > 0) {
            const next = link.next.?;
            if (next != &self.views.link) {
                link.remove();
                next.insert(link);
            }
        } else {
            const prev = link.prev.?;
            if (prev != &self.views.link) {
                link.remove();
                prev.prev.?.insert(link);
            }
        }
        self.arrange();
    }

    pub fn setVisible(self: *Workspace, output: ?*@import("Output.zig").Output) void {
        self.visible_on = output;
        if (output != null) {
            self.scene_tree.node.setEnabled(true);
            self.scene_tree.node.raiseToTop();
            self.arrange();
        } else {
            self.scene_tree.node.setEnabled(false);
        }
    }

    pub fn deinit(self: *Workspace) void {
        std.heap.c_allocator.destroy(self);
    }
};
