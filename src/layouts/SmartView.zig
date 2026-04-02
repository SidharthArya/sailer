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
        const width = @divTrunc(box.width - (cols + 1) * gap, cols);
        const height = @divTrunc(box.height - (rows + 1) * gap, rows);

        var i: i32 = 0;
        it = ws.views.link.prev; // Ribbon order
        while (it != &ws.views.link) : (it = it.?.prev) {
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

        if (ws.server.display_mode == .discrete) {
            if (ws.visible_on) |output| {
                if (ws.server.output_layout.get(output.wlr_output)) |l_output| {
                    ws.scene_tree.node.setPosition(l_output.x, l_output.y);
                }
            }
        } else {
            ws.scene_tree.node.setPosition(0, 0);
        }
    }
};
