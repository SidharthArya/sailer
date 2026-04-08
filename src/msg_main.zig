const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <command> [--key value ...]\n", .{args[0]});
        std.process.exit(1);
    }

    const cmd = args[1];
    var ipc_args = std.json.ObjectMap.init(allocator);
    defer ipc_args.deinit();

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.startsWith(u8, args[i], "--")) {
            const key = args[i][2..];
            if (i + 1 < args.len) {
                const val = args[i + 1];
                if (std.mem.eql(u8, val, "true")) {
                    try ipc_args.put(key, .{ .bool = true });
                } else if (std.mem.eql(u8, val, "false")) {
                    try ipc_args.put(key, .{ .bool = false });
                } else if (std.fmt.parseInt(i64, val, 10)) |num| {
                    try ipc_args.put(key, .{ .integer = num });
                } else |_| {
                    try ipc_args.put(key, .{ .string = val });
                }
                i += 1;
            } else {
                try ipc_args.put(key, .{ .bool = true });
            }
        }
    }

    const root_obj = try allocator.create(std.json.ObjectMap);
    defer allocator.destroy(root_obj);
    root_obj.* = std.json.ObjectMap.init(allocator);
    defer root_obj.deinit();

    try root_obj.put("cmd", .{ .string = cmd });
    try root_obj.put("args", .{ .object = ipc_args });

    var request_json_list = std.ArrayListUnmanaged(u8){};
    defer request_json_list.deinit(allocator);
    try request_json_list.writer(allocator).print("{f}", .{std.json.fmt(std.json.Value{ .object = root_obj.* }, .{})});
    const request_json = request_json_list.items;

    const socket_path = try resolveSocketPath(allocator);
    defer allocator.free(socket_path);

    const response = try sendToIpc(allocator, socket_path, request_json);
    defer allocator.free(response);

    std.debug.print("{s}\n", .{response});
}

fn resolveSocketPath(allocator: std.mem.Allocator) ![]u8 {
    const runtime_dir = std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR") catch try allocator.dupe(u8, "/tmp");
    defer allocator.free(runtime_dir);

    const display = std.process.getEnvVarOwned(allocator, "WAYLAND_DISPLAY") catch try allocator.dupe(u8, "wayland-0");
    defer allocator.free(display);

    return std.fmt.allocPrint(allocator, "{s}/sailer-{s}.sock", .{ runtime_dir, display });
}

fn sendToIpc(allocator: std.mem.Allocator, socket_path: []const u8, request: []const u8) ![]u8 {
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
    return allocator.dupe(u8, buf[0..end]);
}
