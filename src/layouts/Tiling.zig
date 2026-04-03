const std = @import("std");
const wlr = @import("wlroots");
const View = @import("../View.zig");
const Workspace = @import("../Workspace.zig").Workspace;

pub const SplitType = enum { horizontal, vertical };

pub const TilingNode = struct {
    split_type: ?SplitType = null,
    ratio: f32 = 0.5,
    view: ?*View.Toplevel = null,
    parent: ?*TilingNode = null,
    children: [2]?*TilingNode = .{ null, null },

    pub fn remove(self: *TilingNode, allocator: std.mem.Allocator, root_ptr: *?*TilingNode) void {
        const parent = self.parent;
        if (parent == null) {
            // This is the root
            root_ptr.* = null;
            allocator.destroy(self);
            return;
        }

        const sibling = if (parent.?.children[0] == self) parent.?.children[1] else parent.?.children[0];
        const grandparent = parent.?.parent;

        if (grandparent) |gp| {
            if (gp.children[0] == parent) {
                gp.children[0] = sibling;
            } else {
                gp.children[1] = sibling;
            }
            if (sibling) |s| s.parent = gp;
        } else {
            // parent was the root
            root_ptr.* = sibling;
            if (sibling) |s| s.parent = null;
        }

        allocator.destroy(parent.?);
        allocator.destroy(self);
    }

    pub fn createLeaf(allocator: std.mem.Allocator, view: *View.Toplevel) !*TilingNode {
        const node = try allocator.create(TilingNode);
        node.* = .{
            .view = view,
        };
        return node;
    }

    pub fn split(self: *TilingNode, allocator: std.mem.Allocator, new_view: *View.Toplevel) !void {
        if (self.view == null) return; // Already a split node

        const old_view = self.view.?;
        const new_leaf = try TilingNode.createLeaf(allocator, new_view);
        const old_leaf = try TilingNode.createLeaf(allocator, old_view);

        self.view = null;
        self.split_type = .horizontal; // Default
        self.children[0] = old_leaf;
        self.children[1] = new_leaf;
        old_leaf.parent = self;
        new_leaf.parent = self;
    }

    pub fn arrange(self: *TilingNode, box: wlr.Box) void {
        if (self.view) |v| {
            if (v.mapped and !v.hidden) {
                v.scene_tree.node.setEnabled(true);
                var width = box.width;
                var height = box.height;

                const min_w = v.xdg_toplevel.current.min_width;
                const min_h = v.xdg_toplevel.current.min_height;
                const max_w = v.xdg_toplevel.current.max_width;
                const max_h = v.xdg_toplevel.current.max_height;

                if (min_w > 0) width = @max(width, min_w);
                if (max_w > 0) width = @min(width, max_w);
                if (min_h > 0) height = @max(height, min_h);
                if (max_h > 0) height = @min(height, max_h);

                const bw = v.border_width;
                const xdg_w = @max(1, width - 2 * bw);
                const xdg_h = @max(1, height - 2 * bw);

                if (v.xdg_toplevel.current.width != xdg_w or v.xdg_toplevel.current.height != xdg_h) {
                    _ = wlr.XdgToplevel.setSize(v.xdg_toplevel, xdg_w, xdg_h);
                }

                v.updateLayout(width, height);

                const offset_x = @divTrunc(box.width - width, 2);
                const offset_y = @divTrunc(box.height - height, 2);

                v.scene_tree.node.setPosition(box.x + offset_x, box.y + offset_y);
                v.x = box.x + offset_x;
                v.y = box.y + offset_y;
            } else {
                v.scene_tree.node.setEnabled(false);
            }
            return;
        }

        if (self.children[0]) |c1| {
            if (self.children[1]) |c2| {
                var box1 = box;
                var box2 = box;

                if (self.split_type.? == .horizontal) {
                    const w1 = @as(i32, @intFromFloat(@as(f32, @floatFromInt(box.width)) * self.ratio));
                    box1.width = w1;
                    box2.x += w1;
                    box2.width -= w1;
                } else {
                    const h1 = @as(i32, @intFromFloat(@as(f32, @floatFromInt(box.height)) * self.ratio));
                    box1.height = h1;
                    box2.y += h1;
                    box2.height -= h1;
                }

                c1.arrange(box1);
                c2.arrange(box2);
            }
        }
    }

    pub fn findNodeForView(self: *TilingNode, view: *View.Toplevel) ?*TilingNode {
        if (self.view == view) return self;
        if (self.children[0]) |c| if (c.findNodeForView(view)) |n| return n;
        if (self.children[1]) |c| if (c.findNodeForView(view)) |n| return n;
        return null;
    }
};

pub const Tiling = struct {
    root: ?*TilingNode = null,

    pub fn arrange(self: *Tiling, ws: *Workspace, box: wlr.Box) void {
        if (self.root) |root| {
            var local_box = box;
            local_box.x = 0;
            local_box.y = 0;
            root.arrange(local_box);
        }

        ws.scene_tree.node.setPosition(box.x, box.y);
    }
};
