const std = @import("std");
const wlr = @import("wlroots");
const Server = @import("Server.zig").Server;
const Output = @import("Output.zig").Output;

pub const Screenshot = struct {
    pub fn captureOutput(allocator: std.mem.Allocator, renderer: *wlr.Renderer, wlr_output: *wlr.Output) ![]u8 {
        _ = allocator;
        _ = renderer;
        _ = wlr_output;
        // FIXME: renderer.readPixels was removed in wlroots 0.19.
        // Implementation needs migration to wlr_scene_output capture or screencopy-v1.
        return error.UnsupportedInWlroots019;
    }
};
