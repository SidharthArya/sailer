const std = @import("std");
const wlr = @import("wlroots");
const View = @import("../View.zig");
const Workspace = @import("../Workspace.zig").Workspace;

/// XMonad-style "Tall" tiling layout.
/// One master window on the left, remaining windows stacked vertically on the right.
pub const Tiling = struct {
    /// Width ratio of the master window (0.0 - 1.0).
    master_ratio: f32 = 0.55,

    pub fn arrange(self: *Tiling, ws: *Workspace, box: wlr.Box) void {
        const gap = ws.server.config.gap;

        // Collect all mapped, non-floating, non-hidden views in order
        var views: [64]*View.Toplevel = undefined;
        var count: usize = 0;

        var it = ws.views.link.prev;
        while (it != &ws.views.link) : (it = it.?.prev) {
            const view: *View.Toplevel = @fieldParentPtr("link", it.?);
            if (!view.mapped or view.hidden or view.is_floating) {
                if (view.hidden) view.scene_tree.node.setEnabled(false);
                continue;
            }
            view.scene_tree.node.setEnabled(true);
            if (count < views.len) {
                views[count] = view;
                count += 1;
            }
        }

        if (count == 0) {
            ws.scene_tree.node.setPosition(box.x, box.y);
            return;
        }

        // Usable area with outer gap
        const area = wlr.Box{
            .x = gap,
            .y = gap,
            .width = box.width - gap * 2,
            .height = box.height - gap * 2,
        };

        if (count == 1) {
            // Single window takes full area
            placeView(views[0], area, gap);
        } else {
            // Master on the left — overlap by border_width when gap=0 so borders share pixels
            const bw = views[0].border_width;
            const overlap = if (gap == 0) bw else 0;

            const master_width = @as(i32, @intFromFloat(@as(f32, @floatFromInt(area.width)) * self.master_ratio));
            const stack_x = area.x + master_width - overlap;
            const stack_width = area.width - master_width + overlap;

            const master_box = wlr.Box{
                .x = area.x,
                .y = area.y,
                .width = master_width,
                .height = area.height,
            };
            placeView(views[0], master_box, gap);

            // Stack on the right — divide height equally, overlap borders vertically
            const stack_count: i32 = @intCast(count - 1);
            const total_gaps = if (gap == 0) -overlap * (stack_count - 1) else gap * (stack_count - 1);
            const each_height = @divTrunc(area.height - total_gaps, stack_count);
            const y_step = each_height - overlap;

            for (1..count) |i| {
                const idx: i32 = @intCast(i - 1);
                const stack_box = wlr.Box{
                    .x = stack_x,
                    .y = area.y + idx * (y_step + gap),
                    .width = stack_width,
                    .height = each_height,
                };
                placeView(views[i], stack_box, gap);
            }
        }

        ws.scene_tree.node.setPosition(box.x, box.y);
    }

    /// Increase or decrease the master ratio by a step.
    pub fn adjustMasterRatio(self: *Tiling, delta: f32) void {
        self.master_ratio = std.math.clamp(self.master_ratio + delta, 0.1, 0.9);
    }
};

fn placeView(view: *View.Toplevel, box: wlr.Box, gap: i32) void {
    _ = gap;
    var width: i32 = @max(1, box.width);
    var height: i32 = @max(1, box.height);

    const min_w = view.xdg_toplevel.current.min_width;
    const min_h = view.xdg_toplevel.current.min_height;
    const max_w = view.xdg_toplevel.current.max_width;
    const max_h = view.xdg_toplevel.current.max_height;

    if (min_w > 0) width = @max(width, @as(i32, @intCast(min_w)));
    if (max_w > 0) width = @min(width, @as(i32, @intCast(max_w)));
    if (min_h > 0) height = @max(height, @as(i32, @intCast(min_h)));
    if (max_h > 0) height = @min(height, @as(i32, @intCast(max_h)));

    const bw = view.border_width;
    const xdg_w = @max(1, width - 2 * bw);
    const xdg_h = @max(1, height - 2 * bw);

    if (view.xdg_toplevel.current.width != xdg_w or view.xdg_toplevel.current.height != xdg_h) {
        _ = wlr.XdgToplevel.setSize(view.xdg_toplevel, xdg_w, xdg_h);
    }

    view.updateLayout(width, height);
    view.scene_tree.node.setPosition(box.x, box.y);
    view.x = box.x;
    view.y = box.y;
}
