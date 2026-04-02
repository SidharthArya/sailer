const std = @import("std");
const wlr = @import("wlroots");
const View = @import("../View.zig");
const Workspace = @import("../Workspace.zig").Workspace;

pub const Floating = struct {
    pub fn arrange(_: *Floating, ws: *Workspace, _: wlr.Box) void {
        var it = ws.views.link.prev;
        while (it != &ws.views.link) : (it = it.?.prev) {
            const view: *View.Toplevel = @fieldParentPtr("link", it.?);
            if (!view.mapped) continue;

            // In floating mode, we just respect the view's own x,y
            view.scene_tree.node.setPosition(view.x, view.y);
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
