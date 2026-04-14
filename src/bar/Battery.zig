const std = @import("std");
const Bar = @import("../Bar.zig").Bar;
const Theme = @import("Theme.zig").Theme;
const c = @import("../c.zig").c;

pub const Battery = struct {
    var conn: ?*c.DBusConnection = null;

    const DBusErrorShadow = extern struct {
        name: [*c]const u8,
        message: [*c]const u8,
        dummy: u32,
        padding: ?*anyopaque,
    };

    pub fn render(bar: *Bar, pixels: [*]u32) void {
        if (conn == null) {
            var err_bytes: [32]u8 align(8) = undefined;
            const err = @as(*c.DBusError, @ptrCast(&err_bytes));
            c.dbus_error_init(err);
            conn = c.dbus_bus_get(c.DBUS_BUS_SYSTEM, err);
            if (c.dbus_error_is_set(err) != 0) {
                const shadow = @as(*DBusErrorShadow, @ptrCast(@alignCast(&err_bytes)));
                std.log.err("DBus connection failed: {s}", .{shadow.message});
                c.dbus_error_free(err);
                return;
            }
        }

        const percentage = getPropertyDouble("Percentage") catch |err| {
            std.log.debug("Failed to get battery percentage: {}", .{err});
            return;
        };
        const state = getPropertyUint32("State") catch 1; // Default to charging/unknown

        var status_buf: [32]u8 = undefined;
        const icon = if (state == 1) "⚡" else "B";
        const status_str = std.fmt.bufPrint(&status_buf, "[{s}] {d:0.0}%", .{ icon, percentage }) catch "B --%";

        var color = Theme.green;
        if (percentage <= 20) {
            color = Theme.red;
        } else if (percentage <= 50) {
            color = Theme.yellow;
        }

        const scale = bar.output.wlr_output.scale;
        // Draw to the left of the clock (clock is at bar.width - 60)
        // We'll place battery at bar.width - 150
        bar.drawText(pixels, status_str, bar.width - @as(i32, @intFromFloat(150.0 * scale)), @as(i32, @intFromFloat(17.0 * scale)), color);
    }

    fn getPropertyDouble(prop_name: [*c]const u8) !f64 {
        const msg = c.dbus_message_new_method_call(
            "org.freedesktop.UPower",
            "/org/freedesktop/UPower/devices/battery_BAT0",
            "org.freedesktop.DBus.Properties",
            "Get",
        ) orelse return error.DBusMessageAllocFailed;
        defer c.dbus_message_unref(msg);

        const interface: [*c]const u8 = "org.freedesktop.UPower.Device";
        if (c.dbus_message_append_args(
            msg,
            c.DBUS_TYPE_STRING,
            &interface,
            c.DBUS_TYPE_STRING,
            &prop_name,
            c.DBUS_TYPE_INVALID,
        ) == 0) return error.DBusAppendArgsFailed;

        var err_bytes: [32]u8 align(8) = undefined;
        const err = @as(*c.DBusError, @ptrCast(&err_bytes));
        c.dbus_error_init(err);
        const reply = c.dbus_connection_send_with_reply_and_block(conn, msg, -1, err) orelse {
            const shadow = @as(*DBusErrorShadow, @ptrCast(@alignCast(&err_bytes)));
            std.log.err("DBus call failed: {s}", .{shadow.message});
            c.dbus_error_free(err);
            return error.DBusCallFailed;
        };
        defer c.dbus_message_unref(reply);

        var iter: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_init(reply, &iter) == 0) return error.DBusNoReplyArgs;

        if (c.dbus_message_iter_get_arg_type(&iter) != c.DBUS_TYPE_VARIANT) return error.DBusNotAVariant;

        var sub: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&iter, &sub);

        if (c.dbus_message_iter_get_arg_type(&sub) != c.DBUS_TYPE_DOUBLE) return error.DBusNotADouble;

        var val: f64 = 0;
        c.dbus_message_iter_get_basic(&sub, &val);
        return val;
    }

    fn getPropertyUint32(prop_name: [*c]const u8) !u32 {
        const msg = c.dbus_message_new_method_call(
            "org.freedesktop.UPower",
            "/org/freedesktop/UPower/devices/battery_BAT0",
            "org.freedesktop.DBus.Properties",
            "Get",
        ) orelse return error.DBusMessageAllocFailed;
        defer c.dbus_message_unref(msg);

        const interface: [*c]const u8 = "org.freedesktop.UPower.Device";
        if (c.dbus_message_append_args(
            msg,
            c.DBUS_TYPE_STRING,
            &interface,
            c.DBUS_TYPE_STRING,
            &prop_name,
            c.DBUS_TYPE_INVALID,
        ) == 0) return error.DBusAppendArgsFailed;

        var err_bytes: [32]u8 align(8) = undefined;
        const err = @as(*c.DBusError, @ptrCast(&err_bytes));
        c.dbus_error_init(err);
        const reply = c.dbus_connection_send_with_reply_and_block(conn, msg, -1, err) orelse {
            c.dbus_error_free(err);
            return error.DBusCallFailed;
        };
        defer c.dbus_message_unref(reply);

        var iter: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_init(reply, &iter) == 0) return error.DBusNoReplyArgs;

        if (c.dbus_message_iter_get_arg_type(&iter) != c.DBUS_TYPE_VARIANT) return error.DBusNotAVariant;

        var sub: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&iter, &sub);

        if (c.dbus_message_iter_get_arg_type(&sub) != c.DBUS_TYPE_UINT32) return error.DBusNotAUint32;

        var val: u32 = 0;
        c.dbus_message_iter_get_basic(&sub, &val);
        return val;
    }
};
