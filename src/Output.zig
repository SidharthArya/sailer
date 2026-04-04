const std = @import("std");
const posix = std.posix;
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("Server.zig").Server;
const Bar = @import("Bar.zig").Bar;

pub const Output = struct {
    server: *Server,
    wlr_output: *wlr.Output,

    link: wl.list.Link = undefined,
    frame: wl.Listener(*wlr.Output) = .init(Output.handleFrame),
    request_state: wl.Listener(*wlr.Output.event.RequestState) = .init(Output.handleRequestState),
    destroy: wl.Listener(*wlr.Output) = .init(Output.handleDestroy),
    background: ?*wlr.SceneRect = null,
    bar: ?*Bar = null,

    pub fn create(server: *Server, wlr_output: *wlr.Output) !*Output {
        const output = try std.heap.c_allocator.create(Output);
        output.* = .{
            .server = server,
            .wlr_output = wlr_output,
        };

        // 1. Register our listeners FIRST (at the head of the signal list in C libwayland).
        // This matches the order in tinywl.zig and ensures we are at the head of the list.
        wlr_output.events.frame.add(&output.frame);
        wlr_output.events.request_state.add(&output.request_state);
        wlr_output.events.destroy.add(&output.destroy);

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
            bg.node.setEnabled(true);
            std.log.info("Background created for {s} at ({d}, {d}) {d}x{d} (parent=bg_tree)", .{ wlr_output.name, box.x, box.y, box.width, box.height });
        }

        // 4. Create status bar
        output.bar = null;

        return output;
    }

    fn handleFrame(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const output: *Output = @fieldParentPtr("frame", listener);

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

        //        if (output.bar) |bar| bar.update();
        // TODO: Bar update is commented out here — it's driven by a timer in Server instead.
        //       Decide on one approach and remove the dead code.

        if (!scene_output.commit(null)) {
            std.log.err("scene_output.commit failed on {s}", .{output.wlr_output.name});
            return;
        }

        var now = posix.clock_gettime(posix.CLOCK.MONOTONIC) catch return;
        scene_output.sendFrameDone(&now);
    }

    fn handleRequestState(
        listener: *wl.Listener(*wlr.Output.event.RequestState),
        event: *wlr.Output.event.RequestState,
    ) void {
        const output: *Output = @fieldParentPtr("request_state", listener);
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
        const output: *Output = @fieldParentPtr("destroy", listener);
        const server = output.server;

        std.log.info("Output '{s}' destroyed", .{output.wlr_output.name});

        output.destroy.link.remove();
        output.frame.link.remove();
        output.request_state.link.remove();
        output.link.remove();

        for (server.workspaces) |ws| {
            if (ws.visible_on == output) ws.visible_on = null;
        }

        if (output.background) |bg| bg.node.destroy();
        if (output.bar) |bar| bar.deinit();
        std.heap.c_allocator.destroy(output);
    }
};
