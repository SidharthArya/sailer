const std = @import("std");
const wlr = @import("wlroots");

const View = @import("../View.zig");
const Workspace = @import("../Workspace.zig").Workspace;

pub const Ribbon = @import("Ribbon.zig").Ribbon;
pub const Tiling = @import("Tiling.zig").Tiling;
pub const SmartView = @import("SmartView.zig").SmartView;
pub const Floating = @import("Floating.zig").Floating;

pub const Layout = union(enum) {
    ribbon: Ribbon,
    tiling: Tiling,
    smart_view: SmartView,
    floating: Floating,

    pub fn arrange(self: *Layout, ws: *Workspace, box: wlr.Box) void {
        switch (self.*) {
            inline else => |*l| l.arrange(ws, box),
        }
    }

    pub fn name(self: Layout) []const u8 {
        return switch (self) {
            .ribbon => "ribbon",
            .tiling => "tiling",
            .smart_view => "smart_view",
            .floating => "floating",
        };
    }
};
