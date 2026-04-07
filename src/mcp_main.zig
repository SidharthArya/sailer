/// sailer-mcp: MCP stdio bridge for the sailer compositor.
/// Reads MCP JSON-RPC from stdin, forwards commands to sailer's IPC socket,
/// and returns results as MCP responses to stdout.
///
/// Uses newline-delimited JSON (NDJSON) as per the MCP stdio transport spec:
/// each message is a single JSON line terminated by \n.
const std = @import("std");

const gpa = std.heap.c_allocator;

pub fn main() !void {
    // Redirect stderr to log file for debugging
    const log_file = std.fs.openFileAbsolute("/tmp/sailer-mcp.log", .{ .mode = .write_only }) catch blk: {
        break :blk std.fs.createFileAbsolute("/tmp/sailer-mcp.log", .{}) catch null;
    };
    if (log_file) |f| {
        // Seek to end so we append
        f.seekFromEnd(0) catch {};
        std.posix.dup2(f.handle, std.posix.STDERR_FILENO) catch {};
        f.close();
    }

    std.log.info("mcp: server starting", .{});

    const socket_path = resolveSocketPath() catch |err| {
        std.log.err("mcp: failed to resolve IPC socket path: {}", .{err});
        return;
    };
    defer gpa.free(socket_path);
    std.log.info("mcp: socket path: {s}", .{socket_path});

    const stdin_fd = std.fs.File.stdin().handle;
    const stdout_fd = std.fs.File.stdout().handle;

    var line_buf: [65536]u8 = undefined;
    var line_pos: usize = 0;

    while (true) {
        // Read bytes until we find a newline (NDJSON: one JSON object per line)
        while (std.mem.indexOfScalar(u8, line_buf[0..line_pos], '\n') == null) {
            if (line_pos >= line_buf.len) {
                std.log.err("mcp: line buffer overflow", .{});
                line_pos = 0;
                continue;
            }
            const n = std.posix.read(stdin_fd, line_buf[line_pos..]) catch |err| {
                std.log.err("mcp: read error: {}", .{err});
                return;
            };
            if (n == 0) {
                std.log.info("mcp: stdin closed (EOF), exiting", .{});
                return;
            }
            line_pos += n;
        }

        // Extract the line up to (but not including) the newline
        const newline_idx = std.mem.indexOfScalar(u8, line_buf[0..line_pos], '\n').?;
        const line = line_buf[0..newline_idx];

        // Trim trailing \r if present
        const trimmed = std.mem.trimRight(u8, line, "\r");

        // Shift remaining data to front of buffer
        const consumed = newline_idx + 1;
        const remaining = line_pos - consumed;
        if (remaining > 0) {
            std.mem.copyForwards(u8, line_buf[0..remaining], line_buf[consumed..line_pos]);
        }
        line_pos = remaining;

        if (trimmed.len == 0) continue; // skip empty lines

        std.log.info("mcp: received: {s}", .{trimmed});

        processMessage(socket_path, trimmed, stdout_fd) catch |err| {
            std.log.err("mcp: error processing message: {}", .{err});
        };
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

fn processMessage(socket_path: []const u8, body: []const u8, stdout_fd: std.posix.fd_t) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{ .ignore_unknown_fields = true }) catch {
        try sendError(stdout_fd, null, "invalid json");
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    const method_val = root.object.get("method") orelse return;
    const method = method_val.string;
    const id = root.object.get("id");

    std.log.info("mcp: method={s} id={any}", .{ method, id != null });

    if (std.mem.eql(u8, method, "initialize")) {
        try sendResponse(stdout_fd, id, .{
            .protocolVersion = "2024-11-05",
            .capabilities = .{ .tools = .{ .listChanged = false } },
            .serverInfo = .{ .name = "sailer-mcp", .version = "0.1.0" },
        });
        std.log.info("mcp: initialized successfully", .{});
        return;
    }

    // Handle notifications (no id, no response needed)
    if (std.mem.eql(u8, method, "notifications/initialized")) {
        std.log.info("mcp: client confirmed initialization", .{});
        return;
    }

    if (std.mem.eql(u8, method, "notifications/cancelled")) {
        std.log.info("mcp: client cancelled request", .{});
        return;
    }

    // Handle ping
    if (std.mem.eql(u8, method, "ping")) {
        try sendRawResponse(stdout_fd, id, "{}");
        std.log.info("mcp: pong", .{});
        return;
    }

    if (std.mem.eql(u8, method, "tools/list")) {
        const tools_json =
            "{\"tools\":[" ++
            "{\"name\":\"spawn\",\"description\":\"Execute a shell command\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}}," ++
            "{\"name\":\"list_windows\",\"description\":\"List all open windows\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}," ++
            "{\"name\":\"focus_window\",\"description\":\"Focus a window by title\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\"}},\"required\":[\"title\"]}}," ++
            "{\"name\":\"get_workspaces\",\"description\":\"List all workspaces\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}," ++
            "{\"name\":\"switch_workspace\",\"description\":\"Switch to a workspace by index\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"index\":{\"type\":\"integer\"}},\"required\":[\"index\"]}}," ++
            "{\"name\":\"type_text\",\"description\":\"Type text into the currently focused window\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}}" ++
            "]}";
        try sendRawResponse(stdout_fd, id, tools_json);
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
                try sendError(stdout_fd, id, "missing command");
                return;
            }).string;
            try ipc_req.writer(gpa).print("{{\"cmd\":\"spawn\",\"args\":{{\"command\":\"{s}\"}}}}", .{cmd});
        } else if (std.mem.eql(u8, tool_name, "list_windows")) {
            try ipc_req.appendSlice(gpa, "{\"cmd\":\"list_windows\"}");
        } else if (std.mem.eql(u8, tool_name, "focus_window")) {
            const title = (args.object.get("title") orelse {
                try sendError(stdout_fd, id, "missing title");
                return;
            }).string;
            try ipc_req.writer(gpa).print("{{\"cmd\":\"focus_window\",\"args\":{{\"title\":\"{s}\"}}}}", .{title});
        } else if (std.mem.eql(u8, tool_name, "get_workspaces")) {
            try ipc_req.appendSlice(gpa, "{\"cmd\":\"get_workspaces\"}");
        } else if (std.mem.eql(u8, tool_name, "switch_workspace")) {
            const index = (args.object.get("index") orelse {
                try sendError(stdout_fd, id, "missing index");
                return;
            }).integer;
            try ipc_req.writer(gpa).print("{{\"cmd\":\"switch_workspace\",\"args\":{{\"index\":{d}}}}}", .{index});
        } else if (std.mem.eql(u8, tool_name, "type_text")) {
            const text = (args.object.get("text") orelse {
                try sendError(stdout_fd, id, "missing text");
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
            try sendError(stdout_fd, id, "unknown tool");
            return;
        }

        const response = sendToIpc(socket_path, ipc_req.items) catch |err| {
            try sendError(stdout_fd, id, @errorName(err));
            return;
        };
        defer gpa.free(response);

        try sendResponse(stdout_fd, id, .{
            .content = &[_]struct { type: []const u8, text: []const u8 }{
                .{ .type = "text", .text = response },
            },
        });
    }
}

/// Send a JSON-RPC response as a single newline-terminated JSON line (NDJSON).
fn sendResponse(stdout_fd: std.posix.fd_t, id: ?std.json.Value, result: anytype) !void {
    var body = std.ArrayListUnmanaged(u8){};
    defer body.deinit(gpa);
    const body_writer = body.writer(gpa);

    try body_writer.writeAll("{\"jsonrpc\":\"2.0\",");
    if (id) |i| {
        try body_writer.print("\"id\":{f},", .{std.json.fmt(i, .{})});
    }
    try body_writer.print("\"result\":{f}", .{std.json.fmt(result, .{})});
    try body_writer.writeAll("}\n");

    std.log.info("mcp: sending response ({d} bytes)", .{body.items.len});
    _ = try std.posix.write(stdout_fd, body.items);
}

/// Send a JSON-RPC response with a raw JSON string as the result value.
fn sendRawResponse(stdout_fd: std.posix.fd_t, id: ?std.json.Value, raw_result: []const u8) !void {
    var body = std.ArrayListUnmanaged(u8){};
    defer body.deinit(gpa);
    const body_writer = body.writer(gpa);

    try body_writer.writeAll("{\"jsonrpc\":\"2.0\",");
    if (id) |i| {
        try body_writer.print("\"id\":{f},", .{std.json.fmt(i, .{})});
    }
    try body_writer.print("\"result\":{s}", .{raw_result});
    try body_writer.writeAll("}\n");

    std.log.info("mcp: sending raw response ({d} bytes)", .{body.items.len});
    _ = try std.posix.write(stdout_fd, body.items);
}

/// Send a JSON-RPC error as a single newline-terminated JSON line (NDJSON).
fn sendError(stdout_fd: std.posix.fd_t, id: ?std.json.Value, message: []const u8) !void {
    var body = std.ArrayListUnmanaged(u8){};
    defer body.deinit(gpa);
    const body_writer = body.writer(gpa);

    try body_writer.writeAll("{\"jsonrpc\":\"2.0\",");
    if (id) |i| {
        try body_writer.print("\"id\":{f},", .{std.json.fmt(i, .{})});
    }
    try body_writer.print("\"error\":{{\"code\":-32603,\"message\":\"{s}\"}}}}", .{message});
    try body_writer.writeByte('\n');

    _ = try std.posix.write(stdout_fd, body.items);
}
