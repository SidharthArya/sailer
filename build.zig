const std = @import("std");
const wayland_build = @import("wayland");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("sailer", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const wlroots = b.dependency("wlroots", .{});
    const xkbcommon = b.dependency("xkbcommon", .{});
    const pixman = b.dependency("pixman", .{});

    const mod_wlroots = wlroots.module("wlroots");
    mod_wlroots.resolved_target = target;
    mod_wlroots.optimize = optimize;
    mod_wlroots.link_libc = true;
    mod_wlroots.linkSystemLibrary("wlroots-0.19", .{});
    mod_wlroots.linkSystemLibrary("pixman-1", .{});

    const mod_xkbcommon = xkbcommon.module("xkbcommon");
    mod_xkbcommon.resolved_target = target;
    mod_xkbcommon.optimize = optimize;
    mod_xkbcommon.link_libc = true;
    mod_xkbcommon.linkSystemLibrary("xkbcommon", .{});

    const mod_pixman = pixman.module("pixman");
    mod_pixman.resolved_target = target;
    mod_pixman.optimize = optimize;
    mod_pixman.link_libc = true;
    mod_pixman.linkSystemLibrary("pixman-1", .{});

    const scanner = wayland_build.Scanner.create(b, .{});

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("unstable/pointer-constraints/pointer-constraints-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/pointer-gestures/pointer-gestures-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/tablet/tablet-unstable-v2.xml");
    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");
    scanner.addSystemProtocol("unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml");
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.addSystemProtocol("staging/tearing-control/tearing-control-v1.xml");
    scanner.addSystemProtocol("staging/content-type/content-type-v1.xml");
    scanner.addSystemProtocol("staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml");
    scanner.addSystemProtocol("staging/ext-workspace/ext-workspace-v1.xml");
    scanner.addSystemProtocol("staging/xdg-toplevel-icon/xdg-toplevel-icon-v1.xml");
    scanner.addSystemProtocol("unstable/text-input/text-input-unstable-v3.xml");
    scanner.addCustomProtocol(b.path("protocols/wlr-layer-shell-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/virtual-keyboard-unstable-v1.xml"));

    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_data_device_manager", 3);
    scanner.generate("xdg_wm_base", 2);
    scanner.generate("zwlr_layer_shell_v1", 4);
    scanner.generate("zwp_virtual_keyboard_manager_v1", 1);
    scanner.generate("ext_session_lock_manager_v1", 1);
    scanner.generate("ext_image_copy_capture_manager_v1", 1);
    scanner.generate("ext_workspace_manager_v1", 1);
    scanner.generate("zwp_pointer_gestures_v1", 3);
    scanner.generate("zwp_pointer_constraints_v1", 1);
    scanner.generate("zxdg_decoration_manager_v1", 1);
    scanner.generate("zwp_tablet_manager_v2", 1);
    scanner.generate("zwp_linux_dmabuf_v1", 4);
    scanner.generate("wp_cursor_shape_manager_v1", 1);
    scanner.generate("wp_tearing_control_manager_v1", 1);
    scanner.generate("wp_content_type_manager_v1", 1);
    scanner.generate("xdg_toplevel_icon_manager_v1", 1);
    scanner.generate("zwp_text_input_manager_v3", 1);

    const mod_wayland = b.createModule(.{ .root_source_file = scanner.result });

    // Provide the xkbcommon, pixman, and wayland modules to wlroots
    mod_wlroots.addImport("xkbcommon", mod_xkbcommon);
    mod_wlroots.addImport("pixman", mod_pixman);
    mod_wlroots.addImport("wayland", mod_wayland);

    const exe = b.addExecutable(.{
        .name = "sailer",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                .{ .name = "sailer", .module = mod },
                .{ .name = "wlroots", .module = mod_wlroots },
                .{ .name = "wayland", .module = mod_wayland },
                .{ .name = "xkbcommon", .module = mod_xkbcommon },
            },
        }),
    });
    exe.root_module.addCMacro("WLR_USE_UNSTABLE", "1");

    exe.linkLibC();
    exe.linkSystemLibrary("wlroots-0.19");
    exe.linkSystemLibrary("wayland-server");
    exe.linkSystemLibrary("xkbcommon");
    exe.linkSystemLibrary("pixman-1");
    exe.linkSystemLibrary("freetype2");
    exe.linkSystemLibrary("dbus-1");

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // sailer-mcp: standalone MCP bridge binary
    const mcp_exe = b.addExecutable(.{
        .name = "sailer-mcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mcp_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    mcp_exe.linkLibC();
    b.installArtifact(mcp_exe);

    // sailer-msg: CLI client for the IPC socket
    const msg_exe = b.addExecutable(.{
        .name = "sailer-msg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/msg_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    msg_exe.linkLibC();
    b.installArtifact(msg_exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Bug exploration tests — pure logic tests, no wlroots dependency
    const bug_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bug_exploration_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_bug_tests = b.addRunArtifact(bug_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Separate step for bug exploration tests only (no compositor deps needed)
    const bug_test_step = b.step("test-bugs", "Run bug condition exploration tests");
    bug_test_step.dependOn(&run_bug_tests.step);

    // Preservation tests — pure logic tests, no wlroots dependency
    const preservation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/preservation_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_preservation_tests = b.addRunArtifact(preservation_tests);

    // Separate step for preservation tests only
    const preservation_test_step = b.step("test-preservation", "Run preservation property tests");
    preservation_test_step.dependOn(&run_preservation_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
