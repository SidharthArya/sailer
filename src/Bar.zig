const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("Server.zig").Server;
const Output = @import("Output.zig").Output;

const c = @import("c.zig").c;

const Shm = @import("Shm.zig");
const bar_workspaces = @import("bar/Workspaces.zig");
const Workspaces = bar_workspaces.Workspaces;
const Theme = @import("bar/Theme.zig").Theme;
const bar_clock = @import("bar/Clock.zig");
const Clock = bar_clock.Clock;
const Renderer = @import("Renderer.zig").Renderer;
const Config = @import("Config.zig");

pub const Bar = struct {
    server: *Server,
    output: *Output,
    scene_tree: *wlr.SceneTree,
    scene_buffer: *wlr.SceneBuffer,
    wlr_buffer: *wlr.Buffer,
    width: i32,
    height: i32,

    renderer: Renderer,

    pub fn create(server: *Server, output: *Output, font_path: []const u8, config: Config.BarConfig) !*Bar {
        const bar = try std.heap.c_allocator.create(Bar);

        const renderer = try Renderer.init(font_path, config.font_size);

        var box: wlr.Box = undefined;
        server.output_layout.getBox(output.wlr_output, &box);

        const width = box.width;
        const height = config.height;

        // Use a manual SHM buffer to guarantee CPU access
        // TODO: The SHM buffer is recreated on every output resize — consider resizing in-place instead.
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
            .renderer = renderer,
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

        // Background (Crust)
        _ = c.pixman_image_fill_rectangles(c.PIXMAN_OP_SRC, pix, &Theme.crust, 1, &[_]c.pixman_rectangle16_t{.{
            .x = 0,
            .y = 0,
            .width = @intCast(self.width),
            .height = @intCast(self.height),
        }});

        var x_offset: i32 = 12;
        Workspaces.render(
            self,
            pix,
            pixels,
            &x_offset,
        );

        if (self.server.marked_mode) {
            x_offset += 8;
            self.drawText(pixels, "[M]", x_offset, 16, Theme.pink);
            x_offset += 32;
        }

        // Clock (Blue)
        Clock.render(self, pixels);

        self.wlr_buffer.endDataPtrAccess();

        // Damage the buffer node to trigger a redraw
        self.scene_buffer.setBuffer(self.wlr_buffer);
    }

    pub fn drawText(self: *Bar, pixels: [*]u32, text_str: []const u8, x: i32, y: i32, color_raw: c.pixman_color_t) void {
        self.renderer.drawText(pixels, self.width, text_str, x, y, color_raw, self.width, self.height);
    }
    pub fn workspaceAt(self: *Bar, lx: i32, ly: i32) ?usize {
        return Workspaces.workspaceAt(self.server, self.height, lx, ly);
    }

    pub fn hitTestWorkspace(self: *Bar, gx: f64, gy: f64) ?usize {
        return Workspaces.hitTest(
            self.server,
            self.output.wlr_output,
            self.server.output_layout,
            self.height,
            gx,
            gy,
        );
    }

    pub fn deinit(self: *Bar) void {
        self.renderer.deinit();
        self.scene_tree.node.destroy();
        self.wlr_buffer.drop();
        std.heap.c_allocator.destroy(self);
    }
};
