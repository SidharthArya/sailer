const std = @import("std");
const posix = std.posix;
const wlr = @import("wlroots");
const Shm = @import("Shm.zig");

const c = @import("c.zig").c;

pub const Screenshot = struct {
    pub fn captureOutput(renderer: *wlr.Renderer, output: *wlr.Output, scene: *wlr.Scene) !void {
        _ = renderer;
        const width = output.width;
        const height = output.height;

        // 1. Create SHM buffer
        // DRM_FORMAT_XRGB8888 is 0x34325258
        const format: u32 = 0x34325258; // DRM_FORMAT_XRGB8888
        const shm_buf = try Shm.ShmBuffer.create(width, height, format);
        defer shm_buf.destroy();

        // 2. Get SceneOutput
        const scene_output = scene.getSceneOutput(output) orelse return error.SceneOutputNotFound;
        
        // 3. Prepare an output state with our buffer
        var state: c.wlr_output_state = undefined;
        c.wlr_output_state_init(&state);
        defer c.wlr_output_state_finish(&state);

        // Set the buffer in the state.
        // We use the raw pointers for C functions.
        const wlr_buf_ptr: *c.wlr_buffer = @ptrCast(shm_buf.getWlrBuffer());
        c.wlr_output_state_set_buffer(&state, wlr_buf_ptr);

        // 4. Render the scene graph into the buffer
        // We need the raw scene_output pointer.
        // The Zig wrapper often has a .ptr field.
        const scene_output_ptr: *c.wlr_scene_output = @ptrCast(scene_output);

        if (!c.wlr_scene_output_build_state(scene_output_ptr, &state, null)) {
            return error.BuildStateFailed;
        }

        // 5. Save the buffer content as PPM
        const timestamp = std.time.timestamp();
        var name_buf: [128]u8 = undefined;
        const filename = try std.fmt.bufPrint(&name_buf, "/tmp/sailer-screenshot-{d}.ppm", .{timestamp});
        
        try shm_buf.saveAsPpm(filename);

        std.log.info("Screenshot saved to {s}", .{filename});
    }
};
