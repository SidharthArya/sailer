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

            const is_active_here = blk: {
                if (ws.visible_on) |out| {
                    break :blk std.mem.eql(u8, std.mem.span(out.wlr_output.name), std.mem.span(bar.output.wlr_output.name));
                }
                break :blk false;
            };
            const is_globally_focused = (server.focused_workspace == ws);
            const has_views = (ws.views.link.next != &ws.views.link);
            const is_urgent = ws.isUrgent();

            if (is_active_here) {
                const scale = bar.output.wlr_output.scale;
                // Main highlight for workspace on THIS monitor (Mauve)
                // Enlarge slightly for better visibility
                _ = c.pixman_image_fill_rectangles(c.PIXMAN_OP_OVER, pix, &Theme.mauve, 1, &[_]c.pixman_rectangle16_t{.{
                    .x = @intCast(x_offset.*),
                    .y = @intCast(@as(i32, @intFromFloat(1.0 * scale))),
                    .width = @intCast(@as(i32, @intFromFloat(28.0 * scale))),
                    .height = @intCast(bar.height - @as(i32, @intFromFloat(2.0 * scale))),
                }});
                
                // FORCE MAXIMUM CONTRAST: Use Base (Pitch Black) for focused, Blue for active-unfocused
                // If urgent, use Peach (Orange) for the text
                const text_color = if (is_urgent) Theme.peach else if (is_globally_focused) Theme.base else Theme.blue;
                bar.drawText(pixels, label, x_offset.* + @as(i32, @intFromFloat(2.0 * scale)), @as(i32, @intFromFloat(17.0 * scale)), text_color);
            } else if (is_urgent) {
                const scale = bar.output.wlr_output.scale;
                // Urgent workspace not active here (Peach)
                bar.drawText(pixels, label, x_offset.* + @as(i32, @intFromFloat(2.0 * scale)), @as(i32, @intFromFloat(17.0 * scale)), Theme.peach);
            } else if (is_globally_focused) {
                const scale = bar.output.wlr_output.scale;
                // Highlight text only for globally focused workspace on ANOTHER monitor
                bar.drawText(pixels, label, x_offset.* + @as(i32, @intFromFloat(2.0 * scale)), @as(i32, @intFromFloat(17.0 * scale)), Theme.mauve);
            } else if (has_views) {
                const scale = bar.output.wlr_output.scale;
                bar.drawText(pixels, label, x_offset.* + @as(i32, @intFromFloat(2.0 * scale)), @as(i32, @intFromFloat(17.0 * scale)), Theme.pink);
            } else {
                const scale = bar.output.wlr_output.scale;
                bar.drawText(pixels, label, x_offset.* + @as(i32, @intFromFloat(2.0 * scale)), @as(i32, @intFromFloat(17.0 * scale)), Theme.subtext);
            }

            x_offset.* += @as(i32, @intFromFloat(32.0 * bar.output.wlr_output.scale));
        }
    }



    pub fn workspaceAt(server: *Server, wlr_output: *wlr.Output, bar_height: i32, lx: i32, ly: i32) ?usize {
        // Local coordinates relative to the bar's top-left corner
        const scale = wlr_output.scale;
        
        // bar_height here is from the bar state, which is already scaled
        if (ly < 0 or ly >= bar_height) return null;

        var x_offset: i32 = @as(i32, @intFromFloat(12.0 * scale));
        for (server.workspaces, 0..) |_, idx| {
            const slot_x = x_offset;
            const slot_w = @as(i32, @intFromFloat(26.0 * scale)); // match your highlight width / visual slot

            if (lx >= slot_x and lx < slot_x + slot_w) {
                return idx;
            }

            x_offset += @as(i32, @intFromFloat(32.0 * scale));
        }

        return null;
    }

    pub fn hitTest(server: *Server, wlr_output: *wlr.Output, layout: *wlr.OutputLayout, bar_height: i32, gx: f64, gy: f64) ?usize {
        var box: wlr.Box = undefined;
        layout.getBox(wlr_output, &box);

        const lx: i32 = @as(i32, @intFromFloat(@as(f64, @floatFromInt(@as(i32, @intFromFloat(gx)) - box.x)) * wlr_output.scale));
        const ly: i32 = @as(i32, @intFromFloat(@as(f64, @floatFromInt(@as(i32, @intFromFloat(gy)) - box.y)) * wlr_output.scale));
        return workspaceAt(server, wlr_output, bar_height, lx, ly);
    }
};
