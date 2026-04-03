const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("Server.zig").Server;
const View = @import("View.zig");
const Layout = @import("layouts/index.zig").Layout;
const LayerSurface = @import("LayerShell.zig").LayerSurface;

pub const Workspace = struct {
    server: *Server,
    name: []const u8,

    // In a real tiling WM, we will use a tree or specific layout structures.
    // For now, we will maintain a list of views in this workspace.
    views: wl.list.Head(View.Toplevel, .link) = undefined,
    focus_history: wl.list.Head(View.Toplevel, .focus_link) = undefined,
    scene_tree: *wlr.SceneTree,
    visible_on: ?*@import("Output.zig").Output = null,
    scroll_offset_x: i32 = 0,

    layout: Layout,

    pub fn init(server: *Server, name: []const u8) !*Workspace {
        const workspace = try std.heap.c_allocator.create(Workspace);
        const scene_tree = try server.window_tree.createSceneTree();
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
        workspace.focus_history.init();
        return workspace;
    }

    pub fn arrange(self: *Workspace) void {
        const layout_box = self.getUsableArea();
        
        // Skip arrangement if dimensions are garbage (e.g. from uninitialized output layout or excessive shrinking)
        if (layout_box.width <= 0 or layout_box.height <= 0 or layout_box.height > 10000) return;

        // Check for fullscreen or maximized views first
        var it = self.focus_history.link.next;
        while (it != &self.focus_history.link) : (it = it.?.next) {
            const toplevel: *View.Toplevel = @fieldParentPtr("focus_link", it.?);
            if (!toplevel.mapped) continue;

            if (toplevel.is_fullscreen) {
                var full_box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
                if (self.server.display_mode == .spanned) {
                    self.server.output_layout.getBox(null, &full_box);
                } else if (self.visible_on) |output| {
                    self.server.output_layout.getBox(output.wlr_output, &full_box);
                }

                toplevel.x = full_box.x;
                toplevel.y = full_box.y;
                toplevel.scene_tree.node.setPosition(toplevel.x, toplevel.y);
                toplevel.updateLayout(full_box.width, full_box.height);
                _ = toplevel.xdg_toplevel.setSize(full_box.width, full_box.height);
                toplevel.scene_tree.node.raiseToTop();
                return;
            }

            if (toplevel.is_maximized) {
                toplevel.x = layout_box.x;
                toplevel.y = layout_box.y;
                toplevel.scene_tree.node.setPosition(toplevel.x, toplevel.y);
                toplevel.updateLayout(layout_box.width, layout_box.height);
                _ = toplevel.xdg_toplevel.setSize(layout_box.width, layout_box.height);
                toplevel.scene_tree.node.raiseToTop();
                return;
            }
        }

        self.layout.arrange(self, layout_box);
    }

    pub fn getUsableArea(self: *Workspace) wlr.Box {
        var box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0};
        if (self.server.display_mode == .spanned) {
            self.server.output_layout.getBox(null, &box);
        } else if (self.visible_on) |output| {
            self.server.output_layout.getBox(output.wlr_output, &box);
        } else return box;

        if (box.width <= 0 or box.height <= 0) return box;

        var usable = box;
        
        // Subtract hardcoded bar for now (backward compatibility)
        if (self.server.bar_height > 0) {
            usable.y += self.server.bar_height;
            usable.height -= self.server.bar_height;
        }

        // Subtract Layer Shell exclusive zones
        var it = self.server.layer_surfaces.link.next;
        while (it != &self.server.layer_surfaces.link) : (it = it.?.next) {
            const layer: *LayerSurface = @fieldParentPtr("link", it.?);
            if (!layer.wlr_layer_surface.surface.mapped) continue;
            
            // Check if it's on this output
            if (layer.output) |out| {
                if (self.visible_on) |v_out| {
                   if (out != v_out.wlr_output) continue;
                } else if (self.server.display_mode != .spanned) continue;
            }

            const state = layer.wlr_layer_surface.current;
            if (state.exclusive_zone <= 0) continue;

            const anchor = state.anchor;
            if (anchor.top and !anchor.bottom) {
                usable.y += @as(i32, @intCast(state.exclusive_zone));
                usable.height -= @as(i32, @intCast(state.exclusive_zone));
            } else if (anchor.bottom and !anchor.top) {
                usable.height -= @as(i32, @intCast(state.exclusive_zone));
            } else if (anchor.left and !anchor.right) {
                usable.x += @as(i32, @intCast(state.exclusive_zone));
                usable.width -= @as(i32, @intCast(state.exclusive_zone));
            } else if (anchor.right and !anchor.left) {
                usable.width -= @as(i32, @intCast(state.exclusive_zone));
            }
        }
        
        return usable;
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
