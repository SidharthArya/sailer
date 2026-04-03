const std = @import("std");
const wlr = @import("wlroots");
const View = @import("../View.zig");
const Workspace = @import("../Workspace.zig").Workspace;

pub const Ribbon = struct {
    pub fn arrange(self: *Ribbon, ws: *Workspace, box: wlr.Box) void {
        var current_x: i32 = 0;

        // Ribbon order (Left-to-Right): Tail (prev) -> Head (next)
        var it = ws.views.link.prev;
        while (it != &ws.views.link) : (it = it.?.prev) {
            const view: *View.Toplevel = @fieldParentPtr("link", it.?);
            if (!view.mapped or view.hidden) {
                if (view.hidden) view.scene_tree.node.setEnabled(false);
                continue;
            }
            view.scene_tree.node.setEnabled(true);

            const target_width: i32 = if (box.width > 0) @divTrunc(box.width * view.width_percent, 100) else 100;
            const target_height: i32 = @max(1, box.height);

            var width = target_width;
            var height = target_height;

            const min_w = if (view.xdg_toplevel.current.min_width < 10000) view.xdg_toplevel.current.min_width else 0;
            const min_h = if (view.xdg_toplevel.current.min_height < 10000) view.xdg_toplevel.current.min_height else 0;
            const max_w = if (view.xdg_toplevel.current.max_width < 10000) view.xdg_toplevel.current.max_width else 0;
            const max_h = if (view.xdg_toplevel.current.max_height < 10000) view.xdg_toplevel.current.max_height else 0;

            if (min_w > 0) width = @max(width, min_w);
            if (max_w > 0) width = @min(width, @max(width, max_w)); // Ensure max is not less than calculated
            if (min_h > 0) height = @max(height, min_h);
            if (max_h > 0) height = @min(height, @max(height, max_h));

            const bw = view.border_width;
            const xdg_w = @max(1, width - 2 * bw);
            const xdg_h = @max(1, height - 2 * bw);

            if (xdg_w > 10000 or xdg_h > 10000) {
                std.log.err("Refusing to resize view to extreme dimensions: {d}x{d}", .{xdg_w, xdg_h});
                continue;
            }

            // Smart Resize: Only send configure if target dimensions actually changed.
            if (view.xdg_toplevel.current.width != xdg_w or view.xdg_toplevel.current.height != xdg_h) {
                _ = wlr.XdgToplevel.setSize(view.xdg_toplevel, xdg_w, xdg_h);
            }

            view.updateLayout(width, height);

            // Center within its logical slot if it's smaller than its allocated width
            const offset_x = @divTrunc(target_width - width, 2);
            const offset_y = @divTrunc(target_height - height, 2);

            view.scene_tree.node.setPosition(current_x + offset_x, offset_y);
            std.log.debug("Ribbon arrange: {s} -> {d},{d} (size {d}x{d})", .{ @as([*:0]const u8, @ptrCast(view.xdg_toplevel.title orelse "unnamed")), current_x + offset_x, offset_y, width, height });

            view.x = current_x + offset_x;
            view.y = offset_y;

            current_x += target_width + 20; // 20px gap
        }

        self.clampScroll(ws, box);

        // Apply scroll offset and output position
        if (ws.server.display_mode == .discrete) {
            if (ws.visible_on) |output| {
                if (ws.server.output_layout.get(output.wlr_output)) |l_output| {
                    ws.scene_tree.node.setPosition(l_output.x + ws.scroll_offset_x, l_output.y);
                }
            }
        } else {
            ws.scene_tree.node.setPosition(ws.scroll_offset_x, 0);
        }
    }
    fn clampScroll(_: *Ribbon, ws: *Workspace, box: wlr.Box) void {
        // Never allow positive scroll (pushed to right)
        if (ws.scroll_offset_x > 0) {
            ws.scroll_offset_x = 0;
        }

        // Calculate total width of all windows to prevent over-scrolling into empty space
        var total_width: i32 = 0;
        var it = ws.views.link.prev;
        while (it != &ws.views.link) : (it = it.?.prev) {
            const view: *View.Toplevel = @fieldParentPtr("link", it.?);
            if (!view.mapped) continue;
            const width: i32 = @divTrunc(box.width * view.width_percent, 100);
            total_width += width + 20;
        }

        const max_scroll = @max(0, box.width - total_width);
        const min_scroll = if (total_width > box.width) box.width - total_width else 0;

        if (ws.scroll_offset_x < min_scroll) {
            ws.scroll_offset_x = min_scroll;
        } else if (ws.scroll_offset_x > max_scroll) {
            ws.scroll_offset_x = max_scroll;
        }
    }

    pub fn ensureViewVisible(self: *Ribbon, ws: *Workspace, view: *View.Toplevel) void {
        var box: wlr.Box = undefined;
        if (ws.server.display_mode == .spanned) {
            ws.server.output_layout.getBox(null, &box);
        } else if (ws.visible_on) |output| {
            ws.server.output_layout.getBox(output.wlr_output, &box);
        } else return;

        if (box.width <= 0) return;

        const width: i32 = @divTrunc(box.width * view.width_percent, 100);
        const view_x_start = view.x;
        const view_x_end = view.x + width;

        const visible_x_start = -ws.scroll_offset_x;
        const visible_x_end = -ws.scroll_offset_x + box.width;

        var new_scroll = ws.scroll_offset_x;

        // If the view is completely or partially off-screen
        if (view_x_start < visible_x_start) {
            // Priority 1: Align left edge
            new_scroll = -view_x_start;
        } else if (view_x_end > visible_x_end) {
            // Priority 2: Align right edge
            new_scroll = box.width - view_x_end;
        }

        if (new_scroll != ws.scroll_offset_x) {
            ws.scroll_offset_x = new_scroll;
            self.clampScroll(ws, box);
            std.log.info("info(sailer): Workspace '{s}' scrolling to focus: {} (View at {})", .{ ws.name, ws.scroll_offset_x, view_x_start });
            ws.arrange();
        }
    }
};
