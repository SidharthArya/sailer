const std = @import("std");
const wl = @import("wayland").server.wl;
const View = @import("View.zig");
const Workspace = @import("Workspace.zig").Workspace;
const Layout = @import("layouts/index.zig").Layout;

pub const WindowEntry = struct {
    app_id: []const u8,
    title: []const u8,
    width_percent: i32,
    x: i32,
    y: i32,
    is_floating: bool,
    order_index: u32,
};

pub const LayoutStateFile = struct {
    windows: []WindowEntry,
};

/// Build the state file path for a workspace/layout combination.
/// Caller owns the returned slice.
pub fn statePath(
    allocator: std.mem.Allocator,
    workspace_name: []const u8,
    layout_name: []const u8,
) ![]u8 {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    return std.fmt.allocPrint(
        allocator,
        "{s}/.local/share/sailer/layout-state/{s}-{s}.json",
        .{ home, workspace_name, layout_name },
    );
}

/// Serialize the current workspace views to disk for the given layout.
/// Errors are logged and swallowed — compositor operation continues.
pub fn saveState(
    allocator: std.mem.Allocator,
    workspace: *Workspace,
    layout: Layout,
) void {
    saveStateInner(allocator, workspace, layout) catch |err| {
        std.log.err("LayoutState.saveState failed: {}", .{err});
    };
}

fn saveStateInner(
    allocator: std.mem.Allocator,
    workspace: *Workspace,
    layout: Layout,
) !void {
    const layout_name = layout.name();
    const path = try statePath(allocator, workspace.name, layout_name);
    defer allocator.free(path);

    // Ensure directory exists
    const dir_end = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    const dir_path = path[0..dir_end];
    try std.fs.cwd().makePath(dir_path);

    // Build window entries
    var entries: std.ArrayList(WindowEntry) = .empty;
    defer entries.deinit(allocator);

    var order: u32 = 0;
    var it = workspace.views.link.prev;
    while (it != &workspace.views.link) : (it = it.?.prev) {
        const toplevel: *View.Toplevel = @fieldParentPtr("link", it.?);
        if (!toplevel.mapped) continue;

        const app_id: []const u8 = if (toplevel.xdg_toplevel.app_id) |a|
            std.mem.span(a)
        else
            "";
        const title: []const u8 = if (toplevel.xdg_toplevel.title) |t|
            std.mem.span(t)
        else
            "";

        try entries.append(allocator, .{
            .app_id = app_id,
            .title = title,
            .width_percent = toplevel.width_percent,
            .x = toplevel.x,
            .y = toplevel.y,
            .is_floating = toplevel.is_floating,
            .order_index = order,
        });
        order += 1;
    }

    // Serialize to JSON manually for fixed field order
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.writeAll("{\"windows\":[");
    for (entries.items, 0..) |entry, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print(
            "{{\"app_id\":{f},\"title\":{f},\"width_percent\":{d},\"x\":{d},\"y\":{d},\"is_floating\":{},\"order_index\":{d}}}",
            .{
                std.json.fmt(entry.app_id, .{}),
                std.json.fmt(entry.title, .{}),
                entry.width_percent,
                entry.x,
                entry.y,
                entry.is_floating,
                entry.order_index,
            },
        );
    }
    try writer.writeAll("]}");

    // Atomic write: write to .tmp then rename
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    {
        const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
        defer tmp_file.close();
        try tmp_file.writeAll(buf.items);
    }

    try std.fs.cwd().rename(tmp_path, path);
    std.log.info("LayoutState: saved {s} workspace {s}", .{ layout_name, workspace.name });
}

/// Deserialize and apply saved state for the given layout to the workspace.
/// If no file exists or parsing fails, the workspace is left unchanged.
pub fn restoreState(
    allocator: std.mem.Allocator,
    workspace: *Workspace,
    layout: Layout,
) void {
    restoreStateInner(allocator, workspace, layout) catch |err| {
        std.log.err("LayoutState.restoreState failed: {}", .{err});
    };
}

fn restoreStateInner(
    allocator: std.mem.Allocator,
    workspace: *Workspace,
    layout: Layout,
) !void {
    const layout_name = layout.name();
    const path = try statePath(allocator, workspace.name, layout_name);
    defer allocator.free(path);

    // Read file — silently return if absent
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(content);

    // Parse JSON
    const parsed = std.json.parseFromSlice(LayoutStateFile, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.err("LayoutState.restoreState: malformed JSON in {s}: {}", .{ path, err });
        return;
    };
    defer parsed.deinit();

    const state = parsed.value;
    if (state.windows.len == 0) return;

    // Collect current toplevels into a flat array preserving original order
    var all_toplevels: std.ArrayList(*View.Toplevel) = .empty;
    defer all_toplevels.deinit(allocator);

    var it = workspace.views.link.prev;
    while (it != &workspace.views.link) : (it = it.?.prev) {
        const toplevel: *View.Toplevel = @fieldParentPtr("link", it.?);
        if (!toplevel.mapped) continue;
        try all_toplevels.append(allocator, toplevel);
    }

    // Pass 1: match entries to toplevels (one-to-one, app_id primary, title secondary)
    const n = all_toplevels.items.len;
    const matched = try allocator.alloc(?*View.Toplevel, state.windows.len);
    defer allocator.free(matched);
    @memset(matched, null);

    const consumed = try allocator.alloc(bool, n);
    defer allocator.free(consumed);
    @memset(consumed, false);

    // Sort entries by order_index for deterministic matching
    const windows_copy = try allocator.dupe(WindowEntry, state.windows);
    defer allocator.free(windows_copy);
    std.mem.sort(WindowEntry, windows_copy, {}, struct {
        fn lessThan(_: void, a: WindowEntry, b: WindowEntry) bool {
            return a.order_index < b.order_index;
        }
    }.lessThan);

    for (windows_copy, 0..) |entry, ei| {
        // First pass: match by app_id AND title
        for (all_toplevels.items, 0..) |toplevel, ti| {
            if (consumed[ti]) continue;
            const t_app_id: []const u8 = if (toplevel.xdg_toplevel.app_id) |a| std.mem.span(a) else "";
            const t_title: []const u8 = if (toplevel.xdg_toplevel.title) |t| std.mem.span(t) else "";
            if (std.mem.eql(u8, t_app_id, entry.app_id) and std.mem.eql(u8, t_title, entry.title)) {
                matched[ei] = toplevel;
                consumed[ti] = true;
                break;
            }
        }
        // Second pass: match by app_id only (if not already matched)
        if (matched[ei] == null) {
            for (all_toplevels.items, 0..) |toplevel, ti| {
                if (consumed[ti]) continue;
                const t_app_id: []const u8 = if (toplevel.xdg_toplevel.app_id) |a| std.mem.span(a) else "";
                if (std.mem.eql(u8, t_app_id, entry.app_id)) {
                    matched[ei] = toplevel;
                    consumed[ti] = true;
                    break;
                }
            }
        }
    }

    // Pass 2: build final order — matched in order_index order, then unmatched in original order
    var final_order: std.ArrayList(*View.Toplevel) = .empty;
    defer final_order.deinit(allocator);

    for (windows_copy, 0..) |_, ei| {
        if (matched[ei]) |t| try final_order.append(allocator, t);
    }
    for (all_toplevels.items, 0..) |toplevel, ti| {
        if (!consumed[ti]) try final_order.append(allocator, toplevel);
    }

    // Pass 3: apply fields to matched toplevels
    for (windows_copy, 0..) |entry, ei| {
        if (matched[ei]) |t| {
            t.width_percent = entry.width_percent;
            t.x = entry.x;
            t.y = entry.y;
            t.is_floating = entry.is_floating;
        }
    }

    // Relink workspace.views in final_order (prev→next = last→first in ribbon order)
    workspace.views.init();
    for (final_order.items) |toplevel| {
        workspace.views.prepend(toplevel);
    }

    std.log.info("LayoutState: restored {s} workspace {s} ({d} windows)", .{
        layout_name, workspace.name, final_order.items.len,
    });
}
