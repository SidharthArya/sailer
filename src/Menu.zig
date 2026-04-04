const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("Server.zig").Server;
const View = @import("View.zig");
const Toplevel = View.Toplevel;
const c = @import("c.zig").c;
const Shm = @import("Shm.zig");
const Theme = @import("bar/Theme.zig").Theme;
const Renderer = @import("Renderer.zig").Renderer;
const Config = @import("Config.zig");

pub const MenuItem = struct {
    label: []const u8,
    action: Config.Action,
    y_offset: i32,
    height: i32,
};

pub const Menu = struct {
    server: *Server,
    toplevel: *Toplevel,
    scene_tree: *wlr.SceneTree,
    scene_buffer: *wlr.SceneBuffer,
    wlr_buffer: *wlr.Buffer,
    renderer: Renderer,
    width: i32,
    height: i32,
    items: std.ArrayListUnmanaged(MenuItem),
    hovered_index: ?usize = null,

    pub fn create(server: *Server, toplevel: *Toplevel, gx: i32, gy: i32) !*Menu {
        const allocator = std.heap.c_allocator;
        const self = try allocator.create(Menu);

        var items = std.ArrayListUnmanaged(MenuItem){};
        errdefer items.deinit(allocator);

        // Add default items
        try items.append(allocator, .{ .label = "Close", .action = .close, .y_offset = 0, .height = 24 });
        
        if (toplevel.is_maximized) {
            try items.append(allocator, .{ .label = "Unmaximize", .action = .toggle_maximize, .y_offset = 24, .height = 24 });
        } else {
            try items.append(allocator, .{ .label = "Maximize", .action = .toggle_maximize, .y_offset = 24, .height = 24 });
        }

        if (toplevel.is_fullscreen) {
            try items.append(allocator, .{ .label = "Unfullscreen", .action = .toggle_fullscreen, .y_offset = 48, .height = 24 });
        } else {
            try items.append(allocator, .{ .label = "Fullscreen", .action = .toggle_fullscreen, .y_offset = 48, .height = 24 });
        }

        try items.append(allocator, .{ .label = "Lock Window", .action = .toggle_locked, .y_offset = 72, .height = 24 });
        
        const width: i32 = 140;
        const height: i32 = @intCast(items.items.len * 24);

        const shm_buf = try Shm.ShmBuffer.create(width, height, 0x34325258);
        const wlr_buffer = shm_buf.getWlrBuffer();

        const scene_tree = server.scene.tree.createSceneTree() catch return error.SceneTreeCreateFailed;
        const scene_buffer = try scene_tree.createSceneBuffer(wlr_buffer);

        scene_tree.node.setPosition(gx, gy);
        scene_tree.node.raiseToTop();

        const renderer = try Renderer.init(server.config.font, 14);

        self.* = .{
            .server = server,
            .toplevel = toplevel,
            .scene_tree = scene_tree,
            .scene_buffer = scene_buffer,
            .wlr_buffer = wlr_buffer,
            .renderer = renderer,
            .width = width,
            .height = height,
            .items = items,
        };

        self.update();
        return self;
    }

    pub fn update(self: *Menu) void {
        var data_ptr: *anyopaque = undefined;
        var out_format: u32 = 0;
        var stride: usize = 0;
        if (!self.wlr_buffer.beginDataPtrAccess(3, &data_ptr, &out_format, &stride)) return;

        const pixels = @as([*]u32, @ptrCast(@alignCast(data_ptr)));

        const pix = c.pixman_image_create_bits(
            c.PIXMAN_a8r8g8b8,
            self.width,
            self.height,
            @ptrCast(pixels),
            @intCast(self.width * 4),
        ) orelse {
            self.wlr_buffer.endDataPtrAccess();
            return;
        };
        defer _ = c.pixman_image_unref(pix);

        // Background (Base)
        _ = c.pixman_image_fill_rectangles(c.PIXMAN_OP_SRC, pix, &Theme.base, 1, &[_]c.pixman_rectangle16_t{.{
            .x = 0,
            .y = 0,
            .width = @intCast(self.width),
            .height = @intCast(self.height),
        }});

        for (self.items.items, 0..) |item, i| {
            if (self.hovered_index == i) {
                // Highlight (Blue)
                _ = c.pixman_image_fill_rectangles(c.PIXMAN_OP_SRC, pix, &Theme.blue, 1, &[_]c.pixman_rectangle16_t{.{
                    .x = 0,
                    .y = @intCast(item.y_offset),
                    .width = @intCast(self.width),
                    .height = @intCast(item.height),
                }});
                self.renderer.drawText(pixels, self.width, item.label, 12, item.y_offset + 17, Theme.crust, self.width, self.height);
            } else {
                self.renderer.drawText(pixels, self.width, item.label, 12, item.y_offset + 17, Theme.subtext, self.width, self.height);
            }
        }

        self.wlr_buffer.endDataPtrAccess();
        self.scene_buffer.setBuffer(self.wlr_buffer);
    }

    pub fn hitTest(self: *Menu, gx: f64, gy: f64) bool {
        const x = @as(f64, @floatFromInt(self.scene_tree.node.x));
        const y = @as(f64, @floatFromInt(self.scene_tree.node.y));
        return gx >= x and gx < x + @as(f64, @floatFromInt(self.width)) and
               gy >= y and gy < y + @as(f64, @floatFromInt(self.height));
    }

    pub fn handleMotion(self: *Menu, _gx: f64, gy: f64) void {
        _ = _gx;
        const ly = gy - @as(f64, @floatFromInt(self.scene_tree.node.y));
        const index = @as(usize, @intFromFloat(@floor(ly / 24.0)));
        if (index < self.items.items.len) {
            if (self.hovered_index != index) {
                self.hovered_index = index;
                self.update();
            }
        } else if (self.hovered_index != null) {
            self.hovered_index = null;
            self.update();
        }
    }

    pub fn handleButton(self: *Menu, _gx: f64, gy: f64) ?Config.Action {
        _ = _gx;
        const ly = gy - @as(f64, @floatFromInt(self.scene_tree.node.y));
        const index = @as(usize, @intFromFloat(@floor(ly / 24.0)));
        if (index < self.items.items.len) {
            return self.items.items[index].action;
        }
        return null;
    }

    pub fn deinit(self: *Menu) void {
        const allocator = std.heap.c_allocator;
        self.renderer.deinit();
        self.items.deinit(allocator);
        self.scene_tree.node.destroy();
        self.wlr_buffer.drop();
        allocator.destroy(self);
    }
};
