const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("Server.zig").Server;
const View = @import("View.zig");
const TilingNode = @import("Tiling.zig").TilingNode;

pub const LayoutMode = enum { ribbon, tiling, smart_view };

pub const Workspace = struct {
    server: *Server,
    name: []const u8,

    // In a real tiling WM, we will use a tree or specific layout structures.
    // For now, we will maintain a list of views in this workspace.
    views: wl.list.Head(View.Toplevel, .link) = undefined,
    scene_tree: *wlr.SceneTree,
    visible_on: ?*@import("Output.zig").Output = null,
    scroll_offset_x: i32 = 0,

    layout_mode: LayoutMode = .ribbon,
    tiling_root: ?*TilingNode = null,

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
            .layout_mode = .ribbon,
            .tiling_root = null,
        };
        workspace.views.init();
        return workspace;
    }

    pub fn arrange(self: *Workspace) void {
        switch (self.layout_mode) {
            .ribbon => self.arrangeRibbon(),
            .tiling => self.arrangeTiling(),
            .smart_view => self.arrangeSmartView(),
        }
    }

    fn arrangeRibbon(self: *Workspace) void {
        var box: wlr.Box = undefined;
        if (self.server.display_mode == .spanned) {
            self.server.output_layout.getBox(null, &box);
        } else if (self.visible_on) |output| {
            self.server.output_layout.getBox(output.wlr_output, &box);
        } else return;

        var current_x: i32 = 0;

        // Ribbon order (Left-to-Right): Tail (prev) -> Head (next)
        var it = self.views.link.prev;
        while (it != &self.views.link) : (it = it.?.prev) {
            const view: *View.Toplevel = @fieldParentPtr("link", it.?);
            if (!view.mapped) {
                continue;
            }

            const width: i32 = @divTrunc(box.width * view.width_percent, 100);
            const height: i32 = box.height;

            // Smart Resize: Only send configure if target dimensions actually changed.
            // This prevents "Primary buffer size mismatch" spam and helps stability.
            if (view.xdg_toplevel.current.width != width or view.xdg_toplevel.current.height != height) {
                _ = wlr.XdgToplevel.setSize(view.xdg_toplevel, width, height);
            }
            view.scene_tree.node.setPosition(current_x, 0);
            std.log.debug("Ribbon arrange: {s} -> {d},0 (size {d}x{d})", .{ @as([*:0]const u8, @ptrCast(view.xdg_toplevel.title orelse "unnamed")), current_x, width, height });

            view.x = current_x;
            view.y = 0;

            current_x += width + 20; // 20px gap
        }

        // Apply scroll offset and output position
        if (self.server.display_mode == .discrete) {
            if (self.visible_on) |output| {
                if (self.server.output_layout.get(output.wlr_output)) |l_output| {
                    self.scene_tree.node.setPosition(l_output.x + self.scroll_offset_x, l_output.y);
                    std.log.debug("Workspace '{s}' positioned at {d}+{d},{d}", .{ self.name, l_output.x, self.scroll_offset_x, l_output.y });
                }
            }
        } else {
            self.scene_tree.node.setPosition(self.scroll_offset_x, 0);
        }
    }

    fn clampScroll(self: *Workspace, box: wlr.Box) void {
        // Never allow positive scroll (pushed to right)
        if (self.scroll_offset_x > 0) {
            self.scroll_offset_x = 0;
        }

        // Calculate total width of all windows to prevent over-scrolling into empty space
        var total_width: i32 = 0;
        var it = self.views.link.prev;
        while (it != &self.views.link) : (it = it.?.prev) {
            const view: *View.Toplevel = @fieldParentPtr("link", it.?);
            if (!view.mapped) continue;
            const width: i32 = @divTrunc(box.width * view.width_percent, 100);
            total_width += width + 20;
        }

        const min_scroll = box.width - total_width;
        if (total_width > box.width) {
            if (self.scroll_offset_x < min_scroll) {
                self.scroll_offset_x = min_scroll;
            }
        } else {
            self.scroll_offset_x = 0;
        }
    }

    pub fn ensureViewVisible(self: *Workspace, view: *View.Toplevel) void {
        if (self.layout_mode != .ribbon) return;

        var box: wlr.Box = undefined;
        if (self.server.display_mode == .spanned) {
            self.server.output_layout.getBox(null, &box);
        } else if (self.visible_on) |output| {
            self.server.output_layout.getBox(output.wlr_output, &box);
        } else return;

        if (box.width <= 0) return;

        const width: i32 = @divTrunc(box.width * view.width_percent, 100);
        const view_x_start = view.x;
        const view_x_end = view.x + width;

        const visible_x_start = -self.scroll_offset_x;
        const visible_x_end = -self.scroll_offset_x + box.width;

        var new_scroll = self.scroll_offset_x;

        // If the view is completely or partially off-screen
        if (view_x_start < visible_x_start) {
            // Priority 1: Align left edge
            new_scroll = -view_x_start;
        } else if (view_x_end > visible_x_end) {
            // Priority 2: Align right edge
            new_scroll = box.width - view_x_end;
        }

        if (new_scroll != self.scroll_offset_x) {
            self.scroll_offset_x = new_scroll;
            self.clampScroll(box);
            std.log.info("info(sailer): Workspace '{s}' scrolling to focus: {} (View at {})", .{ self.name, self.scroll_offset_x, view_x_start });
            self.arrange();
        }
    }

    fn arrangeTiling(self: *Workspace) void {
        var box: wlr.Box = undefined;
        if (self.server.display_mode == .spanned) {
            self.server.output_layout.getBox(null, &box);
        } else if (self.visible_on) |output| {
            self.server.output_layout.getBox(output.wlr_output, &box);
        } else return;

        if (self.tiling_root) |root| {
            root.arrange(box);
        }

        if (self.server.display_mode == .discrete) {
            if (self.visible_on) |output| {
                if (self.server.output_layout.get(output.wlr_output)) |l_output| {
                    self.scene_tree.node.setPosition(l_output.x, l_output.y);
                }
            }
        } else {
            self.scene_tree.node.setPosition(0, 0);
        }
    }

    fn arrangeSmartView(self: *Workspace) void {
        var box: wlr.Box = undefined;
        if (self.server.display_mode == .spanned) {
            self.server.output_layout.getBox(null, &box);
        } else if (self.visible_on) |output| {
            self.server.output_layout.getBox(output.wlr_output, &box);
        } else return;

        var count: i32 = 0;
        var it = self.views.link.next;
        while (it != &self.views.link) : (it = it.?.next) count += 1;

        if (count == 0) return;

        const cols = @as(i32, @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(count))))));
        const rows = @divTrunc(count + cols - 1, cols);

        const gap = 40;
        const width = @divTrunc(box.width - (cols + 1) * gap, cols);
        const height = @divTrunc(box.height - (rows + 1) * gap, rows);

        var i: i32 = 0;
        it = self.views.link.prev; // Ribbon order
        while (it != &self.views.link) : (it = it.?.prev) {
            const view: *View.Toplevel = @fieldParentPtr("link", it.?);
            if (!view.mapped) continue;

            const r = @divTrunc(i, cols);
            const c = @mod(i, cols);

            const vx = gap + c * (width + gap);
            const vy = gap + r * (height + gap);

            _ = wlr.XdgToplevel.setSize(view.xdg_toplevel, width, height);
            view.scene_tree.node.setPosition(vx, vy);

            view.x = vx;
            view.y = vy;
            i += 1;
        }

        if (self.server.display_mode == .discrete) {
            if (self.visible_on) |output| {
                if (self.server.output_layout.get(output.wlr_output)) |l_output| {
                    self.scene_tree.node.setPosition(l_output.x, l_output.y);
                }
            }
        } else {
            self.scene_tree.node.setPosition(0, 0);
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
