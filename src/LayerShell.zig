const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("Server.zig").Server;
const c = @import("c.zig").c;

pub const LayerSurface = struct {
    server: *Server,
    link: wl.list.Link = undefined,
    wlr_layer_surface: *wlr.LayerSurfaceV1,
    scene_layer_surface: *wlr.SceneLayerSurfaceV1,
    
    output: ?*wlr.Output = null,

    commit: wl.Listener(*wlr.Surface) = .init(LayerSurface.handleCommit),
    map: wl.Listener(void) = .init(LayerSurface.handleMap),
    unmap: wl.Listener(void) = .init(LayerSurface.handleUnmap),
    destroy: wl.Listener(*wlr.LayerSurfaceV1) = .init(LayerSurface.handleDestroy),
    new_popup: wl.Listener(*wlr.XdgPopup) = .init(LayerSurface.handleNewPopup),

    pub fn create(server: *Server, wlr_layer_surface: *wlr.LayerSurfaceV1) !*LayerSurface {
        const self = try std.heap.c_allocator.create(LayerSurface);
        
        // Choose output
        const output = wlr_layer_surface.output orelse blk: {
            if (server.outputs.link.next != &server.outputs.link) {
                const first = @as(*@import("Output.zig").Output, @fieldParentPtr("link", server.outputs.link.next.?));
                break :blk first.wlr_output;
            }
            break :blk null;
        };

        const parent_tree = server.getLayerTree(wlr_layer_surface.pending.layer);
        const scene_layer_surface = try parent_tree.createSceneLayerSurfaceV1(wlr_layer_surface);
        scene_layer_surface.tree.node.data = null;

        self.* = .{
            .server = server,
            .wlr_layer_surface = wlr_layer_surface,
            .scene_layer_surface = scene_layer_surface,
            .output = output,
        };

        server.layer_surfaces.prepend(self);

        wlr_layer_surface.surface.data = self;
        
        wlr_layer_surface.surface.events.commit.add(&self.commit);
        wlr_layer_surface.surface.events.map.add(&self.map);
        wlr_layer_surface.surface.events.unmap.add(&self.unmap);
        wlr_layer_surface.events.destroy.add(&self.destroy);
        wlr_layer_surface.events.new_popup.add(&self.new_popup);

        return self;
    }

    pub fn configure(self: *LayerSurface) void {
        if (!self.wlr_layer_surface.initialized) return;
        const output = self.output orelse return;
        var box: wlr.Box = undefined;
        self.server.output_layout.getBox(output, &box);
        
        var usable_area = box;
        self.scene_layer_surface.configure(&box, &usable_area);
    }

    fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const self: *LayerSurface = @fieldParentPtr("commit", listener);
        
        const pending = self.wlr_layer_surface.pending;
        const current = self.wlr_layer_surface.current;

        std.log.debug("Layer surface commit: {s} (initial={}, mapped={})", .{
            self.wlr_layer_surface.namespace,
            self.wlr_layer_surface.initial_commit,
            self.wlr_layer_surface.surface.mapped,
        });

        const changed = (pending.committed.layer or pending.committed.exclusive_zone or pending.committed.anchor or pending.committed.margin);
        if (self.wlr_layer_surface.initial_commit or changed) {
            // Update scene graph layer if it changed
            if (pending.layer != current.layer) {
                const parent_tree = self.server.getLayerTree(pending.layer);
                self.scene_layer_surface.tree.node.reparent(parent_tree);
            }
            
            // If exclusive zone or margins changed, we need to re-arrange workspaces
            // For now, we'll just trigger a global layout update
            self.server.updateLayout();
        }
    }

    fn handleMap(listener: *wl.Listener(void)) void {
        const self: *LayerSurface = @fieldParentPtr("map", listener);
        std.log.info("Layer surface MAP: {s}", .{self.wlr_layer_surface.namespace});
        self.scene_layer_surface.tree.node.setEnabled(true);
        self.server.updateLayout();
    }

    fn handleUnmap(listener: *wl.Listener(void)) void {
        const self: *LayerSurface = @fieldParentPtr("unmap", listener);
        self.server.updateLayout();
    }

    fn handleDestroy(listener: *wl.Listener(*wlr.LayerSurfaceV1), _: *wlr.LayerSurfaceV1) void {
        const self: *LayerSurface = @fieldParentPtr("destroy", listener);
        
        self.link.remove();
        self.commit.link.remove();
        self.map.link.remove();
        self.unmap.link.remove();
        self.destroy.link.remove();
        self.new_popup.link.remove();

        std.heap.c_allocator.destroy(self);
    }

    fn handleNewPopup(listener: *wl.Listener(*wlr.XdgPopup), xdg_popup: *wlr.XdgPopup) void {
        const self: *LayerSurface = @fieldParentPtr("new_popup", listener);
        // We can reuse the XDG popup handling from Server if we make it accessible
        self.server.handleNewXdgPopup(xdg_popup, self.scene_layer_surface.tree);
    }
};
