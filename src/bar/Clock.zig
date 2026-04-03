const std = @import("std");
const Bar = @import("../Bar.zig").Bar;
const Theme = @import("Theme.zig").Theme;

const c = @import("../c.zig").c;

pub const Clock = struct {
    pub fn render(bar: *Bar, pixels: [*]u32) void {
        const now = c.time(null);
        var tm_local: c.struct_tm = undefined;
        _ = c.localtime_r(&now, &tm_local);
        
        var time_buf: [32]u8 = undefined;
        const time_str = std.fmt.bufPrint(&time_buf, "{d:0>2}:{d:0>2}", .{ tm_local.tm_hour, tm_local.tm_min }) catch "00:00";
        
        // Draw at the right side of the bar
        bar.drawText(pixels, time_str, bar.width - 60, 17, Theme.blue);
    }
};

