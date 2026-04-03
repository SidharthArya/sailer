pub const c = @cImport({
    @cDefine("WLR_USE_UNSTABLE", "1");
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("pixman.h");
    @cInclude("wlr/types/wlr_shm.h");
    @cInclude("wlr/types/wlr_scene.h");
    @cInclude("wlr/types/wlr_buffer.h");
    @cInclude("wlr/interfaces/wlr_buffer.h");
    @cInclude("wlr/types/wlr_output.h");
    @cInclude("wlr/render/wlr_renderer.h");
    @cInclude("wlr/util/box.h");
    @cInclude("wayland-server-core.h");
    @cInclude("drm_fourcc.h");
});
