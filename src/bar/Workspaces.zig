const std = @import("std");
const wlr = @import("wlroots");
const Server = @import("../Server.zig").Server;
const Bar = @import("../Bar.zig").Bar;

const c = @import("../c.zig").c;

const Theme = @import("Theme.zig").Theme;

pub const Workspaces = struct {
    pub fn render(
        bar: *Bar,
        pix: *c.pixman_image_t,
        pixels: [*]u32,
        x_offset: *i32,
    ) void {
        const server = bar.server;
        for (server.workspaces, 1..) |ws, i| {
            var label_buf: [4]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, " {d} ", .{i}) catch " ?";

            const is_focused = (server.focused_workspace == ws);
            const has_views = (ws.views.link.next != &ws.views.link);

            if (is_focused) {
                // Focus highlight (Mauve)
                _ = c.pixman_image_fill_rectangles(c.PIXMAN_OP_OVER, pix, &Theme.mauve, 1, &[_]c.pixman_rectangle16_t{.{
                    .x = @intCast(x_offset.*),
                    .y = 3,
                    .width = 26,
                    .height = @intCast(bar.height - 6),
                }});
                bar.drawText(pixels, label, x_offset.*, 17, Theme.base);
            } else if (has_views) {
                bar.drawText(pixels, label, x_offset.*, 17, Theme.pink);
            } else {
                bar.drawText(pixels, label, x_offset.*, 17, Theme.subtext);
            }

            x_offset.* += 32;
        }
    }



    pub fn workspaceAt(server: *Server, bar_height: i32, lx: i32, ly: i32) ?usize {
        // Local coordinates relative to the bar's top-left corner
        if (ly < 0 or ly >= bar_height) return null;

        var x_offset: i32 = 12;
        for (server.workspaces, 0..) |_, idx| {
            const slot_x = x_offset;
            const slot_w = 26; // match your highlight width / visual slot

            if (lx >= slot_x and lx < slot_x + slot_w) {
                return idx;
            }

            x_offset += 32;
        }

        return null;
    }

    pub fn hitTest(server: *Server, wlr_output: *wlr.Output, layout: *wlr.OutputLayout, bar_height: i32, gx: f64, gy: f64) ?usize {
        var box: wlr.Box = undefined;
        layout.getBox(wlr_output, &box);

        const lx: i32 = @as(i32, @intFromFloat(gx)) - box.x;
        const ly: i32 = @as(i32, @intFromFloat(gy)) - box.y;
        return workspaceAt(server, bar_height, lx, ly);
    }
};
