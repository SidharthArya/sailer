const std = @import("std");
const wlr = @import("wlroots");
const View = @import("../View.zig");
const Workspace = @import("../Workspace.zig").Workspace;

pub const Ribbon = struct {
    pub fn arrange(self: *Ribbon, ws: *Workspace, box: wlr.Box) void {
        var current_x: i32 = 0;

        // Layout windows left-to-right (tail→head order)
        var it = ws.views.link.prev;
        while (it != &ws.views.link) : (it = it.?.prev) {
            const view: *View.Toplevel = @fieldParentPtr("link", it.?);
            if (!view.mapped or view.hidden) {
                if (view.hidden) view.scene_tree.node.setEnabled(false);
                continue;
            }
            view.scene_tree.node.setEnabled(true);

            // Floating windows or the currently grabbed window stay at their own x/y
            if (view.is_floating or view.server.grabbed_view == view) {
                view.scene_tree.node.setPosition(view.x, view.y);
                continue;
            }

            const gap = ws.server.config.gap;
            const target_width: i32 = if (box.width > 0) @divTrunc(box.width * view.width_percent, 100) else 100;
            const target_height: i32 = @max(1, box.height);

            var width: i32 = target_width - gap * 2;
            var height: i32 = @max(1, target_height - gap * 2);

            const min_w = if (view.xdg_toplevel.current.min_width > 0 and view.xdg_toplevel.current.min_width < 10000) view.xdg_toplevel.current.min_width else 0;
            const min_h = if (view.xdg_toplevel.current.min_height > 0 and view.xdg_toplevel.current.min_height < 10000) view.xdg_toplevel.current.min_height else 0;
            const max_w = if (view.xdg_toplevel.current.max_width > 0 and view.xdg_toplevel.current.max_width < 10000) view.xdg_toplevel.current.max_width else 0;
            const max_h = if (view.xdg_toplevel.current.max_height > 0 and view.xdg_toplevel.current.max_height < 10000) view.xdg_toplevel.current.max_height else 0;

            if (min_w > 0) width = @max(width, min_w);
            if (max_w > 0) width = @min(width, @as(i32, @intCast(max_w)));
            if (min_h > 0) height = @max(height, min_h);
            if (max_h > 0) height = @min(height, @as(i32, @intCast(max_h)));

            const bw = view.border_width;
            const xdg_w = @max(1, width - 2 * bw);
            const xdg_h = @max(1, height - 2 * bw);

            if (xdg_w > 10000 or xdg_h > 10000) {
                std.log.err("Ribbon: refusing extreme dimensions {d}x{d}", .{ xdg_w, xdg_h });
                continue;
            }

            if (view.xdg_toplevel.current.width != xdg_w or view.xdg_toplevel.current.height != xdg_h) {
                _ = wlr.XdgToplevel.setSize(view.xdg_toplevel, xdg_w, xdg_h);
            }

            view.updateLayout(width, height);

            const offset_x = @divTrunc(target_width - width, 2);
            const offset_y = @divTrunc(target_height - height, 2);

            // Store unscrolled position — scroll is applied via scene_tree position below
            view.x = current_x + offset_x;
            view.y = offset_y;

            // Position relative to scene tree (scroll applied at scene tree level)
            view.scene_tree.node.setPosition(view.x, view.y);

            current_x += target_width;
        }

        self.clampScroll(ws, box);

        // Apply scroll: shift the entire workspace scene tree left/right
        ws.scene_tree.node.setPosition(box.x + ws.scroll_offset_x, box.y);
    }

    fn clampScroll(_: *Ribbon, ws: *Workspace, box: wlr.Box) void {
        var total_width: i32 = 0;
        var it = ws.views.link.prev;
        while (it != &ws.views.link) : (it = it.?.prev) {
            const view: *View.Toplevel = @fieldParentPtr("link", it.?);
            if (!view.mapped or view.hidden or view.is_floating) continue;
            total_width += @divTrunc(box.width * view.width_percent, 100);
        }

        // scroll_offset_x is negative to scroll right (reveal windows to the right)
        // min_scroll: most negative — last window right-aligned
        // max_scroll: 0 — first window left-aligned
        const min_scroll: i32 = if (total_width > box.width) box.width - total_width else 0;
        const max_scroll: i32 = 0;

        if (ws.scroll_offset_x < min_scroll) ws.scroll_offset_x = min_scroll;
        if (ws.scroll_offset_x > max_scroll) ws.scroll_offset_x = max_scroll;
    }

    pub fn ensureViewVisible(self: *Ribbon, ws: *Workspace, view: *View.Toplevel) void {
        if (view.is_floating) return;

        // Use getUsableArea to match the same box used in arrange()
        const box = ws.getUsableArea();
        if (box.width <= 0) return;

        const view_width: i32 = @divTrunc(box.width * view.width_percent, 100);

        // Center the focused window in the viewport (niri/paperwm style)
        const target_scroll = @divTrunc(box.width - view_width, 2) - view.x;

        if (target_scroll != ws.scroll_offset_x) {
            ws.scroll_offset_x = target_scroll;
            self.clampScroll(ws, box);
            ws.scene_tree.node.setPosition(box.x + ws.scroll_offset_x, box.y);
        }
    }
};
