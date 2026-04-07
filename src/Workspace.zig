const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("Server.zig").Server;
const View = @import("View.zig");
const Layout = @import("layouts/index.zig").Layout;
const LayerSurface = @import("LayerShell.zig").LayerSurface;
const LayoutKind = @import("Config.zig").LayoutKind;

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
    prev_layout: ?Layout = null,

    pub fn init(server: *Server, name: []const u8) !*Workspace {
        const workspace = try std.heap.c_allocator.create(Workspace);
        const scene_tree = try server.window_tree.createSceneTree();
        scene_tree.node.setEnabled(true);
        const initial_layout: Layout = switch (server.config.default_layout) {
            .ribbon => .{ .ribbon = .{} },
            .tiling => .{ .tiling = .{} },
            .floating => .{ .floating = .{} },
            .smart_view => .{ .smart_view = .{} },
        };
        workspace.* = .{
            .server = server,
            .name = name,
            .scene_tree = scene_tree,
            .visible_on = null,
            .layout = initial_layout,
        };
        workspace.views.init();
        workspace.focus_history.init();
        return workspace;
    }

    pub fn arrange(self: *Workspace) void {
        const layout_box = self.getUsableArea();
        
        // Skip arrangement if dimensions are garbage (e.g. from uninitialized output layout or excessive shrinking)
        // TODO: The magic constant 10000 for height sanity check is fragile — derive a proper upper bound.
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
                    // Workspace-relative equivalent of its own absolute position is (0,0) as its node is at (0,0) in spanned mode
                    full_box.x = 0;
                    full_box.y = 0;
                } else if (self.visible_on) |output| {
                    self.server.output_layout.getBox(output.wlr_output, &full_box);
                    // Workspace-relative equivalent of its own absolute position is (0,0) as its node is at (output.x, output.y)
                    full_box.x = 0;
                    full_box.y = 0;
                }

                toplevel.x = full_box.x;
                toplevel.y = full_box.y;
                toplevel.scene_tree.node.setPosition(toplevel.x, toplevel.y);
                toplevel.updateLayout(full_box.width, full_box.height);
                _ = toplevel.xdg_toplevel.setSize(full_box.width, full_box.height);
                toplevel.scene_tree.node.raiseToTop();
                break;
            }

            if (toplevel.is_maximized) {
                toplevel.x = layout_box.x;
                toplevel.y = layout_box.y;
                toplevel.scene_tree.node.setPosition(toplevel.x, toplevel.y);
                toplevel.updateLayout(layout_box.width, layout_box.height);
                _ = toplevel.xdg_toplevel.setSize(layout_box.width, layout_box.height);
                toplevel.scene_tree.node.raiseToTop();
                break;
            }
        }

        self.layout.arrange(self, layout_box);
        self.server.refreshBars();
    }

    pub fn getUsableArea(self: *Workspace) wlr.Box {
        var box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0};
        if (self.server.display_mode == .spanned) {
            self.server.output_layout.getBox(null, &box);
        } else if (self.visible_on) |output| {
            self.server.output_layout.getBox(output.wlr_output, &box);
            if (self.server.display_mode == .discrete) {
                box.x = 0;
                box.y = 0;
            }
        } else return box;

        if (box.width <= 0 or box.height <= 0) return box;

        var usable = box;
        
        // Subtract hardcoded bar for now (backward compatibility)
        // TODO: Remove this hardcoded bar subtraction once all bar heights are tracked via Layer Shell exclusive zones.
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

        // Find focused view — use focus_history as it's more reliable than seat surface lookup
        var focused: ?*View.Toplevel = null;
        var it = self.focus_history.link.next;
        while (it != &self.focus_history.link) : (it = it.?.next) {
            const candidate: *View.Toplevel = @fieldParentPtr("focus_link", it.?);
            if (candidate.mapped and !candidate.hidden) {
                focused = candidate;
                break;
            }
        }

        if (focused) |f| {
            if (delta > 0) {
                // focus_right: ribbon iterates link.prev left-to-right, so right = link.prev
                var target = f.link.prev.?;
                while (target != &self.views.link) {
                    const next_v: *View.Toplevel = @fieldParentPtr("link", target);
                    if (next_v.mapped and !next_v.hidden and next_v.is_floating == f.is_floating) {
                        self.server.focusView(next_v, next_v.xdg_toplevel.base.surface);
                        return;
                    }
                    target = target.prev.?;
                }
                self.ensureViewVisible(f);
            } else {
                // focus_left: left = link.next
                var target = f.link.next.?;
                while (target != &self.views.link) {
                    const prev_v: *View.Toplevel = @fieldParentPtr("link", target);
                    if (prev_v.mapped and !prev_v.hidden and prev_v.is_floating == f.is_floating) {
                        self.server.focusView(prev_v, prev_v.xdg_toplevel.base.surface);
                        return;
                    }
                    target = target.next.?;
                }
                self.ensureViewVisible(f);
            }
        } else {
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

    pub fn resizeView(self: *Workspace, view: *View.Toplevel, delta: i32) void {
        const current = view.width_percent;
        view.width_percent = @as(i32, @intCast(@max(10, @min(100, current + delta))));
        self.arrange();
    }

    pub fn moveView(self: *Workspace, view: *View.Toplevel, delta: i32) void {
        if (self.layout != .floating) return;
        // TODO: The step size of 20px is hardcoded — make it configurable or proportional to output size.
        const step = 20;
        switch (delta) {
            -1 => view.x -= step, // left
            1 => view.x += step,  // right
            -2 => view.y -= step, // up
            2 => view.y += step,  // down
            else => {},
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
        std.heap.c_allocator.free(self.name);
        std.heap.c_allocator.destroy(self);
    }
};
