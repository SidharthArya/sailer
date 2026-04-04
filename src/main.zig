const std = @import("std");
const Server = @import("Server.zig").Server;
const wlr = @import("wlroots");
const builtin = @import("builtin");

// TODO: Replace std.heap.c_allocator with a proper allocator (e.g. std.heap.GeneralPurposeAllocator)
//       to enable leak detection and better memory safety.
const gpa = std.heap.c_allocator;

pub fn main() anyerror!void {
    if (builtin.mode == .Debug) {
        wlr.log.init(.debug, null);
    } else {
        wlr.log.init(.info, null);
    }

    var server: Server = undefined;
    // TODO: Move version string to a comptime constant or build option instead of hardcoding here.
    std.log.info("Sailer Version 0.1.0-v8.2 (Stability & Performance Fix)", .{});
    try server.init();
    defer server.deinit();

    if (std.process.getEnvVarOwned(gpa, "XDG_RUNTIME_DIR")) |dir| {
        std.log.info("XDG_RUNTIME_DIR is set to: {s}", .{dir});
        gpa.free(dir);
    } else |_| {
        std.log.warn("XDG_RUNTIME_DIR is NOT set! Wayland clients will fail to connect.", .{});
    }

    // Prevent zombie processes from children
    var sa = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.NOCLDWAIT,
    };
    std.posix.sigaction(std.posix.SIG.CHLD, &sa, null);
    
    try server.backend.start();
    std.log.info("Backend started, Wayland socket: {s}", .{server.socket_name});

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len >= 2) {
        const cmd = args[1];
        // TODO: Support multiple startup commands (e.g. a list in config) rather than a single CLI arg.
        var child = std.process.Child.init(
            &[_][]const u8{ "/bin/sh", "-c", cmd },
            gpa,
        );

        var env_map = try std.process.getEnvMap(gpa);
        defer env_map.deinit();

        try env_map.put("WAYLAND_DISPLAY", server.socket_name);
        child.env_map = &env_map;

        try child.spawn();
        std.log.info("Spawned startup command: {s}", .{cmd});
    }

    std.log.info("Running compositor on WAYLAND_DISPLAY={s}", .{server.socket_name});
    server.wl_server.run();
}
