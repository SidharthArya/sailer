const std = @import("std");
const wlr = @import("wlroots");
const Shm = @import("Shm.zig");

pub const Screenshot = struct {
    pub fn captureOutput(allocator: std.mem.Allocator, scene_output: *wlr.SceneOutput) ![]u8 {
        const width = scene_output.output.width;
        const height = scene_output.output.height;
        
        // 1. Create a temporary SHM buffer for rendering
        const shm_buf = try Shm.ShmBuffer.create(width, height, 0x34325258); // XRGB8888
        defer shm_buf.wlr_buffer.drop();
        
        // 2. Prepare output state with the buffer
        var state = wlr.Output.State.init();
        defer state.finish();
        
        state.setBuffer(shm_buf.getWlrBuffer());
        
        // 3. Render the scene into the buffer
        if (!scene_output.buildState(&state, null)) {
            return error.SceneBuildStateFailed;
        }
        
        // 4. Wrap the raw pixels in a BMP container
        const header_size = 54;
        const pixel_data_size = shm_buf.data.len;
        const total_size = header_size + pixel_data_size;
        
        var bmp = try allocator.alloc(u8, total_size);
        errdefer allocator.free(bmp);
        
        // BMP Header (Little Endian)
        @memset(bmp[0..header_size], 0);
        bmp[0] = 'B'; bmp[1] = 'M';
        std.mem.writeInt(u32, bmp[2..6], @intCast(total_size), .little);
        std.mem.writeInt(u32, bmp[10..14], header_size, .little);
        
        // DIB Header (BITMAPINFOHEADER)
        std.mem.writeInt(u32, bmp[14..18], 40, .little);
        std.mem.writeInt(i32, bmp[18..22], width, .little);
        std.mem.writeInt(i32, bmp[22..26], -height, .little); // Top-down
        std.mem.writeInt(u16, bmp[26..28], 1, .little);
        std.mem.writeInt(u16, bmp[28..30], 32, .little); // 32bpp (XRGB)
        std.mem.writeInt(u32, bmp[34..38], @intCast(pixel_data_size), .little);
        
        @memcpy(bmp[header_size..], shm_buf.data);
        
        return bmp;
    }
};
