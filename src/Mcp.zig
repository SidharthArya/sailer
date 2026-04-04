const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const Server = @import("Server.zig").Server;
const Toplevel = @import("View.zig").Toplevel;
const Screenshot = @import("Screenshot.zig").Screenshot;

pub const McpServer = struct {
    server: *Server,
    allocator: std.mem.Allocator,

    pub fn init(server: *Server, allocator: std.mem.Allocator) !*McpServer {
        const self = try allocator.create(McpServer);
        self.server = server;
        self.allocator = allocator;

        std.log.info("info(mcp): MCP Server logic initialized", .{});
        return self;
    }

    pub fn handleClient(self: *McpServer, stream: std.net.Stream) !void {
        // TODO: handleClient is never called — there is no socket listener. Wire this up or remove it.
        var reader_buf: [16384]u8 = undefined;
        var br = std.io.bufferedReader(stream.reader());
        var bw = std.io.bufferedWriter(stream.writer());
        const reader = br.reader();
        const writer = bw.writer();

        while (true) {
            const line = reader.readUntilDelimiterOrEof(&reader_buf, '\n') catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            } orelse break;

            try self.processMessage(line, writer);
            try bw.flush();
        }
    }

    fn processMessage(self: *McpServer, line: []const u8, writer: anytype) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{ .ignore_unknown_fields = true }) catch |err| {
            std.log.err("mcp: json parse error: {}", .{err});
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        const method = root.object.get("method") orelse return;
        const id = root.object.get("id");

        if (std.mem.eql(u8, method.string, "initialize")) {
            try self.sendResponse(writer, id, .{
                .protocolVersion = "2024-11-05",
                .capabilities = .{
                    .tools = .{},
                },
                .serverInfo = .{
                    .name = "sailer-mcp",
                    .version = "0.1.0",
                },
            });
        } else if (std.mem.eql(u8, method.string, "tools/list")) {
            try self.sendResponse(writer, id, .{
                .tools = .{
                    .{
                        .name = "list_windows",
                        .description = "List all open windows and their states",
                        .inputSchema = .{
                            .type = "object",
                            .properties = @as(struct {}, .{}),
                        },
                    },
                    .{
                        .name = "spawn",
                        .description = "Execute a shell command in the compositor environment",
                        .inputSchema = .{
                            .type = "object",
                            .properties = .{
                                .command = .{ .type = "string" },
                            },
                            .required = [_][]const u8{"command"},
                        },
                    },
                    .{
                        .name = "focus_window",
                        .description = "Focus a specific window by title or index",
                        .inputSchema = .{
                            .type = "object",
                            .properties = .{
                                .title = .{ .type = "string" },
                            },
                        },
                    },
                    .{
                        .name = "get_screenshot",
                        .description = "Capture screenshots of all connected outputs",
                        .inputSchema = .{
                            .type = "object",
                            .properties = @as(struct {}, .{}),
                        },
                    },
                },
            });
        } else if (std.mem.eql(u8, method.string, "tools/call")) {
            const params = root.object.get("params") orelse return;
            const tool_name = params.object.get("name") orelse return;
            const args = params.object.get("arguments") orelse std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };

            if (std.mem.eql(u8, tool_name.string, "list_windows")) {
                var list: std.ArrayList(std.json.Value) = .empty;
                defer list.deinit(self.allocator);

                var it = self.server.toplevels.link.next;
                var idx: u32 = 0;
                while (it != &self.server.toplevels.link) : (it = it.?.next) {
                    const view: *Toplevel = @fieldParentPtr("link", it.?);
                    const title = view.xdg_toplevel.title orelse "unnamed";
                    const app_id = view.xdg_toplevel.app_id orelse "unknown";
                    const focused = (self.server.seat.keyboard_state.focused_surface == view.xdg_toplevel.base.surface);

                    var window_obj = std.json.ObjectMap.init(self.allocator);
                    try window_obj.put("id", .{ .integer = @intCast(idx) });
                    try window_obj.put("title", .{ .string = std.mem.span(title) });
                    try window_obj.put("app_id", .{ .string = std.mem.span(app_id) });
                    try window_obj.put("focused", .{ .bool = focused });
                    
                    try list.append(self.allocator, .{ .object = window_obj });
                    idx += 1;
                }

                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(self.allocator);
                try buf.writer(self.allocator).print("{f}", .{std.json.fmt(list.items, .{})});

                try self.sendResponse(writer, id, .{
                    .content = [_]struct { type: []const u8, text: []const u8 }{
                        .{ .type = "text", .text = buf.items },
                    },
                });
            } else if (std.mem.eql(u8, tool_name.string, "spawn")) {
                const cmd = args.object.get("command").?.string;
                // TODO: The .? here will panic if "command" is missing — add proper error handling.
                self.server.spawn(cmd);
                try self.sendResponse(writer, id, .{
                    .content = [_]struct { type: []const u8, text: []const u8 }{
                        .{ .type = "text", .text = "Command executed" },
                    },
                });
            } else if (std.mem.eql(u8, tool_name.string, "focus_window")) {
                const title = args.object.get("title").?.string;
                var it = self.server.toplevels.link.next;
                while (it != &self.server.toplevels.link) : (it = it.?.next) {
                    const view: *Toplevel = @fieldParentPtr("link", it.?);
                    const window_title = view.xdg_toplevel.title orelse "";
                    if (std.mem.indexOf(u8, std.mem.span(window_title), title) != null) {
                        self.server.focusView(view, view.xdg_toplevel.base.surface);
                        break;
                    }
                }
                try self.sendResponse(writer, id, .{
                    .content = [_]struct { type: []const u8, text: []const u8 }{
                        .{ .type = "text", .text = "Focus updated" },
                    },
                });
            } else if (std.mem.eql(u8, tool_name.string, "get_screenshot")) {
                var contents: std.ArrayList(std.json.Value) = .empty;
                defer {
                    for (contents.items) |item| {
                        self.allocator.free(item.object.get("text").?.string);
                    }
                    contents.deinit(self.allocator);
                }

                var it = self.server.outputs.link.next;
                while (it != &self.server.outputs.link) : (it = it.?.next) {
                    const output: *@import("Output.zig").Output = @fieldParentPtr("link", it.?);
                    const scene_output = self.server.scene.getSceneOutput(output.wlr_output) orelse continue;
                    
                    const bmp_data = Screenshot.captureOutput(self.allocator, scene_output) catch |err| {
                        std.log.err("mcp: failed to capture screenshot for {s}: {}", .{ output.wlr_output.name, err });
                        continue;
                    };
                    defer self.allocator.free(bmp_data);

                    const encoded_len = std.base64.standard.Encoder.calcSize(bmp_data.len);
                    const encoded = try self.allocator.alloc(u8, encoded_len);
                    _ = std.base64.standard.Encoder.encode(encoded, bmp_data);

                    var content_obj = std.json.ObjectMap.init(self.allocator);
                    try content_obj.put("type", .{ .string = "image" });
                    try content_obj.put("data", .{ .string = encoded });
                    try content_obj.put("mimeType", .{ .string = "image/bmp" });
                    try contents.append(self.allocator, .{ .object = content_obj });
                }

                try self.sendResponse(writer, id, .{ .content = contents.items });
            }
        }
    }

    fn sendResponse(self: *McpServer, writer: anytype, id: ?std.json.Value, result: anytype) !void {
        _ = self;
        try writer.writeAll("{\"jsonrpc\":\"2.0\",");
        if (id) |i| {
            try writer.print("\"id\":{f},", .{std.json.fmt(i, .{})});
        }
        try writer.print("\"result\":{f}}}\n", .{std.json.fmt(result, .{})});
    }
};
