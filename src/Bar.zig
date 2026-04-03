const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("Server.zig").Server;
const Output = @import("Output.zig").Output;

const c = @cImport({
    @cDefine("WLR_USE_UNSTABLE", "1");
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("pixman.h");
    @cInclude("wlr/types/wlr_shm.h");
    @cInclude("wlr/types/wlr_scene.h");
    @cInclude("wlr/types/wlr_buffer.h");
    @cInclude("wlr/interfaces/wlr_buffer.h");
});

const Shm = @import("Shm.zig");


pub const Bar = struct {
    server: *Server,
    output: *Output,
    scene_tree: *wlr.SceneTree,
    scene_buffer: *wlr.SceneBuffer,
    wlr_buffer: *wlr.Buffer,
    width: i32,
    height: i32,

    ft_library: c.FT_Library,
    ft_face: c.FT_Face,
    
    pub fn create(server: *Server, output: *Output, font_path: []const u8) !*Bar {
        const bar = try std.heap.c_allocator.create(Bar);
        
        var ft_library: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&ft_library) != 0) return error.FreeTypeInitFailed;
        errdefer _ = c.FT_Done_FreeType(ft_library);

        var ft_face: c.FT_Face = undefined;
        const font_path_z = try std.heap.c_allocator.dupeZ(u8, font_path);
        defer std.heap.c_allocator.free(font_path_z);
        if (c.FT_New_Face(ft_library, font_path_z, 0, &ft_face) != 0) {
            std.log.err("Failed to load font: {s}", .{font_path});
            return error.FontLoadFailed;
        }
        _ = c.FT_Set_Pixel_Sizes(ft_face, 0, 14);

        var box: wlr.Box = undefined;
        server.output_layout.getBox(output.wlr_output, &box);

        const width = box.width;
        const height = 24;

        // Use a manual SHM buffer to guarantee CPU access
        const shm_buf = try Shm.ShmBuffer.create(width, height, 0x34325258); // XRGB8888
        const wlr_buffer = shm_buf.getWlrBuffer();
        
        const scene_tree = server.scene.tree.createSceneTree() catch return error.SceneTreeCreateFailed;
        const scene_buffer = try scene_tree.createSceneBuffer(wlr_buffer);
        
        scene_tree.node.setPosition(box.x, box.y);
        scene_tree.node.raiseToTop();

        bar.* = .{
            .server = server,
            .output = output,
            .scene_tree = scene_tree,
            .scene_buffer = scene_buffer,
            .wlr_buffer = wlr_buffer,
            .width = width,
            .height = height,
            .ft_library = ft_library,
            .ft_face = ft_face,
        };

        bar.update();
        return bar;
    }

    pub fn update(self: *Bar) void {
        var data_ptr: *anyopaque = undefined;
        var out_format: u32 = 0;
        var stride: usize = 0;
        // Using SHM buffer guarantees beginDataPtrAccess will work
        if (!self.wlr_buffer.beginDataPtrAccess(3, &data_ptr, &out_format, &stride)) {
             std.log.err("Failed to map status bar buffer for CPU access", .{});
             return;
        }
        
        const pixels = @as([*]u32, @ptrCast(@alignCast(data_ptr)));

        const pix = c.pixman_image_create_bits(
            c.PIXMAN_a8r8g8b8,
            self.width,
            self.height,
            @ptrCast(pixels),
            @intCast(self.width * 4),
        ) orelse return;
        defer _ = c.pixman_image_unref(pix);

        // Catppuccin Mocha Palette
        const pink = c.pixman_color_t{ .red = 0xf5f5, .green = 0xc2c2, .blue = 0xe7e7, .alpha = 0xffff };
        const mauve = c.pixman_color_t{ .red = 0xcbcb, .green = 0xa6a6, .blue = 0xf7f7, .alpha = 0xffff };
        const blue = c.pixman_color_t{ .red = 0x8989, .green = 0xb4b4, .blue = 0xfafa, .alpha = 0xffff };
        const subtext = c.pixman_color_t{ .red = 0xa6a6, .green = 0xadad, .blue = 0xc8c8, .alpha = 0xffff };
        const crust = c.pixman_color_t{ .red = 0x1111, .green = 0x1111, .blue = 0x1b1b, .alpha = 0xffff };
        const base = c.pixman_color_t{ .red = 0x1e1e, .green = 0x1e1e, .blue = 0x2e2e, .alpha = 0xffff };

        // Background (Crust)
        _ = c.pixman_image_fill_rectangles(c.PIXMAN_OP_SRC, pix, &crust, 1, &[_]c.pixman_rectangle16_t{.{
            .x = 0,
            .y = 0,
            .width = @intCast(self.width),
            .height = @intCast(self.height),
        }});

        var x_offset: i32 = 12;
        for (self.server.workspaces, 1..) |ws, i| {
            var label_buf: [4]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, " {d} ", .{i}) catch " ?";
            
            const is_focused = (self.server.focused_workspace == ws);
            const has_views = (ws.views.link.next != &ws.views.link);
            
            if (is_focused) {
                // Focus highlight (Mauve)
                 _ = c.pixman_image_fill_rectangles(c.PIXMAN_OP_OVER, pix, &mauve, 1, &[_]c.pixman_rectangle16_t{.{
                    .x = @intCast(x_offset),
                    .y = 3,
                    .width = 26,
                    .height = @intCast(self.height - 6),
                }});
                self.drawText(pixels, label, x_offset, 17, base);
            } else if (has_views) {
                self.drawText(pixels, label, x_offset, 17, pink);
            } else {
                self.drawText(pixels, label, x_offset, 17, subtext);
            }
            
            x_offset += 32;
        }

        // Clock (Blue)
        const now = std.time.timestamp();
        var time_buf: [32]u8 = undefined;
        const day_seconds = @mod(now, 86400);
        const hours = @divTrunc(day_seconds, 3600);
        const minutes = @divTrunc(@mod(day_seconds, 3600), 60);
        const time_str = std.fmt.bufPrint(&time_buf, "{d:0>2}:{d:0>2} UTC", .{hours, minutes}) catch "00:00";
        self.drawText(pixels, time_str, self.width - 110, 17, blue);
        
        self.wlr_buffer.endDataPtrAccess();

        // Damage the buffer node to trigger a redraw
        self.scene_buffer.setBuffer(self.wlr_buffer);
    }

    fn drawText(self: *Bar, pixels: [*]u32, text_str: []const u8, x: i32, y: i32, color_raw: c.pixman_color_t) void {
        const r_s = @as(u32, color_raw.red >> 8);
        const g_s = @as(u32, color_raw.green >> 8);
        const b_s = @as(u32, color_raw.blue >> 8);

        var pen_x = x;
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

                    if (px >= 0 and px < self.width and py >= 0 and py < self.height) {
                         const offset = @as(usize, @intCast(py * self.width + px));
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

    pub fn deinit(self: *Bar) void {
        _ = c.FT_Done_Face(self.ft_face);
        _ = c.FT_Done_FreeType(self.ft_library);
        self.scene_tree.node.destroy();
        self.wlr_buffer.drop();
        std.heap.c_allocator.destroy(self);
    }
};
