const std = @import("std");
const wlr = @import("wlroots");
const View = @import("../View.zig");
const Workspace = @import("../Workspace.zig").Workspace;

pub const SmartView = struct {
    pub fn arrange(_: *SmartView, ws: *Workspace, box: wlr.Box) void {
        var count: i32 = 0;
        var it = ws.views.link.next;
        while (it != &ws.views.link) : (it = it.?.next) count += 1;

        if (count == 0) return;

        const cols = @as(i32, @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(count))))));
        const rows = @divTrunc(count + cols - 1, cols);

        const gap = 40;
        const cell_width = @divTrunc(box.width - (cols + 1) * gap, cols);
        const cell_height = @divTrunc(box.height - (rows + 1) * gap, rows);

        var i: i32 = 0;
        it = ws.views.link.prev; // Ribbon order
        while (it != &ws.views.link) : (it = it.?.prev) {
            const view: *View.Toplevel = @fieldParentPtr("link", it.?);
            if (!view.mapped or view.hidden) {
                if (view.hidden) view.scene_tree.node.setEnabled(false);
                continue;
            }
            view.scene_tree.node.setEnabled(true);

            const r = @divTrunc(i, cols);
            const c = @mod(i, cols);

            var width = cell_width;
            var height = cell_height;

            const min_w = view.xdg_toplevel.current.min_width;
            const min_h = view.xdg_toplevel.current.min_height;
            const max_w = view.xdg_toplevel.current.max_width;
            const max_h = view.xdg_toplevel.current.max_height;

            if (min_w > 0) width = @max(width, min_w);
            if (max_w > 0) width = @min(width, max_w);
            if (min_h > 0) height = @max(height, min_h);
            if (max_h > 0) height = @min(height, max_h);

            const bw = view.border_width;
            const xdg_w = @max(1, width - 2 * bw);
            const xdg_h = @max(1, height - 2 * bw);

            if (view.xdg_toplevel.current.width != xdg_w or view.xdg_toplevel.current.height != xdg_h) {
                _ = wlr.XdgToplevel.setSize(view.xdg_toplevel, xdg_w, xdg_h);
            }

            view.updateLayout(width, height);

            const offset_x = @divTrunc(cell_width - width, 2);
            const offset_y = @divTrunc(cell_height - height, 2);

            const vx = gap + c * (cell_width + gap) + offset_x;
            const vy = gap + r * (cell_height + gap) + offset_y;

            view.scene_tree.node.setPosition(vx, vy);

            view.x = vx;
            view.y = vy;
            i += 1;
        }

        ws.scene_tree.node.setPosition(box.x, box.y);
    }
};
