const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("Server.zig").Server;
const View = @import("View.zig");

pub const Workspace = struct {
    server: *Server,
    name: []const u8,

    // In a real tiling WM, we will use a tree or specific layout structures.
    // For now, we will maintain a list of views in this workspace.
    views: wl.list.Head(View.Toplevel, .link) = undefined,
    scene_tree: *wlr.SceneTree,
    visible_on: ?*@import("Output.zig").Output = null,

    pub fn init(server: *Server, name: []const u8) !*Workspace {
        const workspace = try std.heap.c_allocator.create(Workspace);
        workspace.* = .{
            .server = server,
            .name = name,
            // Create a dedicated scene tree for this workspace.
            // All windows in this workspace will be children of this tree.
            .scene_tree = try server.scene.tree.createSceneTree(),
            .visible_on = null,
        };
        workspace.views.init();
        // Hide by default
        workspace.scene_tree.node.setEnabled(false);
        return workspace;
    }

    pub fn setVisible(self: *Workspace, output: ?*@import("Output.zig").Output) void {
        self.visible_on = output;
        if (output) |o| {
            if (self.server.output_layout.get(o.wlr_output)) |l_output| {
                self.scene_tree.node.setPosition(l_output.x, l_output.y);
            }
            self.scene_tree.node.setEnabled(true);
            self.scene_tree.node.raiseToTop();
        } else {
            self.scene_tree.node.setEnabled(false);
        }
    }

    pub fn deinit(self: *Workspace) void {
        std.heap.c_allocator.destroy(self);
    }
};
