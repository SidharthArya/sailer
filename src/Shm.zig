const std = @import("std");
const posix = std.posix;
const wlr = @import("wlroots");

const c = @cImport({
    @cDefine("WLR_USE_UNSTABLE", "1");
    @cInclude("wlr/types/wlr_buffer.h");
    @cInclude("wlr/interfaces/wlr_buffer.h");
});

pub const ShmBuffer = struct {
    wlr_buffer: c.wlr_buffer,
    data: []align(4096) u8,
    stride: usize,
    format: u32,

    const impl = c.wlr_buffer_impl{
        .destroy = destroy,
        .get_dmabuf = null,
        .get_shm = null,
        .begin_data_ptr_access = begin_data_ptr_access,
        .end_data_ptr_access = end_data_ptr_access,
    };

    pub fn from(wlr_buffer: [*c]c.wlr_buffer) *ShmBuffer {
        const buf: *c.wlr_buffer = wlr_buffer.?;
        return @fieldParentPtr("wlr_buffer", buf);
    }

    fn destroy(wlr_buffer: [*c]c.wlr_buffer) callconv(.c) void {
        const self = ShmBuffer.from(wlr_buffer);
        const aligned_data: []align(4096) const u8 = self.data;
        posix.munmap(aligned_data);
        std.heap.c_allocator.destroy(self);
    }

    fn begin_data_ptr_access(wlr_buffer: [*c]c.wlr_buffer, flags: u32, data: ?*?*anyopaque, format: ?*u32, stride: ?*usize) callconv(.c) bool {
        _ = flags;
        const self = ShmBuffer.from(wlr_buffer);
        if (data) |d| d.* = self.data.ptr;
        if (format) |f| f.* = self.format;
        if (stride) |s| s.* = self.stride;
        return true;
    }

    fn end_data_ptr_access(wlr_buffer: [*c]c.wlr_buffer) callconv(.c) void {
        _ = wlr_buffer;
    }

    pub fn create(width: i32, height: i32, format: u32) !*ShmBuffer {
        const stride = @as(usize, @intCast(width)) * 4;
        const size = stride * @as(usize, @intCast(height));

        const fd = try posix.memfd_create("sailer-shm", 0);
        defer posix.close(fd);
        try posix.ftruncate(fd, size);

        const data = try posix.mmap(
            null,
            size,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );

        const self = try std.heap.c_allocator.create(ShmBuffer);
        self.* = .{
            .wlr_buffer = undefined,
            .data = data,
            .stride = stride,
            .format = format,
        };

        c.wlr_buffer_init(&self.wlr_buffer, &ShmBuffer.impl, width, height);
        return self;
    }

    pub fn getWlrBuffer(self: *ShmBuffer) *wlr.Buffer {
        return @ptrCast(&self.wlr_buffer);
    }
};
