const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vk_headers = b.dependency("vulkan_headers", .{
        .target = target,
        .optimize = optimize,
    });
    const registry = vk_headers.path("registry/vk.xml");

    const glfw = b.dependency("glfw", .{
        .target = target,
        .optimize = optimize,
        .wayland = true,
    });

    const translate_c = b.dependency("translate_c", .{});
    const translator: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translator.addSystemIncludePath(glfw.artifact("glfw").getEmittedIncludeTree());
    translator.addSystemIncludePath(vk_headers.path("include"));

    const vulkan = b.dependency("vulkan_zig", .{
        .registry = registry,
    }).module("vulkan-zig");

    const imgui = b.dependency("dear_imgui", .{
        .target = target,
        .optimize = optimize,
    });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_mod.addImport("c", translator.mod);
    root_mod.addImport("vulkan", vulkan);
    root_mod.linkLibrary(glfw.artifact("glfw"));
    root_mod.addImport("imgui", imgui.module("dear_imgui"));
    root_mod.addImport("imgui_vk", imgui.module("dear_imgui_vulkan"));

    const exe = b.addExecutable(.{
        .name = "zimgoo",
        .root_module = root_mod,
        .use_llvm = true,
        .use_lld = true,
    });
    b.installArtifact(exe);

    const vert_cmd = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.2",
        "-o",
    });
    const vert_spv = vert_cmd.addOutputFileArg("vert.spv");
    vert_cmd.addFileArg(b.path("src/shaders/triangle.vert"));
    exe.root_module.addAnonymousImport("vertex_shader", .{
        .root_source_file = vert_spv,
    });

    const frag_cmd = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.2",
        "-o",
    });
    const frag_spv = frag_cmd.addOutputFileArg("frag.spv");
    frag_cmd.addFileArg(b.path("src/shaders/triangle.frag"));
    exe.root_module.addAnonymousImport("fragment_shader", .{
        .root_source_file = frag_spv,
    });

    const run_artifact = b.addRunArtifact(exe);
    run_artifact.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the project");
    run_step.dependOn(&run_artifact.step);
}
