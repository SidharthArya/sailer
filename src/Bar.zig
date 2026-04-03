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
    
    pub fn create(server: *Server, output: *Output) !*Bar {
        const bar = try std.heap.c_allocator.create(Bar);
        
        var ft_library: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&ft_library) != 0) return error.FreeTypeInitFailed;
        errdefer _ = c.FT_Done_FreeType(ft_library);

        var ft_face: c.FT_Face = undefined;
        const font_path = "/usr/share/fonts/TTF/DejaVuSans.ttf";
        if (c.FT_New_Face(ft_library, font_path, 0, &ft_face) != 0) {
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

        // Background
        var bg_color = c.pixman_color_t{
            .red = 0x1A1A,
            .green = 0x1A1A,
            .blue = 0x2222,
            .alpha = 0xF000,
        };
        _ = c.pixman_image_fill_rectangles(c.PIXMAN_OP_SRC, pix, &bg_color, 1, &[_]c.pixman_rectangle16_t{.{
            .x = 0,
            .y = 0,
            .width = @intCast(self.width),
            .height = @intCast(self.height),
        }});

        var x_offset: i32 = 10;
        
        for (self.server.workspaces, 1..) |ws, i| {
            var label_buf: [4]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, " {d} ", .{i}) catch " ?";
            
            const is_focused = (self.server.focused_workspace == ws);
            const has_views = (ws.views.link.next != &ws.views.link);
            
            const text_color = if (is_focused) 
                c.pixman_color_t{ .red = 0xFFFF, .green = 0xFFFF, .blue = 0xFFFF, .alpha = 0xFFFF }
            else if (has_views)
                c.pixman_color_t{ .red = 0xAAAA, .green = 0xAAAA, .blue = 0xAAAA, .alpha = 0xFFFF }
            else
                c.pixman_color_t{ .red = 0x4444, .green = 0x4444, .blue = 0x4444, .alpha = 0xFFFF };

            if (is_focused) {
                 _ = c.pixman_image_fill_rectangles(c.PIXMAN_OP_OVER, pix, &c.pixman_color_t{ .red = 0x3D3D, .green = 0x4B4B, .blue = 0x7575, .alpha = 0xFFFF }, 1, &[_]c.pixman_rectangle16_t{.{
                    .x = @intCast(x_offset),
                    .y = 2,
                    .width = 24,
                    .height = @intCast(self.height - 4),
                }});
            }

            self.drawText(pixels, label, x_offset, 18, text_color);
            x_offset += 28;
        }

        const now = std.time.timestamp();
        var time_buf: [32]u8 = undefined;
        const day_seconds = @mod(now, 86400);
        const hours = @divTrunc(day_seconds, 3600);
        const minutes = @divTrunc(@mod(day_seconds, 3600), 60);
        const time_str = std.fmt.bufPrint(&time_buf, "{d:0>2}:{d:0>2} UTC", .{hours, minutes}) catch "00:00";
        self.drawText(pixels, time_str, self.width - 100, 18, .{ .red = 0xFFFF, .green = 0xFFFF, .blue = 0x7FFF, .alpha = 0xFFFF });
        
        self.wlr_buffer.endDataPtrAccess();

        // Damage the buffer node to trigger a redraw
        self.scene_buffer.setBuffer(self.wlr_buffer);
    }

    fn drawText(self: *Bar, pixels: [*]u32, text: []const u8, x: i32, y: i32, color: c.pixman_color_t) void {
        var pen_x = x;
        for (text) |char| {
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
                         const a = @as(u32, alpha);
                         const rb = ((color.red >> 8) * a) >> 8;
                         const gb = ((color.green >> 8) * a) >> 8;
                         const bb = ((color.blue >> 8) * a) >> 8;
                         pixels[offset] = (a << 24) | (rb << 16) | (gb << 8) | bb;
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
