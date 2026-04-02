const std = @import("std");
const wlr = @import("wlroots");
const View = @import("../View.zig");
const Workspace = @import("../Workspace.zig").Workspace;

pub const Ribbon = struct {
    pub fn arrange(_: *Ribbon, ws: *Workspace, box: wlr.Box) void {
        var current_x: i32 = 0;

        // Ribbon order (Left-to-Right): Tail (prev) -> Head (next)
        var it = ws.views.link.prev;
        while (it != &ws.views.link) : (it = it.?.prev) {
            const view: *View.Toplevel = @fieldParentPtr("link", it.?);
            if (!view.mapped) {
                continue;
            }

            const width: i32 = @divTrunc(box.width * view.width_percent, 100);
            const height: i32 = box.height;

            // Smart Resize: Only send configure if target dimensions actually changed.
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

        const min_scroll = box.width - total_width;
        if (total_width > box.width) {
            if (ws.scroll_offset_x < min_scroll) {
                ws.scroll_offset_x = min_scroll;
            }
        } else {
            ws.scroll_offset_x = 0;
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
