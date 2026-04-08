const c = @import("../c.zig").c;

pub const Theme = struct {
    pub const pink = c.pixman_color_t{ .red = 0xf5f5, .green = 0xc2c2, .blue = 0xe7e7, .alpha = 0xffff };
    pub const mauve = c.pixman_color_t{ .red = 0xcbcb, .green = 0xa6a6, .blue = 0xf7f7, .alpha = 0xffff };
    pub const blue = c.pixman_color_t{ .red = 0x8989, .green = 0xb4b4, .blue = 0xfafa, .alpha = 0xffff };
    pub const subtext = c.pixman_color_t{ .red = 0xa6a6, .green = 0xadad, .blue = 0xc8c8, .alpha = 0xffff };
    pub const crust = c.pixman_color_t{ .red = 0x1111, .green = 0x1111, .blue = 0x1b1b, .alpha = 0xffff };
    pub const base = c.pixman_color_t{ .red = 0x1e1e, .green = 0x1e1e, .blue = 0x2e2e, .alpha = 0xffff };
    pub const peach = c.pixman_color_t{ .red = 0xffff, .green = 0x5999, .blue = 0x1999, .alpha = 0xffff };
};
