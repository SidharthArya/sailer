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
        workspace.* = .{
            .server = server,
            .name = name,
            // Create a dedicated scene tree for this workspace.
            // All windows in this workspace will be children of this tree.
            .scene_tree = try server.scene.tree.createSceneTree(),
            .visible_on = null,
            .layout_mode = .ribbon,
            .tiling_root = null,
        };
        workspace.views.init();
        // Hide by default
        workspace.scene_tree.node.setEnabled(false);
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
        const output = self.visible_on orelse return;

        var box: wlr.Box = undefined;
        self.server.output_layout.getBox(output.wlr_output, &box);

        var current_x: i32 = 0;

        // Ribbon order (Left-to-Right): Tail (prev) -> Head (next)
        var it = self.views.link.prev;
        while (it != &self.views.link) : (it = it.?.prev) {
            const view: *View.Toplevel = @fieldParentPtr("link", it.?);
            if (!view.mapped) {
                it = it.?.prev;
                continue;
            }

            const width: i32 = @divTrunc(box.width * view.width_percent, 100);
            const height: i32 = box.height;

            _ = wlr.XdgToplevel.setSize(view.xdg_toplevel, width, height);
            view.scene_tree.node.setPosition(current_x, 0);

            view.x = current_x;
            view.y = 0;

            current_x += width + 20; // 20px gap
        }

        // Apply scroll offset and output position
        if (self.server.output_layout.get(output.wlr_output)) |l_output| {
            self.scene_tree.node.setPosition(l_output.x - self.scroll_offset_x, l_output.y);
        }
    }

    fn arrangeTiling(self: *Workspace) void {
        const output = self.visible_on orelse return;
        var box: wlr.Box = undefined;
        self.server.output_layout.getBox(output.wlr_output, &box);

        if (self.tiling_root) |root| {
            root.arrange(box);
        }

        // Apply output position (tiling usually handles its own x/y within the box)
        if (self.server.output_layout.get(output.wlr_output)) |l_output| {
            self.scene_tree.node.setPosition(l_output.x, l_output.y);
        }
    }

    fn arrangeSmartView(self: *Workspace) void {
        const output = self.visible_on orelse return;
        var box: wlr.Box = undefined;
        self.server.output_layout.getBox(output.wlr_output, &box);

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

        if (self.server.output_layout.get(output.wlr_output)) |l_output| {
            self.scene_tree.node.setPosition(l_output.x, l_output.y);
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
