const std = @import("std");
const wl = @import("wayland").server.wl;
const Server = @import("Server.zig").Server;
const Action = @import("Config.zig").Action;
const DisplayMode = @import("Config.zig").DisplayMode;

/// A pending command from the IPC thread, to be executed on the main Wayland thread.
const PendingCmd = struct {
    cmd: []const u8,       // owned
    response_fd: std.posix.fd_t,
};

/// IPC server — listens on a Unix socket and handles JSON commands.
/// Read-only queries are answered directly from the IPC thread.
/// State-mutating commands are queued and executed on the main Wayland thread.
pub const IpcServer = struct {
    server: *Server,
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    listener_fd: std.posix.fd_t = -1,

    // Pipe used to wake the Wayland event loop when a mutating command arrives.
    wake_read_fd: std.posix.fd_t = -1,
    wake_write_fd: std.posix.fd_t = -1,
    wake_source: ?*wl.EventSource = null,

    // Queue of pending mutating commands (protected by mutex).
    queue_mutex: std.Thread.Mutex = .{},
    queue: std.ArrayListUnmanaged(PendingCmd) = .{},

    // Simple actions that take no arguments — mapped from command name to Action enum.
    const simple_actions = [_]struct { name: []const u8, action: Action }{
        .{ .name = "focus_left", .action = .focus_left },
        .{ .name = "focus_right", .action = .focus_right },
        .{ .name = "focus_output", .action = .focus_output },
        .{ .name = "close", .action = .close },
        .{ .name = "resize_shrink", .action = .resize_shrink },
        .{ .name = "resize_expand", .action = .resize_expand },
        .{ .name = "move_left", .action = .move_left },
        .{ .name = "move_right", .action = .move_right },
        .{ .name = "move_up", .action = .move_up },
        .{ .name = "move_down", .action = .move_down },
        .{ .name = "reorder_left", .action = .reorder_left },
        .{ .name = "reorder_right", .action = .reorder_right },
        .{ .name = "toggle_layout", .action = .toggle_layout },
        .{ .name = "toggle_floating_layout", .action = .toggle_floating_layout },
        .{ .name = "toggle_tiling_layout", .action = .toggle_tiling_layout },
        .{ .name = "toggle_ribbon_layout", .action = .toggle_ribbon_layout },
        .{ .name = "smart_view", .action = .smart_view },
        .{ .name = "toggle_maximize", .action = .toggle_maximize },
        .{ .name = "toggle_fullscreen", .action = .toggle_fullscreen },
        .{ .name = "toggle_floating", .action = .toggle_floating },
        .{ .name = "toggle_hidden", .action = .toggle_hidden },
        .{ .name = "toggle_locked", .action = .toggle_locked },
        .{ .name = "toggle_sticky", .action = .toggle_sticky },
        .{ .name = "toggle_private", .action = .toggle_private },
        .{ .name = "toggle_marked", .action = .toggle_marked },
        .{ .name = "toggle_urgent", .action = .toggle_urgent },
        .{ .name = "cycle_display_mode", .action = .cycle_display_mode },
        .{ .name = "terminate", .action = .terminate },
        .{ .name = "reload_config", .action = .reload_config },
        .{ .name = "get_screenshot", .action = .get_screenshot },
    };

    fn isSimpleAction(cmd: []const u8) bool {
        for (simple_actions) |entry| {
            if (std.mem.eql(u8, cmd, entry.name)) return true;
        }
        return false;
    }

    fn getSimpleAction(cmd: []const u8) ?Action {
        for (simple_actions) |entry| {
            if (std.mem.eql(u8, cmd, entry.name)) return entry.action;
        }
        return null;
    }

    // All known mutating command names (simple actions + commands with args)
    fn isKnownMutatingCommand(cmd: []const u8) bool {
        if (isSimpleAction(cmd)) return true;
        const arg_commands = [_][]const u8{
            "spawn", "focus_window", "switch_workspace", "move_to_workspace", "type_text", "set_display_mode",
        };
        for (arg_commands) |c| {
            if (std.mem.eql(u8, cmd, c)) return true;
        }
        return false;
    }

    pub fn init(server: *Server, allocator: std.mem.Allocator) !*IpcServer {
        const self = try allocator.create(IpcServer);

        const runtime_dir = std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR") catch try allocator.dupe(u8, "/tmp");
        defer allocator.free(runtime_dir);

        const display = server.socket_name;
        const socket_path = try std.fmt.allocPrint(allocator, "{s}/sailer-{s}.sock", .{ runtime_dir, display });

        self.* = .{
            .server = server,
            .allocator = allocator,
            .socket_path = socket_path,
        };

        return self;
    }

    pub fn start(self: *IpcServer) !void {
        std.fs.deleteFileAbsolute(self.socket_path) catch {};

        const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
        errdefer std.posix.close(fd);

        var addr = std.posix.sockaddr.un{ .family = std.posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        if (self.socket_path.len >= addr.path.len) return error.PathTooLong;
        @memcpy(addr.path[0..self.socket_path.len], self.socket_path);

        try std.posix.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));
        try std.posix.listen(fd, 8);
        self.listener_fd = fd;

        // Create wake pipe
        const pipe = try std.posix.pipe();
        self.wake_read_fd = pipe[0];
        self.wake_write_fd = pipe[1];

        // Register wake pipe with Wayland event loop via C directly
        // (zig-wayland's addFd has a type mismatch in the generated binding)
        const c_ipc = @import("c.zig").c;
        const wake_source_raw = c_ipc.wl_event_loop_add_fd(
            @ptrCast(self.server.wl_server.getEventLoop()),
            self.wake_read_fd,
            1, // WL_EVENT_READABLE
            struct {
                fn cb(_fd: c_int, _mask: u32, data: ?*anyopaque) callconv(.c) c_int {
                    _ = _fd; _ = _mask;
                    const ipc: *IpcServer = @ptrCast(@alignCast(data.?));
                    return IpcServer.drainQueueC(ipc);
                }
            }.cb,
            self,
        ) orelse return error.AddFdFailed;
        self.wake_source = @ptrCast(wake_source_raw);

        self.running.store(true, .release);
        const t = try std.Thread.spawn(.{}, acceptLoop, .{self});
        t.detach();
        std.log.info("IPC socket listening at {s}", .{self.socket_path});
    }

    pub fn deinit(self: *IpcServer) void {
        self.running.store(false, .release);
        // Close the listener first — this unblocks the accept() call in acceptLoop.
        if (self.listener_fd >= 0) {
            std.posix.close(self.listener_fd);
            self.listener_fd = -1;
        }
        // Close the wake pipe write end.
        if (self.wake_write_fd >= 0) {
            std.posix.close(self.wake_write_fd);
            self.wake_write_fd = -1;
        }
        if (self.wake_source) |s| s.remove();
        if (self.wake_read_fd >= 0) {
            std.posix.close(self.wake_read_fd);
            self.wake_read_fd = -1;
        }

        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        for (self.queue.items) |item| {
            self.allocator.free(item.cmd);
            std.posix.close(item.response_fd);
        }
        self.queue.deinit(self.allocator);

        std.fs.deleteFileAbsolute(self.socket_path) catch {};
        self.allocator.free(self.socket_path);
        self.allocator.destroy(self);
    }

    fn acceptLoop(self: *IpcServer) void {
        while (self.running.load(.acquire)) {
            const client_fd = std.posix.accept(self.listener_fd, null, null, 0) catch |err| {
                if (self.running.load(.acquire)) std.log.err("IPC accept error: {}", .{err});
                break;
            };
            const t = std.Thread.spawn(.{}, handleClient, .{ self, client_fd }) catch |err| {
                std.log.err("IPC failed to spawn client thread: {}", .{err});
                std.posix.close(client_fd);
                continue;
            };
            t.detach();
        }
    }

    fn handleClient(self: *IpcServer, fd: std.posix.fd_t) void {
        var buf: [65536]u8 = undefined;
        var pos: usize = 0;

        while (true) {
            const n = std.posix.read(fd, buf[pos..]) catch break;
            if (n == 0) break;
            pos += n;

            while (std.mem.indexOfScalar(u8, buf[0..pos], '\n')) |nl| {
                const line = buf[0..nl];
                self.dispatchCommand(line, fd) catch |err| {
                    std.log.err("IPC dispatch error: {}", .{err});
                    _ = std.posix.write(fd, "{\"ok\":false,\"error\":\"internal error\"}\n") catch {};
                };
                const remaining = pos - nl - 1;
                std.mem.copyForwards(u8, buf[0..remaining], buf[nl + 1 .. pos]);
                pos = remaining;
            }
            if (pos >= buf.len) break;
        }
        // Don't close fd here for mutating commands — drainQueue will close it after responding.
        // For read-only commands fd is already responded to. We close it only if nothing is queued.
    }

    /// Decide whether to handle immediately (read-only) or queue (mutating).
    fn dispatchCommand(self: *IpcServer, line: []const u8, fd: std.posix.fd_t) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{ .ignore_unknown_fields = true }) catch {
            _ = std.posix.write(fd, "{\"ok\":false,\"error\":\"invalid json\"}\n") catch {};
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        const cmd_val = root.object.get("cmd") orelse {
            _ = std.posix.write(fd, "{\"ok\":false,\"error\":\"missing cmd\"}\n") catch {};
            return;
        };
        const cmd = cmd_val.string;
        const args = root.object.get("args") orelse std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };

        // Read-only commands — safe to answer from IPC thread
        if (std.mem.eql(u8, cmd, "list_windows")) {
            try self.handleListWindows(fd);
            std.posix.close(fd);
            return;
        }
        if (std.mem.eql(u8, cmd, "get_workspaces")) {
            try self.handleGetWorkspaces(fd);
            std.posix.close(fd);
            return;
        }

        // Validate spawn before queuing
        if (std.mem.eql(u8, cmd, "spawn")) {
            const command = (args.object.get("command") orelse {
                _ = std.posix.write(fd, "{\"ok\":false,\"error\":\"missing command\"}\n") catch {};
                std.posix.close(fd);
                return;
            }).string;
            const bin_end = std.mem.indexOfScalar(u8, command, ' ') orelse command.len;
            const bin = command[0..bin_end];
            if (!self.binaryExists(bin)) {
                var resp_buf: [256]u8 = undefined;
                const resp = std.fmt.bufPrint(&resp_buf, "{{\"ok\":false,\"error\":\"command not found: {s}\"}}\n", .{bin}) catch "{\"ok\":false,\"error\":\"command not found\"}\n";
                _ = std.posix.write(fd, resp) catch {};
                std.posix.close(fd);
                return;
            }
        }

        // Unknown command check
        if (!isKnownMutatingCommand(cmd)) {
            var resp_buf: [256]u8 = undefined;
            const resp = std.fmt.bufPrint(&resp_buf, "{{\"ok\":false,\"error\":\"unknown command: {s}\"}}\n", .{cmd}) catch "{\"ok\":false,\"error\":\"unknown command\"}\n";
            _ = std.posix.write(fd, resp) catch {};
            std.posix.close(fd);
            return;
        }

        // Mutating commands — queue for main thread
        const cmd_copy = try self.allocator.dupe(u8, line);
        self.queue_mutex.lock();
        try self.queue.append(self.allocator, .{ .cmd = cmd_copy, .response_fd = fd });
        self.queue_mutex.unlock();

        // Wake the Wayland event loop
        if (self.wake_write_fd >= 0) {
            _ = std.posix.write(self.wake_write_fd, "x") catch {};
        }
    }

    /// Called on the main Wayland thread when the wake pipe is readable.
    fn drainQueueC(ipc: *IpcServer) c_int {
        // Drain the wake byte(s)
        var tmp: [64]u8 = undefined;
        _ = std.posix.read(ipc.wake_read_fd, &tmp) catch {};

        ipc.queue_mutex.lock();
        const items = ipc.queue.toOwnedSlice(ipc.allocator) catch {
            ipc.queue_mutex.unlock();
            return 0;
        };
        ipc.queue_mutex.unlock();
        defer ipc.allocator.free(items);

        for (items) |item| {
            defer ipc.allocator.free(item.cmd);
            defer std.posix.close(item.response_fd);
            ipc.executeMutatingCommand(item.cmd, item.response_fd) catch |err| {
                std.log.err("IPC execute error: {}", .{err});
                _ = std.posix.write(item.response_fd, "{\"ok\":false,\"error\":\"internal error\"}\n") catch {};
            };
        }
        return 0;
    }

    /// Execute a mutating command on the main Wayland thread.
    fn executeMutatingCommand(self: *IpcServer, line: []const u8, fd: std.posix.fd_t) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const root = parsed.value;
        const cmd = root.object.get("cmd").?.string;
        const args = root.object.get("args") orelse std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };

        // Simple no-arg actions — dispatch through executeAction
        if (getSimpleAction(cmd)) |action| {
            const Keybinding = @import("Config.zig").Keybinding;
            const kb: Keybinding = .{};
            self.server.executeAction(action, kb, null);
            _ = std.posix.write(fd, "{\"ok\":true}\n") catch {};
            return;
        }

        if (std.mem.eql(u8, cmd, "spawn")) {
            const command = args.object.get("command").?.string;
            self.server.spawn(command);
            _ = std.posix.write(fd, "{\"ok\":true}\n") catch {};

        } else if (std.mem.eql(u8, cmd, "focus_window")) {
            const title = (args.object.get("title") orelse {
                _ = std.posix.write(fd, "{\"ok\":false,\"error\":\"missing title\"}\n") catch {};
                return;
            }).string;
            const View = @import("View.zig");
            var found = false;
            outer: for (self.server.workspaces) |ws| {
                var it = ws.views.link.next;
                while (it != &ws.views.link) : (it = it.?.next) {
                    const view: *View.Toplevel = @fieldParentPtr("link", it.?);
                    const window_title = std.mem.span(view.xdg_toplevel.title orelse "");
                    if (std.mem.indexOf(u8, window_title, title) != null) {
                        self.server.focusView(view, view.xdg_toplevel.base.surface);
                        found = true;
                        break :outer;
                    }
                }
            }
            if (found) {
                _ = std.posix.write(fd, "{\"ok\":true}\n") catch {};
            } else {
                _ = std.posix.write(fd, "{\"ok\":false,\"error\":\"window not found\"}\n") catch {};
            }

        } else if (std.mem.eql(u8, cmd, "switch_workspace")) {
            const index_val = args.object.get("index") orelse {
                _ = std.posix.write(fd, "{\"ok\":false,\"error\":\"missing index\"}\n") catch {};
                return;
            };
            // Accept both integer and string
            const index: u32 = switch (index_val) {
                .integer => |n| @intCast(n),
                .string => |s| std.fmt.parseInt(u32, s, 10) catch {
                    _ = std.posix.write(fd, "{\"ok\":false,\"error\":\"invalid index\"}\n") catch {};
                    return;
                },
                else => {
                    _ = std.posix.write(fd, "{\"ok\":false,\"error\":\"invalid index type\"}\n") catch {};
                    return;
                },
            };
            if (index == 0 or index > self.server.workspaces.len) {
                _ = std.posix.write(fd, "{\"ok\":false,\"error\":\"index out of range\"}\n") catch {};
                return;
            }
            self.server.switchToWorkspace(index - 1);
            _ = std.posix.write(fd, "{\"ok\":true}\n") catch {};
        } else if (std.mem.eql(u8, cmd, "move_to_workspace")) {
            const index_val = args.object.get("index") orelse {
                _ = std.posix.write(fd, "{\"ok\":false,\"error\":\"missing index\"}\n") catch {};
                return;
            };
            const index: u32 = switch (index_val) {
                .integer => |n| @intCast(n),
                .string => |s| std.fmt.parseInt(u32, s, 10) catch {
                    _ = std.posix.write(fd, "{\"ok\":false,\"error\":\"invalid index\"}\n") catch {};
                    return;
                },
                else => {
                    _ = std.posix.write(fd, "{\"ok\":false,\"error\":\"invalid index type\"}\n") catch {};
                    return;
                },
            };
            if (index == 0 or index > self.server.workspaces.len) {
                _ = std.posix.write(fd, "{\"ok\":false,\"error\":\"index out of range\"}\n") catch {};
                return;
            }
            const Keybinding = @import("Config.zig").Keybinding;
            var kb: Keybinding = .{};
            kb.action = .move_workspace;
            kb.workspace_index = index;
            self.server.executeAction(.move_workspace, kb, null);
            _ = std.posix.write(fd, "{\"ok\":true}\n") catch {};

        } else if (std.mem.eql(u8, cmd, "type_text")) {
            const text = (args.object.get("text") orelse {
                _ = std.posix.write(fd, "{\"ok\":false,\"error\":\"missing text\"}\n") catch {};
                return;
            }).string;
            self.server.typeText(text);
            _ = std.posix.write(fd, "{\"ok\":true}\n") catch {};

        } else if (std.mem.eql(u8, cmd, "set_display_mode")) {
            const mode_str = (args.object.get("mode") orelse {
                _ = std.posix.write(fd, "{\"ok\":false,\"error\":\"missing mode\"}\n") catch {};
                return;
            }).string;
            const mode: DisplayMode = if (std.mem.eql(u8, mode_str, "discrete"))
                .discrete
            else if (std.mem.eql(u8, mode_str, "spanned"))
                .spanned
            else if (std.mem.eql(u8, mode_str, "mirror"))
                .mirror
            else {
                _ = std.posix.write(fd, "{\"ok\":false,\"error\":\"invalid mode, use: discrete, spanned, mirror\"}\n") catch {};
                return;
            };
            self.server.display_mode = mode;
            self.server.updateLayout();
            _ = std.posix.write(fd, "{\"ok\":true}\n") catch {};
        }
    }

    fn handleListWindows(self: *IpcServer, fd: std.posix.fd_t) !void {
        const View = @import("View.zig");
        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "{\"ok\":true,\"windows\":[");
        var first = true;
        for (self.server.workspaces) |ws| {
            var it = ws.views.link.next;
            while (it != &ws.views.link) : (it = it.?.next) {
                const view: *View.Toplevel = @fieldParentPtr("link", it.?);
                if (!view.mapped) continue;
                const title = std.mem.span(view.xdg_toplevel.title orelse "unnamed");
                const app_id = std.mem.span(view.xdg_toplevel.app_id orelse "unknown");
                const focused = self.server.seat.keyboard_state.focused_surface == view.xdg_toplevel.base.surface;
                if (!first) try out.appendSlice(self.allocator, ",");
                try out.writer(self.allocator).print("{{\"title\":\"{s}\",\"app_id\":\"{s}\",\"focused\":{},\"workspace\":\"{s}\",\"hidden\":{},\"floating\":{},\"maximized\":{},\"fullscreen\":{},\"locked\":{},\"sticky\":{},\"marked\":{},\"urgent\":{}}}", .{
                    title, app_id, focused, ws.name,
                    view.hidden, view.is_floating, view.is_maximized, view.is_fullscreen,
                    view.locked, view.sticky, view.marked, view.urgent,
                });
                first = false;
            }
        }
        try out.appendSlice(self.allocator, "]}\n");
        _ = std.posix.write(fd, out.items) catch {};
    }

    fn handleGetWorkspaces(self: *IpcServer, fd: std.posix.fd_t) !void {
        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "{\"ok\":true,\"workspaces\":[");
        for (self.server.workspaces, 0..) |ws, i| {
            const focused = self.server.focused_workspace == ws;
            const has_views = ws.views.link.next != &ws.views.link;
            if (i > 0) try out.appendSlice(self.allocator, ",");
            try out.writer(self.allocator).print("{{\"index\":{d},\"name\":\"{s}\",\"focused\":{},\"has_views\":{},\"layout\":\"{s}\"}}", .{ i + 1, ws.name, focused, has_views, ws.layout.name() });
        }
        try out.appendSlice(self.allocator, "]}\n");
        _ = std.posix.write(fd, out.items) catch {};
    }

    fn binaryExists(self: *IpcServer, bin: []const u8) bool {
        if (std.mem.startsWith(u8, bin, "/")) {
            std.fs.accessAbsolute(bin, .{}) catch return false;
            return true;
        }
        const path_env = std.process.getEnvVarOwned(self.allocator, "PATH") catch return true;
        defer self.allocator.free(path_env);
        var it = std.mem.splitScalar(u8, path_env, ':');
        while (it.next()) |dir| {
            const full = std.fs.path.join(self.allocator, &.{ dir, bin }) catch continue;
            defer self.allocator.free(full);
            std.fs.accessAbsolute(full, .{}) catch continue;
            return true;
        }
        return false;
    }
};
