const std = @import("std");
const posix = std.posix;
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("Server.zig").Server;

pub const Output = struct {
    server: *Server,
    wlr_output: *wlr.Output,

    link: wl.list.Link = undefined,
    frame: wl.Listener(*wlr.Output) = .init(Output.handleFrame),
    request_state: wl.Listener(*wlr.Output.event.RequestState) = .init(Output.handleRequestState),
    destroy: wl.Listener(*wlr.Output) = .init(Output.handleDestroy),

    pub fn create(server: *Server, wlr_output: *wlr.Output) !*Output {
        const output = try std.heap.c_allocator.create(Output);

        output.* = .{
            .server = server,
            .wlr_output = wlr_output,
        };
        wlr_output.events.frame.add(&output.frame);
        wlr_output.events.request_state.add(&output.request_state);
        wlr_output.events.destroy.add(&output.destroy);

        server.outputs.prepend(output);

        const layout_output = try server.output_layout.addAuto(wlr_output);

        const scene_output = try server.scene.createSceneOutput(wlr_output);
        server.scene_output_layout.addOutput(layout_output, scene_output);

        return output;
    }

    fn handleFrame(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const output: *Output = @fieldParentPtr("frame", listener);

        const scene_output = output.server.scene.getSceneOutput(output.wlr_output).?;
        _ = scene_output.commit(null);

        var now = posix.clock_gettime(posix.CLOCK.MONOTONIC) catch @panic("CLOCK_MONOTONIC not supported");
        scene_output.sendFrameDone(&now);
    }

    fn handleRequestState(
        listener: *wl.Listener(*wlr.Output.event.RequestState),
        event: *wlr.Output.event.RequestState,
    ) void {
        const output: *Output = @fieldParentPtr("request_state", listener);
        _ = output.wlr_output.commitState(event.state);
    }

    fn handleDestroy(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const output: *Output = @fieldParentPtr("destroy", listener);

        output.frame.link.remove();
        output.request_state.link.remove();
        output.destroy.link.remove();
        output.link.remove();

        const server = output.server;
        std.heap.c_allocator.destroy(output);

        if (server.outputs.link.next == &server.outputs.link) {
            std.log.info("Last output destroyed, terminating server", .{});
            server.wl_server.terminate();
        }
    }
};
