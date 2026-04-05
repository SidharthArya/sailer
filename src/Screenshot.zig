const std = @import("std");
const posix = std.posix;
const wlr = @import("wlroots");
const Shm = @import("Shm.zig");

const c = @import("c.zig").c;

pub const Screenshot = struct {
    /// Capture an output and save it as a PPM file to /tmp.
    pub fn captureOutput(renderer: *wlr.Renderer, output: *wlr.Output, scene: *wlr.Scene) !void {
        _ = renderer;
        const scene_output = scene.getSceneOutput(output) orelse return error.SceneOutputNotFound;
        const raw = try captureToBytes(std.heap.c_allocator, scene_output, output.width, output.height);
        defer std.heap.c_allocator.free(raw);

        const timestamp = std.time.timestamp();
        var name_buf: [128]u8 = undefined;
        const filename = try std.fmt.bufPrint(&name_buf, "/tmp/sailer-screenshot-{d}.ppm", .{timestamp});
        try savePpm(filename, raw, output.width, output.height);
        std.log.info("Screenshot saved to {s}", .{filename});
    }

    /// Capture a scene_output and return raw XRGB8888 pixel bytes.
    /// Caller owns the returned slice.
    pub fn captureToBytes(allocator: std.mem.Allocator, scene_output: *wlr.SceneOutput, width: i32, height: i32) ![]u8 {
        const format: u32 = 0x34325258; // DRM_FORMAT_XRGB8888
        const shm_buf = try Shm.ShmBuffer.create(width, height, format);
        defer shm_buf.destroy();

        var state: c.wlr_output_state = undefined;
        c.wlr_output_state_init(&state);
        defer c.wlr_output_state_finish(&state);

        const wlr_buf_ptr: *c.wlr_buffer = @ptrCast(shm_buf.getWlrBuffer());
        c.wlr_output_state_set_buffer(&state, wlr_buf_ptr);

        const scene_output_ptr: *c.wlr_scene_output = @ptrCast(scene_output);

        // Mark the entire output as damaged so build_state renders everything
        // into the fresh buffer rather than skipping undamaged regions.
        c.wlr_damage_ring_add_whole(&scene_output_ptr.*.damage_ring);

        if (!c.wlr_scene_output_build_state(scene_output_ptr, &state, null)) {
            return error.BuildStateFailed;
        }

        // Copy pixel data into an owned slice
        const stride = @as(usize, @intCast(width)) * 4;
        const size = stride * @as(usize, @intCast(height));
        const out = try allocator.alloc(u8, size);
        @memcpy(out, shm_buf.data[0..size]);
        return out;
    }

    fn savePpm(filename: []const u8, data: []const u8, width: i32, height: i32) !void {
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();

        var write_buf: [4096]u8 = undefined;
        var f_writer = file.writer(&write_buf);
        const writer = &f_writer.interface;

        try writer.print("P6\n{d} {d}\n255\n", .{ width, height });

        const stride = @as(usize, @intCast(width)) * 4;
        var y: usize = 0;
        while (y < @as(usize, @intCast(height))) : (y += 1) {
            var x: usize = 0;
            while (x < @as(usize, @intCast(width))) : (x += 1) {
                const offset = y * stride + x * 4;
                // XRGB8888 little-endian: [B, G, R, X]
                try writer.writeByte(data[offset + 2]); // R
                try writer.writeByte(data[offset + 1]); // G
                try writer.writeByte(data[offset + 0]); // B
            }
        }
        try f_writer.end();
    }
};
