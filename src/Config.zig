const std = @import("std");
const xkb = @import("xkbcommon");
const wlr = @import("wlroots");

pub const Action = enum {
    spawn,
    focus_left,
    focus_right,
    resize_shrink,
    resize_expand,
    reorder_left,
    reorder_right,
    switch_workspace,
    terminate,
};

pub const Keybinding = struct {
    key: []const u8,
    modifiers: []const []const u8,
    action: Action,
    command: ?[]const u8 = null,
    workspace_index: ?u32 = null,

    pub fn getKeysym(self: Keybinding) xkb.Keysym {
        const namez = std.heap.c_allocator.dupeZ(u8, self.key) catch return .NoSymbol;
        defer std.heap.c_allocator.free(namez);
        const sym = xkb.Keysym.fromName(namez, .no_flags);
        std.log.info("getKeysym: name='{s}', sym={d}", .{ self.key, @intFromEnum(sym) });
        return sym;
    }

    pub fn getModifiers(self: Keybinding) wlr.Keyboard.ModifierMask {
        var mask = wlr.Keyboard.ModifierMask{};
        for (self.modifiers) |m| {
            std.log.info("Parsing modifier: '{s}'", .{m});
            if (std.ascii.eqlIgnoreCase(m, "ctrl")) mask.ctrl = true;
            if (std.ascii.eqlIgnoreCase(m, "shift")) mask.shift = true;
            if (std.ascii.eqlIgnoreCase(m, "alt") or std.ascii.eqlIgnoreCase(m, "mod1")) mask.alt = true;
            if (std.ascii.eqlIgnoreCase(m, "logo") or std.ascii.eqlIgnoreCase(m, "mod4") or std.ascii.eqlIgnoreCase(m, "super")) mask.logo = true;
        }
        return mask;
    }
};

pub const Config = struct {
    keybindings: []Keybinding,

    pub fn load(allocator: std.mem.Allocator) !std.json.Parsed(Config) {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.NoHome;
        defer allocator.free(home);

        const config_path = try std.fs.path.join(allocator, &[_][]const u8{ home, ".config", "sailer", "config.json" });
        defer allocator.free(config_path);

        std.log.info("Loading config from: {s}", .{config_path});

        const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                std.log.warn("Config file not found: {s}, using default", .{config_path});
                return default(allocator);
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        const parsed = try std.json.parseFromSlice(Config, allocator, content, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        std.log.info("Loaded config with {} keybindings", .{parsed.value.keybindings.len});
        return parsed;
    }

    pub fn default(allocator: std.mem.Allocator) !std.json.Parsed(Config) {
        const default_json = "{\"keybindings\": []}";
        return std.json.parseFromSlice(Config, allocator, default_json, .{ .allocate = .alloc_always });
    }
};
