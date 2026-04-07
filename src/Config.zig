const std = @import("std");
const xkb = @import("xkbcommon");
const wlr = @import("wlroots");
pub const Action = enum {
    spawn,
    focus_left,
    focus_right,
    resize_shrink,
    resize_expand,
    move_left,
    move_right,
    move_up,
    move_down,
    reorder_left,
    reorder_right,
    switch_workspace,
    toggle_layout,
    smart_view,
    terminate,
    set_display_mode,
    cycle_display_mode,
    focus_output,
    get_screenshot,
    screenshot,
    toggle_locked,
    toggle_sticky,
    toggle_private,
    toggle_marked,
    toggle_hidden,
    toggle_urgent,
    toggle_scratchpad,
    close,
    toggle_maximize,
    toggle_fullscreen,
    toggle_floating,
    toggle_floating_layout,
    toggle_tiling_layout,
    toggle_ribbon_layout,
    reload_config,
};

pub const DisplayMode = enum {
    discrete,
    spanned,
    mirror,
};

pub const FocusOnClose = enum {
    previous,
    last,
};

pub const LayoutKind = enum {
    ribbon,
    tiling,
    floating,
    smart_view,
};

pub const BarConfig = struct {
    enabled: bool = true,
    exclusive: bool = true,
    height: i32 = 32,
    font_size: u32 = 11,
    // TODO: Add configurable bar position (top/bottom) and per-output bar enable/disable.
    refresh_interval: u32 = 10000, // ms
};

/// Resolve a key name string to an xkb keysym, trying exact match first then lowercase.
pub fn keysymFromName(key: []const u8) xkb.Keysym {
    if (key.len == 0) return .NoSymbol;
    const namez = std.heap.c_allocator.dupeZ(u8, key) catch return .NoSymbol;
    defer std.heap.c_allocator.free(namez);
    var sym = xkb.Keysym.fromName(namez, .no_flags);
    if (sym == .NoSymbol) {
        const lower = std.ascii.allocLowerString(std.heap.c_allocator, key) catch return .NoSymbol;
        defer std.heap.c_allocator.free(lower);
        const lowerz = std.heap.c_allocator.dupeZ(u8, lower) catch return .NoSymbol;
        defer std.heap.c_allocator.free(lowerz);
        sym = xkb.Keysym.fromName(lowerz, .no_flags);
    }
    return sym;
}

/// Resolve a slice of modifier name strings to a ModifierMask.
pub fn modifiersFromNames(modifiers: []const []const u8) wlr.Keyboard.ModifierMask {
    var mask = wlr.Keyboard.ModifierMask{};
    for (modifiers) |m| {
        if (std.ascii.eqlIgnoreCase(m, "ctrl")) mask.ctrl = true;
        if (std.ascii.eqlIgnoreCase(m, "shift")) mask.shift = true;
        if (std.ascii.eqlIgnoreCase(m, "alt") or std.ascii.eqlIgnoreCase(m, "mod1")) mask.alt = true;
        if (std.ascii.eqlIgnoreCase(m, "logo") or std.ascii.eqlIgnoreCase(m, "mod4") or std.ascii.eqlIgnoreCase(m, "super")) mask.logo = true;
    }
    return mask;
}

pub const SequenceKey = struct {
    key: []const u8 = "",
    modifiers: []const []const u8 = &.{},

    pub fn getKeysym(self: SequenceKey) xkb.Keysym {
        return keysymFromName(self.key);
    }

    pub fn getModifiers(self: SequenceKey) wlr.Keyboard.ModifierMask {
        return modifiersFromNames(self.modifiers);
    }
};

pub const Keybinding = struct {
    key: []const u8 = "",
    modifiers: []const []const u8 = &.{},
    action: ?Action = null,
    command: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    workspace_index: ?u32 = null,
    display_mode: ?DisplayMode = null,
    sequence: ?[]SequenceKey = null,

    pub fn getKeysym(self: Keybinding) xkb.Keysym {
        return keysymFromName(self.key);
    }

    pub fn getModifiers(self: Keybinding) wlr.Keyboard.ModifierMask {
        return modifiersFromNames(self.modifiers);
    }
};

pub const Config = struct {
    keybindings: []Keybinding,
    font: []const u8 = "/usr/share/fonts/TTF/DejaVuSans.ttf",
    split_ratio: f32 = 0.5,
    gap: i32 = 20,
    focus_on_close: FocusOnClose = .previous,
    default_layout: LayoutKind = .ribbon,
    default_display_mode: DisplayMode = .discrete,
    bar: BarConfig = .{},
    repeat_rate: u32 = 25,
    repeat_delay: u32 = 600,

    pub fn load(allocator: std.mem.Allocator) !Config {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.NoHome;
        defer allocator.free(home);

        const config_dir = try std.fs.path.join(allocator, &[_][]const u8{ home, ".config", "sailer" });
        defer allocator.free(config_dir);

        var dir = std.fs.openDirAbsolute(config_dir, .{}) catch |err| {
            if (err == error.FileNotFound) return try default(allocator);
            return err;
        };
        defer dir.close();

        const extensions = [_][]const u8{ ".yaml", ".yml", ".json" };
        var content: ?[]u8 = null;
        var found_path: ?[]const u8 = null;

        for (extensions) |ext| {
            const name = try std.mem.concat(allocator, u8, &[_][]const u8{ "config", ext });
            defer allocator.free(name);
            if (dir.openFile(name, .{})) |file| {
                defer file.close();
                content = try file.readToEndAlloc(allocator, 1024 * 1024);
                found_path = try std.fs.path.join(allocator, &[_][]const u8{ config_dir, name });
                break;
            } else |_| continue;
        }

        if (content) |c| {
            defer allocator.free(c);
            std.log.info("Loading config from: {s}", .{found_path.?});
            
            var json_str: []u8 = c;
            var child: ?std.process.Child = null;
            
            if (std.mem.endsWith(u8, found_path.?, ".yaml") or std.mem.endsWith(u8, found_path.?, ".yml")) {
                // TODO: Replace the python3 yaml->json subprocess with a native Zig YAML parser
                //       (e.g. the bundled ymlz dependency) to remove the python3 runtime requirement.
                const py_cmd = [_][]const u8{
                    "python3",
                    "-c",
                    "import yaml, json, sys; print(json.dumps(yaml.safe_load(sys.stdin.read())))"
                };
                child = std.process.Child.init(&py_cmd, allocator);
                child.?.stdin_behavior = .Pipe;
                child.?.stdout_behavior = .Pipe;
                child.?.stderr_behavior = .Ignore;
                
                try child.?.spawn();
                try child.?.stdin.?.writeAll(c);
                child.?.stdin.?.close();
                child.?.stdin = null;
                
                json_str = try child.?.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
            }
            defer {
                if (child) |*ch| {
                    _ = ch.wait() catch {};
                }
            }

            allocator.free(found_path.?);
            
            const parsed = std.json.parseFromSlice(Config, allocator, json_str, .{ .ignore_unknown_fields = true }) catch |err| {
                std.log.err("Failed to parse config: {}", .{err});
                return try default(allocator);
            };
            std.log.info("Loaded config with {} keybindings", .{parsed.value.keybindings.len});
            return parsed.value;
        }

        std.log.warn("No config found, using default", .{});
        return try default(allocator);
    }

    pub fn default(allocator: std.mem.Allocator) !Config {
        // TODO: The default config embeds no keybindings, making the compositor unusable out of the box.
        //       Add a sensible set of default keybindings (e.g. Super+Return for terminal, Super+Q to close).
        const default_json = 
            \\{
            \\  "font": "/usr/share/fonts/TTF/DejaVuSans.ttf",
            \\  "split_ratio": 0.5,
            \\  "gap": 8,
            \\  "focus_on_close": "previous",
            \\  "repeat_rate": 25,
            \\  "repeat_delay": 600,
            \\  "bar": {
            \\    "enabled": true,
            \\    "exclusive": true,
            \\    "height": 32,
            \\    "font_size": 11,
            \\    "refresh_interval": 10000
            \\  },
            \\  "keybindings": []
            \\}
        ;
        const parsed = try std.json.parseFromSlice(Config, allocator, default_json, .{ .ignore_unknown_fields = true });
        return parsed.value;
    }
};

