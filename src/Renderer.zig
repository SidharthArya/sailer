const std = @import("std");
const c = @import("c.zig").c;

pub const Renderer = struct {
    ft_library: c.FT_Library,
    ft_face: c.FT_Face,

    pub fn init(font_path: []const u8, font_size: u32) !Renderer {
        var ft_library: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&ft_library) != 0) return error.FreeTypeInitFailed;
        
        var ft_face: c.FT_Face = undefined;
        const font_path_z = try std.heap.c_allocator.dupeZ(u8, font_path);
        defer std.heap.c_allocator.free(font_path_z);
        if (c.FT_New_Face(ft_library, font_path_z, 0, &ft_face) != 0) {
            _ = c.FT_Done_FreeType(ft_library);
            return error.FontLoadFailed;
        }
        _ = c.FT_Set_Pixel_Sizes(ft_face, 0, font_size);

        return Renderer{
            .ft_library = ft_library,
            .ft_face = ft_face,
        };
    }

    pub fn deinit(self: *Renderer) void {
        _ = c.FT_Done_Face(self.ft_face);
        _ = c.FT_Done_FreeType(self.ft_library);
    }

    /// Blend a color onto the destination pixel buffer
    // TODO: This renders one glyph at a time with no glyph caching — add a glyph cache to avoid
    //       re-rasterizing the same characters on every bar refresh.
    pub fn drawText(self: *Renderer, pixels: [*]u32, stride_px: i32, text_str: []const u8, x: i32, y: i32, color_raw: c.pixman_color_t, width: i32, height: i32) void {
        const r_s = @as(u32, color_raw.red >> 8);
        const g_s = @as(u32, color_raw.green >> 8);
        const b_s = @as(u32, color_raw.blue >> 8);

        var pen_x = x;
        // TODO: Only ASCII characters are handled — add UTF-8 decoding for proper Unicode support.
        for (text_str) |char| {
            if (c.FT_Load_Char(self.ft_face, char, c.FT_LOAD_RENDER) != 0) continue;
            const glyph = self.ft_face.*.glyph.*;
            const bitmap = glyph.bitmap;

            var r: u32 = 0;
            while (r < bitmap.rows) : (r += 1) {
                var col: u32 = 0;
                while (col < bitmap.width) : (col += 1) {
                    const alpha = bitmap.buffer[r * @as(u32, @intCast(bitmap.pitch)) + col];
                    if (alpha == 0) continue;

                    const px = pen_x + glyph.bitmap_left + @as(i32, @intCast(col));
                    const py = y - glyph.bitmap_top + @as(i32, @intCast(r));

                    if (px >= 0 and px < width and py >= 0 and py < height) {
                        const offset = @as(usize, @intCast(py * stride_px + px));
                        const dst = pixels[offset];

                        // Extract dst components (XRGB -> R, G, B)
                        const r_d = (dst >> 16) & 0xFF;
                        const g_d = (dst >> 8) & 0xFF;
                        const b_d = dst & 0xFF;

                        const a = @as(u32, alpha);
                        const inv_a = 255 - a;

                        // Alpha blend: (src * alpha + dst * (255 - alpha)) / 255
                        const r_out = (r_s * a + r_d * inv_a) / 255;
                        const g_out = (g_s * a + g_d * inv_a) / 255;
                        const b_out = (b_s * a + b_d * inv_a) / 255;

                        pixels[offset] = (r_out << 16) | (g_out << 8) | b_out;
                    }
                }
            }
            pen_x += @intCast(@divTrunc(glyph.advance.x, 64));
        }
    }
};
