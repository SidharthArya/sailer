const std = @import("std");
const wlr = @import("wlroots");
const View = @import("../View.zig");
const Workspace = @import("../Workspace.zig").Workspace;

pub const Floating = struct {
    pub fn arrange(_: *Floating, ws: *Workspace, _: wlr.Box) void {
        var it = ws.views.link.prev;
        while (it != &ws.views.link) : (it = it.?.prev) {
            const view: *View.Toplevel = @fieldParentPtr("link", it.?);
            if (!view.mapped or view.hidden) {
                if (view.hidden) view.scene_tree.node.setEnabled(false);
                continue;
            }
            view.scene_tree.node.setEnabled(true);

            // In floating mode, we just respect the view's own x,y
            view.scene_tree.node.setPosition(view.x, view.y);
        }

    }
};
