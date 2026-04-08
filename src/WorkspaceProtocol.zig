const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const ext = wayland.server.ext;
const Server = @import("Server.zig").Server;
const Workspace = @import("Workspace.zig").Workspace;
const Output = @import("Output.zig").Output;
const c = @import("c.zig").c;

pub const WorkspaceProtocol = struct {
    server: *Server,
    manager_global: *wl.Global,
    next_id: u32 = 0xff000000,
    
    // We track resource instances to send events when state changes
    groups: std.ArrayListUnmanaged(*WorkspaceGroup) = .{},
    
    pub fn init(server: *Server) !*WorkspaceProtocol {
        const self = try std.heap.c_allocator.create(WorkspaceProtocol);
        self.* = .{
            .server = server,
            .manager_global = try wl.Global.create(server.wl_server, ext.WorkspaceManagerV1, 1, *WorkspaceProtocol, self, bindManager),
        };
        return self;
    }

    fn bindManager(client: *wl.Client, self: *WorkspaceProtocol, version: u32, id: u32) void {
        const resource = ext.WorkspaceManagerV1.create(client, version, id) catch return;
        resource.setHandler(*WorkspaceProtocol, handleRequest, null, self);
        
        // When a client binds, we must inform them about all workspace groups.
        // Sailer uses discrete mode (workspaces per output) usually.
        // We'll create a group for each output.
        var it = self.server.outputs.link.next;
        while (it != &self.server.outputs.link) {
            const output: *Output = @fieldParentPtr("link", it.?);
            const group = WorkspaceGroup.create(self, client, version, output) catch continue;
            self.groups.append(std.heap.c_allocator, group) catch {};
            resource.sendWorkspaceGroup(group.resource);
            it = it.?.next;
        }
        resource.sendDone();
    }

    fn handleRequest(resource: *ext.WorkspaceManagerV1, request: ext.WorkspaceManagerV1.Request, self: *WorkspaceProtocol) void {
        switch (request) {
            .commit => {},
            .stop => resource.destroy(),
        }
        _ = self;
    }

    pub fn notifyActive(self: *WorkspaceProtocol, workspace: *Workspace) void {
        for (self.groups.items) |group| {
            group.notifyActive(workspace);
        }
    }

    pub fn notifyUrgent(self: *WorkspaceProtocol, workspace: *Workspace) void {
        for (self.groups.items) |group| {
            group.notifyUrgent(workspace);
        }
    }

    fn removeGroup(self: *WorkspaceProtocol, group: *WorkspaceGroup) void {
        for (self.groups.items, 0..) |g, i| {
            if (g == group) {
                _ = self.groups.orderedRemove(i);
                break;
            }
        }
    }
};

const WorkspaceGroup = struct {
    protocol: *WorkspaceProtocol,
    resource: *ext.WorkspaceGroupHandleV1,
    output: *Output,
    handles: [10]*WorkspaceHandle = undefined,

    pub fn create(protocol: *WorkspaceProtocol, client: *wl.Client, version: u32, output: *Output) !*WorkspaceGroup {
        const self = try std.heap.c_allocator.create(WorkspaceGroup);
        const id = protocol.next_id;
        protocol.next_id += 1;
        
        const resource = try ext.WorkspaceGroupHandleV1.create(client, version, id);
        self.* = .{
            .protocol = protocol,
            .resource = resource,
            .output = output,
        };
        resource.setHandler(*WorkspaceGroup, handleRequest, struct {
            fn destroy(_: *ext.WorkspaceGroupHandleV1, data: *WorkspaceGroup) void {
                data.protocol.removeGroup(data);
                std.heap.c_allocator.destroy(data);
            }
        }.destroy, self);
        
        // Initial events
        resource.sendCapabilities(.{ .create_workspace = false });
        
        // Find wl_output resource for this client
        if (findOutputResource(output, client)) |out_res| {
            resource.sendOutputEnter(out_res);
        }

        // Create workspace handles for this group
        for (protocol.server.workspaces, 0..) |ws, i| {
            const handle = try WorkspaceHandle.create(self, client, version, ws);
            self.handles[i] = handle;
            self.resource.sendWorkspaceEnter(handle.resource);
        }

        return self;
    }

    fn handleRequest(_: *ext.WorkspaceGroupHandleV1, request: ext.WorkspaceGroupHandleV1.Request, _: *WorkspaceGroup) void {
        switch (request) {
            .create_workspace => {},
            .destroy => {},
        }
    }

    pub fn notifyActive(self: *WorkspaceGroup, workspace: *Workspace) void {
        for (self.handles) |h| {
            h.updateState(workspace == h.workspace);
        }
    }

    pub fn notifyUrgent(self: *WorkspaceGroup, workspace: *Workspace) void {
        for (self.handles) |h| {
            if (h.workspace == workspace) {
                h.updateState(self.protocol.server.focused_workspace == workspace);
            }
        }
    }
};

const WorkspaceHandle = struct {
    group: *WorkspaceGroup,
    resource: *ext.WorkspaceHandleV1,
    workspace: *Workspace,

    pub fn create(group: *WorkspaceGroup, client: *wl.Client, version: u32, workspace: *Workspace) !*WorkspaceHandle {
        const self = try std.heap.c_allocator.create(WorkspaceHandle);
        const id = group.protocol.next_id;
        group.protocol.next_id += 1;
        
        const resource = try ext.WorkspaceHandleV1.create(client, version, id);
        
        self.* = .{
            .group = group,
            .resource = resource,
            .workspace = workspace,
        };
        resource.setHandler(*WorkspaceHandle, handleRequest, struct {
            fn destroy(_: *ext.WorkspaceHandleV1, data: *WorkspaceHandle) void {
                std.heap.c_allocator.destroy(data);
            }
        }.destroy, self);

        // Initial state
        resource.sendName(@as([*:0]const u8, @ptrCast(workspace.name.ptr)));
        
        const is_active = (group.protocol.server.focused_workspace == workspace);
        const is_urgent = workspace.isUrgent();
        
        const state = ext.WorkspaceHandleV1.State{
            .active = is_active,
            .urgent = is_urgent,
            .hidden = false,
        };
        resource.sendState(state);

        // Capabilities: we support activation
        resource.sendCapabilities(.{ .activate = true, .deactivate = false, .remove = false, .assign = false });

        return self;
    }

    pub fn updateState(self: *WorkspaceHandle, is_active: bool) void {
        const state = ext.WorkspaceHandleV1.State{
            .active = is_active,
            .urgent = self.workspace.isUrgent(),
            .hidden = false,
        };
        self.resource.sendState(state);
    }

    fn handleRequest(_: *ext.WorkspaceHandleV1, request: ext.WorkspaceHandleV1.Request, self: *WorkspaceHandle) void {
        switch (request) {
            .destroy => {},
            .activate => {
                const server = self.group.protocol.server;
                server.activateWorkspace(self.workspace);
            },
            .deactivate => {},
            .assign => {},
            .remove => {},
        }
    }
};

fn findOutputResource(output: *Output, client: *wl.Client) ?*wl.Output {
    var it = output.wlr_output.resources.link.next;
    while (it != &output.wlr_output.resources.link) {
        const resource = wl.Resource.fromLink(it.?);
        if (resource.getClient() == client) {
            return @ptrCast(resource);
        }
        it = it.?.next;
    }
    return null;
}
