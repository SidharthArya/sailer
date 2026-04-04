const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("Server.zig").Server;

pub const SessionLock = struct {
    server: *Server,
    wlr_lock: *wlr.SessionLockV1,
    surfaces: wl.list.Head(SessionLockSurface, .link),

    new_surface: wl.Listener(*wlr.SessionLockSurfaceV1) = .init(SessionLock.handleNewSurface),
    unlock: wl.Listener(void) = .init(SessionLock.handleUnlock),
    destroy: wl.Listener(void) = .init(SessionLock.handleDestroy),

    pub fn create(server: *Server, wlr_lock: *wlr.SessionLockV1) !*SessionLock {
        const self = try std.heap.c_allocator.create(SessionLock);
        self.* = .{
            .server = server,
            .wlr_lock = wlr_lock,
            .surfaces = undefined,
        };
        self.surfaces.init();

        wlr_lock.events.new_surface.add(&self.new_surface);
        wlr_lock.events.unlock.add(&self.unlock);
        wlr_lock.events.destroy.add(&self.destroy);

        // Notify client we are locked
        wlr_lock.sendLocked();
        
        // Hide all workspaces and bars
        server.setOverlayEnabled(true);
        wlr.Seat.keyboardNotifyClearFocus(server.seat);

        return self;
    }

    fn handleNewSurface(listener: *wl.Listener(*wlr.SessionLockSurfaceV1), wlr_surface: *wlr.SessionLockSurfaceV1) void {
        const self: *SessionLock = @fieldParentPtr("new_surface", listener);
        _ = SessionLockSurface.create(self, wlr_surface) catch |err| {
            std.log.err("Failed to create session lock surface: {}", .{err});
        };
    }

    fn handleUnlock(listener: *wl.Listener(void)) void {
        const self: *SessionLock = @fieldParentPtr("unlock", listener);
        self.server.active_session_lock = null;
        self.server.setOverlayEnabled(false);
        self.destroyInternal();
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const self: *SessionLock = @fieldParentPtr("destroy", listener);
        if (self.server.active_session_lock == self) {
            self.server.active_session_lock = null;
            self.server.setOverlayEnabled(false);
            self.server.focusTopWindow();
        }
        self.destroyInternal();
    }

    fn destroyInternal(self: *SessionLock) void {
        self.new_surface.link.remove();
        self.unlock.link.remove();
        self.destroy.link.remove();
        
        var it = self.surfaces.link.next;
        while (it != &self.surfaces.link) {
            const next = it.?.next;
            const surface: *SessionLockSurface = @fieldParentPtr("link", it.?);
            surface.destroyInternal();
            it = next;
        }

        std.heap.c_allocator.destroy(self);
    }
};

pub const SessionLockSurface = struct {
    lock: *SessionLock,
    wlr_surface: *wlr.SessionLockSurfaceV1,
    scene_surface: *wlr.SceneSurface,
    link: wl.list.Link = undefined,

    destroy: wl.Listener(void) = .init(SessionLockSurface.handleDestroy),
    commit: wl.Listener(*wlr.Surface) = .init(SessionLockSurface.handleCommit),

    pub fn create(lock: *SessionLock, wlr_surface: *wlr.SessionLockSurfaceV1) !*SessionLockSurface {
        const self = try std.heap.c_allocator.create(SessionLockSurface);
        
        // Lock surfaces go to overlay_tree
        const scene_surface = try lock.server.overlay_tree.createSceneSurface(wlr_surface.surface);
        
        self.* = .{
            .lock = lock,
            .wlr_surface = wlr_surface,
            .scene_surface = scene_surface,
        };

        const output = wlr_surface.output;
        var box: wlr.Box = undefined;
        lock.server.output_layout.getBox(output, &box);
        
        scene_surface.buffer.node.setPosition(box.x, box.y);
        _ = wlr_surface.configure(@intCast(box.width), @intCast(box.height));

        lock.surfaces.append(self);
        wlr_surface.events.destroy.add(&self.destroy);
        wlr_surface.surface.events.commit.add(&self.commit);

        // Focus the lock surface
        const kbd = lock.server.seat.keyboard_state.keyboard orelse return self;
        wlr.Seat.keyboardNotifyEnter(lock.server.seat, wlr_surface.surface, kbd.keycodes[0..kbd.num_keycodes], &kbd.modifiers);

        return self;
    }

    fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const self: *SessionLockSurface = @fieldParentPtr("commit", listener);
        _ = self;
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const self: *SessionLockSurface = @fieldParentPtr("destroy", listener);
        self.destroyInternal();
    }

    fn destroyInternal(self: *SessionLockSurface) void {
        self.link.remove();
        self.destroy.link.remove();
        self.commit.link.remove();
        self.scene_surface.buffer.node.destroy();
        std.heap.c_allocator.destroy(self);
    }
};
