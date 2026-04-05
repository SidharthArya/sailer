/// sailer-mcp: MCP stdio bridge for the sailer compositor.
/// Reads MCP JSON-RPC from stdin, forwards commands to sailer's IPC socket,
/// and returns results as MCP responses to stdout.
const std = @import("std");

const gpa = std.heap.c_allocator;

pub fn main() !void {
    const socket_path = resolveSocketPath() catch |err| {
        std.log.err("failed to resolve IPC socket path: {}", .{err});
        return;
    };
    defer gpa.free(socket_path);

    var stdin_buf: [65536]u8 = undefined;
    var stdin_pos: usize = 0;
    const stdin_fd = std.fs.File.stdin().handle;
    const stdout_fd = std.fs.File.stdout().handle;

    while (true) {
        const n = std.posix.read(stdin_fd, stdin_buf[stdin_pos..]) catch break;
        if (n == 0) break;
        stdin_pos += n;

        while (std.mem.indexOfScalar(u8, stdin_buf[0..stdin_pos], '\n')) |nl| {
            const line = stdin_buf[0..nl];
            var out = std.ArrayListUnmanaged(u8){};
            defer out.deinit(gpa);

            processMessage(socket_path, line, &out) catch |err| {
                std.log.err("mcp: error processing message: {}", .{err});
                out.clearRetainingCapacity();
                out.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"internal error\"}}\n") catch {};
            };
            if (out.items.len > 0) _ = std.posix.write(stdout_fd, out.items) catch {};

            const remaining = stdin_pos - nl - 1;
            std.mem.copyForwards(u8, stdin_buf[0..remaining], stdin_buf[nl + 1 .. stdin_pos]);
            stdin_pos = remaining;
        }
        if (stdin_pos >= stdin_buf.len) break;
    }
}

fn resolveSocketPath() ![]u8 {
    const runtime_dir = std.process.getEnvVarOwned(gpa, "XDG_RUNTIME_DIR") catch try gpa.dupe(u8, "/tmp");
    defer gpa.free(runtime_dir);

    const display = std.process.getEnvVarOwned(gpa, "WAYLAND_DISPLAY") catch try gpa.dupe(u8, "wayland-0");
    defer gpa.free(display);

    return std.fmt.allocPrint(gpa, "{s}/sailer-{s}.sock", .{ runtime_dir, display });
}

fn sendToIpc(socket_path: []const u8, request: []const u8) ![]u8 {
    const stream = try std.net.connectUnixSocket(socket_path);
    defer stream.close();

    try stream.writeAll(request);
    try stream.writeAll("\n");

    // Read response line
    var buf: [65536]u8 = undefined;
    var pos: usize = 0;
    while (pos < buf.len) {
        const n = try stream.read(buf[pos..]);
        if (n == 0) break;
        pos += n;
        if (std.mem.indexOfScalar(u8, buf[0..pos], '\n') != null) break;
    }
    const end = std.mem.indexOfScalar(u8, buf[0..pos], '\n') orelse pos;
    return gpa.dupe(u8, buf[0..end]);
}

fn processMessage(socket_path: []const u8, line: []const u8, out: *std.ArrayListUnmanaged(u8)) !void {
    const writer = out.writer(gpa);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{ .ignore_unknown_fields = true }) catch {
        try sendError(writer, null, "invalid json");
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    const method_val = root.object.get("method") orelse return;
    const method = method_val.string;
    const id = root.object.get("id");

    if (std.mem.eql(u8, method, "initialize")) {
        try sendResponse(writer, id, .{
            .protocolVersion = "2024-11-05",
            .capabilities = .{ .tools = .{} },
            .serverInfo = .{ .name = "sailer-mcp", .version = "0.1.0" },
        });
        return;
    }

    if (std.mem.eql(u8, method, "tools/list")) {
        const tools_json =
            \\[
            \\  {"name":"spawn","description":"Execute a shell command","inputSchema":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}},
            \\  {"name":"list_windows","description":"List all open windows","inputSchema":{"type":"object","properties":{}}},
            \\  {"name":"focus_window","description":"Focus a window by title","inputSchema":{"type":"object","properties":{"title":{"type":"string"}},"required":["title"]}},
            \\  {"name":"get_workspaces","description":"List all workspaces","inputSchema":{"type":"object","properties":{}}},
            \\  {"name":"switch_workspace","description":"Switch to a workspace by index","inputSchema":{"type":"object","properties":{"index":{"type":"integer"}},"required":["index"]}},
            \\  {"name":"type_text","description":"Type text into the currently focused window","inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}
            \\]
        ;
        try writer.writeAll("{\"jsonrpc\":\"2.0\",");
        if (id) |i| try writer.print("\"id\":{f},", .{std.json.fmt(i, .{})});
        try writer.print("\"result\":{{\"tools\":{s}}}}}\n", .{tools_json});
        return;
    }

    if (std.mem.eql(u8, method, "tools/call")) {
        const params = root.object.get("params") orelse return;
        const tool_name = (params.object.get("name") orelse return).string;
        const args = params.object.get("arguments") orelse std.json.Value{ .object = std.json.ObjectMap.init(gpa) };

        // Build IPC request
        var ipc_req = std.ArrayListUnmanaged(u8){};
        defer ipc_req.deinit(gpa);

        if (std.mem.eql(u8, tool_name, "spawn")) {
            const cmd = (args.object.get("command") orelse {
                try sendError(writer, id, "missing command");
                return;
            }).string;
            try ipc_req.writer(gpa).print("{{\"cmd\":\"spawn\",\"args\":{{\"command\":\"{s}\"}}}}", .{cmd});
        } else if (std.mem.eql(u8, tool_name, "list_windows")) {
            try ipc_req.appendSlice(gpa, "{\"cmd\":\"list_windows\"}");
        } else if (std.mem.eql(u8, tool_name, "focus_window")) {
            const title = (args.object.get("title") orelse {
                try sendError(writer, id, "missing title");
                return;
            }).string;
            try ipc_req.writer(gpa).print("{{\"cmd\":\"focus_window\",\"args\":{{\"title\":\"{s}\"}}}}", .{title});
        } else if (std.mem.eql(u8, tool_name, "get_workspaces")) {
            try ipc_req.appendSlice(gpa, "{\"cmd\":\"get_workspaces\"}");
        } else if (std.mem.eql(u8, tool_name, "switch_workspace")) {
            const index = (args.object.get("index") orelse {
                try sendError(writer, id, "missing index");
                return;
            }).integer;
            try ipc_req.writer(gpa).print("{{\"cmd\":\"switch_workspace\",\"args\":{{\"index\":{d}}}}}", .{index});
        } else if (std.mem.eql(u8, tool_name, "type_text")) {
            const text = (args.object.get("text") orelse {
                try sendError(writer, id, "missing text");
                return;
            }).string;
            // Escape backslashes and quotes for JSON embedding
            var escaped = std.ArrayListUnmanaged(u8){};
            defer escaped.deinit(gpa);
            for (text) |ch| {
                if (ch == '"' or ch == '\\') try escaped.append(gpa, '\\');
                try escaped.append(gpa, ch);
            }
            try ipc_req.writer(gpa).print("{{\"cmd\":\"type_text\",\"args\":{{\"text\":\"{s}\"}}}}", .{escaped.items});
        } else {
            try sendError(writer, id, "unknown tool");
            return;
        }

        const response = sendToIpc(socket_path, ipc_req.items) catch |err| {
            try sendError(writer, id, @errorName(err));
            return;
        };
        defer gpa.free(response);

        try sendResponse(writer, id, .{
            .content = &[_]struct { type: []const u8, text: []const u8 }{
                .{ .type = "text", .text = response },
            },
        });
    }
}

fn sendResponse(writer: anytype, id: ?std.json.Value, result: anytype) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",");
    if (id) |i| try writer.print("\"id\":{f},", .{std.json.fmt(i, .{})});
    try writer.print("\"result\":{f}}}\n", .{std.json.fmt(result, .{})});
}

fn sendError(writer: anytype, id: ?std.json.Value, message: []const u8) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",");
    if (id) |i| try writer.print("\"id\":{f},", .{std.json.fmt(i, .{})});
    try writer.print("\"error\":{{\"code\":-32603,\"message\":\"{s}\"}}}}\n", .{message});
}
