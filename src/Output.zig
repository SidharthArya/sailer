const std = @import("std");
const posix = std.posix;
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("Server.zig").Server;
const Bar = @import("Bar.zig").Bar;

pub const Output = struct {
    server: *Server,
    wlr_output: *wlr.Output,

    link: wl.list.Link = .{ .next = null, .prev = null },
    background: ?*wlr.SceneRect = null,
    bar: ?*Bar = null,
    listeners: Listeners,

    pub const Listeners = extern struct {
        frame: wl.Listener(*wlr.Output),
        request_state: wl.Listener(*wlr.Output.event.RequestState),
        destroy: wl.Listener(*wlr.Output),
    };

    pub fn create(server: *Server, wlr_output: *wlr.Output) !*Output {
        const output = try std.heap.c_allocator.create(Output);
        output.server = server;
        output.wlr_output = wlr_output;
        output.link = .{ .next = null, .prev = null };
        output.background = null;
        output.bar = null;

        output.listeners.frame = .init(Output.handleFrame);
        output.listeners.request_state = .init(Output.handleRequestState);
        output.listeners.destroy = .init(Output.handleDestroy);

        // 1. Register our listeners FIRST
        wlr_output.events.frame.add(&output.listeners.frame);
        wlr_output.events.request_state.add(&output.listeners.request_state);
        wlr_output.events.destroy.add(&output.listeners.destroy);


        // CRITICAL: Create the Wayland global for this output so that clients can see it.
        // It must be created after initRender has set up the renderer.
        wlr_output.createGlobal(server.wl_server);
        errdefer wlr_output.destroyGlobal();

        server.outputs.prepend(output);

        // 2. Create the SceneOutput and register it with the output layout.
        const layout_output = try server.output_layout.addAuto(wlr_output);
        const scene_output = try server.scene.createSceneOutput(wlr_output);
        server.scene_output_layout.addOutput(layout_output, scene_output);

        // 3. Create background
        var box: wlr.Box = undefined;
        server.output_layout.getBox(wlr_output, &box);
        output.background = server.bg_tree.createSceneRect(box.width, box.height, &server.bg_color) catch null;
        if (output.background) |bg| {
            bg.node.setPosition(box.x, box.y);
            bg.node.lowerToBottom();
            bg.node.setEnabled(true);
            std.log.info("Background created for {s} at ({d}, {d}) {d}x{d} (parent=bg_tree)", .{ wlr_output.name, box.x, box.y, box.width, box.height });
        }

        // 4. Create status bar
        output.bar = null;

        return output;
    }

    fn handleFrame(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const listeners: *Output.Listeners = @fieldParentPtr("frame", listener);
        const output: *Output = @fieldParentPtr("listeners", listeners);


        if (!output.server.session_active) return;

        const scene_output = output.server.scene.getSceneOutput(output.wlr_output) orelse {
            var state = wlr.Output.State.init();
            defer state.finish();
            _ = output.wlr_output.commitState(&state);
            return;
        };

        if (output.background) |bg| {
            var box: wlr.Box = undefined;
            output.server.output_layout.getBox(output.wlr_output, &box);
            bg.setSize(box.width, box.height);
            bg.node.setPosition(box.x, box.y);
        }

        // Bar is updated by the timer in Server.handleBarTimer, not per-frame.

        if (!scene_output.commit(null)) {            std.log.err("scene_output.commit failed on {s}", .{output.wlr_output.name});
            return;
        }

        var now = posix.clock_gettime(posix.CLOCK.MONOTONIC) catch return;
        scene_output.sendFrameDone(&now);
    }

    fn handleRequestState(
        listener: *wl.Listener(*wlr.Output.event.RequestState),
        event: *wlr.Output.event.RequestState,
    ) void {
        const listeners: *Output.Listeners = @fieldParentPtr("request_state", listener);
        const output: *Output = @fieldParentPtr("listeners", listeners);

        _ = output.wlr_output.commitState(event.state);
        output.server.updateLayout();

        // Update background size
        var box: wlr.Box = undefined;
        output.server.output_layout.getBox(output.wlr_output, &box);
        if (output.background) |bg| {
            bg.setSize(box.width, box.height);
            bg.node.setPosition(box.x, box.y);
            std.log.info("Background resized for {s} to {d}x{d} at ({d}, {d})", .{ output.wlr_output.name, box.width, box.height, box.x, box.y });
        }
    }

    fn handleDestroy(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const listeners: *Output.Listeners = @fieldParentPtr("destroy", listener);
        const output: *Output = @fieldParentPtr("listeners", listeners);

        const server = output.server;

        std.log.info("Output '{s}' destroyed", .{output.wlr_output.name});

        server.output_layout.remove(output.wlr_output);
        if (server.scene.getSceneOutput(output.wlr_output)) |so| so.destroy();

        output.listeners.destroy.link.remove();
        output.listeners.frame.link.remove();
        output.listeners.request_state.link.remove();

        output.link.remove();

        for (server.workspaces) |ws| {
            if (ws.visible_on == output) ws.visible_on = null;
        }

        if (output.background) |bg| bg.node.destroy();
        if (output.bar) |bar| bar.deinit();
        std.heap.c_allocator.destroy(output);
    }
};
