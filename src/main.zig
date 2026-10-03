const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Swapchain = @import("swapchain.zig").Swapchain;

const imgui = @import("imgui");
const ivk = @import("imgui_vk");

const app_name = "game";

const vertices = [_]Vertex{
    .{ .pos = .{ 0, -0.5 }, .color = .{ 1, 0, 0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0, 1, 0 } },
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 0, 0, 1 } },
};

pub fn main(init: std.process.Init) !void {
    if (c.glfwInit() != c.GLFW_TRUE) return error.GlfwInitFailed;
    defer c.glfwTerminate();

    if (c.glfwVulkanSupported() != c.GLFW_TRUE) {
        std.log.err("GLFW could not find libvulkan", .{});
        return error.NoVulkan;
    }

    var extent = vk.Extent2D{ .width = 800, .height = 600 };

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    const window = c.glfwCreateWindow(
        @intCast(extent.width),
        @intCast(extent.height),
        app_name,
        null,
        null,
    ) orelse return error.WindowInitFailed;
    defer c.glfwDestroyWindow(window);

    extent.width, extent.height = blk: {
        var w: c_int = undefined;
        var h: c_int = undefined;
        c.glfwGetFramebufferSize(window, &w, &h);
        break :blk .{ @intCast(w), @intCast(h) };
    };

    const gpa = init.gpa;

    const gc = try GraphicsContext.init(gpa, app_name, window);
    defer gc.deinit();

    std.log.debug("Using device: {s}", .{gc.deviceName()});

    var swapchain = try Swapchain.init(&gc, gpa, extent);
    defer swapchain.deinit();

    const pipeline_info: vk.PipelineLayoutCreateInfo = .{
        .flags = .{},
        .set_layout_count = 0,
        .p_set_layouts = undefined,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
    };
    const pipeline_layout = try gc.dev.createPipelineLayout(&pipeline_info, null);
    defer gc.dev.destroyPipelineLayout(pipeline_layout, null);

    const render_pass = try createRenderPass(&gc, swapchain);
    defer gc.dev.destroyRenderPass(render_pass, null);

    const pipeline = try createPipeline(&gc, pipeline_layout, render_pass);
    defer gc.dev.destroyPipeline(pipeline, null);

    var framebuffers = try createFrameBuffers(&gc, gpa, render_pass, swapchain);
    defer destroyFramebuffers(&gc, gpa, framebuffers);

    const cmd_pool_info: vk.CommandPoolCreateInfo = .{
        .queue_family_index = gc.graphics_queue.family,
    };
    const pool = try gc.dev.createCommandPool(&cmd_pool_info, null);
    defer gc.dev.destroyCommandPool(pool, null);

    const buf_info: vk.BufferCreateInfo = .{
        .size = @sizeOf(@TypeOf(vertices)),
        .usage = .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
    };
    const buffer = try gc.dev.createBuffer(&buf_info, null);
    defer gc.dev.destroyBuffer(buffer, null);

    const mem_reqs = gc.dev.getBufferMemoryRequirements(buffer);
    const memory = try gc.alloc(mem_reqs, .{ .device_local_bit = true });
    defer gc.dev.freeMemory(memory, null);
    try gc.dev.bindBufferMemory(buffer, memory, 0);

    try uploadVertices(&gc, pool, buffer);

    var cmdbufs = try createCommandBuffers(
        &gc,
        pool,
        gpa,
        buffer,
        swapchain.extent,
        render_pass,
        pipeline,
        framebuffers,
    );
    defer destroyCommandbuffers(&gc, pool, gpa, cmdbufs);

    var state: Swapchain.PresentState = .optimal;
    while (c.glfwWindowShouldClose(window) == c.GLFW_FALSE) {
        var w: c_int = undefined;
        var h: c_int = undefined;
        c.glfwGetFramebufferSize(window, &w, &h);

        if (w == 0 or h == 0) {
            c.glfwPollEvents();
            continue;
        }

        if (state == .suboptimal or extent.width != @as(u32, @intCast(w)) or extent.height != @as(u32, @intCast(h))) {
            extent.width = @intCast(w);
            extent.height = @intCast(h);

            try swapchain.recreate(extent);

            destroyFramebuffers(&gc, gpa, framebuffers);
            framebuffers = try createFrameBuffers(&gc, gpa, render_pass, swapchain);

            destroyCommandbuffers(&gc, pool, gpa, cmdbufs);
            cmdbufs = try createCommandBuffers(
                &gc,
                pool,
                gpa,
                buffer,
                swapchain.extent,
                render_pass,
                pipeline,
                framebuffers,
            );
        }

        const cmdbuf = cmdbufs[swapchain.image_index];
        state = swapchain.present(cmdbuf) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => |narrow| return narrow,
        };

        c.glfwPollEvents();
    }

    try swapchain.waitForAllFences();
    try gc.dev.deviceWaitIdle();
}

fn uploadVertices(gc: *const GraphicsContext, pool: vk.CommandPool, buffer: vk.Buffer) !void {
    const buf_info: vk.BufferCreateInfo = .{
        .size = @sizeOf(@TypeOf(vertices)),
        .usage = .{
            .transfer_dst_bit = true,
            .vertex_buffer_bit = true,
            .transfer_src_bit = true,
        },
        .sharing_mode = .exclusive,
    };
    const staging_buffer = try gc.dev.createBuffer(&buf_info, null);
    defer gc.dev.destroyBuffer(staging_buffer, null);

    const mem_reqs = gc.dev.getBufferMemoryRequirements(staging_buffer);
    const staging_mem = try gc.alloc(mem_reqs, .{
        .device_local_bit = true,
        .host_visible_bit = true,
    });
    defer gc.dev.freeMemory(staging_mem, null);
    try gc.dev.bindBufferMemory(staging_buffer, staging_mem, 0);

    {
        const data = try gc.dev.mapMemory(staging_mem, 0, vk.WHOLE_SIZE, .{});
        defer gc.dev.unmapMemory(staging_mem);

        const gpu_vertices: [*]Vertex = @ptrCast(@alignCast(data));
        @memcpy(gpu_vertices, vertices[0..]);
    }

    try copyBuffer(gc, pool, buffer, staging_buffer, @sizeOf(@TypeOf(vertices)));
}

fn copyBuffer(gc: *const GraphicsContext, pool: vk.CommandPool, dst: vk.Buffer, src: vk.Buffer, size: vk.DeviceSize) !void {
    var cmdbuf_handle: vk.CommandBuffer = undefined;
    const cmd_buf_info: vk.CommandBufferAllocateInfo = .{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    };
    try gc.dev.allocateCommandBuffers(&cmd_buf_info, @ptrCast(&cmdbuf_handle));
    defer gc.dev.freeCommandBuffers(pool, &.{cmdbuf_handle});

    const cmdbuf = GraphicsContext.CommandBuffer.init(cmdbuf_handle, gc.dev.wrapper);

    try cmdbuf.beginCommandBuffer(&.{
        .flags = .{ .one_time_submit_bit = true },
    });

    const region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = size,
    };
    cmdbuf.copyBuffer(src, dst, &.{region});

    try cmdbuf.endCommandBuffer();

    const si: vk.SubmitInfo = .{
        .command_buffer_count = 1,
        .p_command_buffers = &.{cmdbuf.handle},
        .p_wait_dst_stage_mask = undefined,
    };
    try gc.dev.queueSubmit(gc.graphics_queue.handle, &.{si}, .null_handle);
    try gc.dev.queueWaitIdle(gc.graphics_queue.handle);
}

fn createCommandBuffers(
    gc: *const GraphicsContext,
    pool: vk.CommandPool,
    gpa: Allocator,
    buffer: vk.Buffer,
    extent: vk.Extent2D,
    render_pass: vk.RenderPass,
    pipeline: vk.Pipeline,
    framebuffers: []vk.Framebuffer,
) ![]vk.CommandBuffer {
    const cmdbufs = try gpa.alloc(vk.CommandBuffer, framebuffers.len);
    errdefer gpa.free(cmdbufs);

    const cmd_buf_info: vk.CommandBufferAllocateInfo = .{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = @intCast(cmdbufs.len),
    };
    try gc.dev.allocateCommandBuffers(&cmd_buf_info, cmdbufs.ptr);
    errdefer gc.dev.freeCommandBuffers(pool, cmdbufs);

    const clear = vk.ClearValue{
        .color = .{ .float_32 = .{ 0, 0, 0, 1 } },
    };

    const viewport: vk.Viewport = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .min_depth = 0,
        .max_depth = 1,
    };

    const scissor: vk.Rect2D = .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    };

    for (cmdbufs, framebuffers) |cb, fb| {
        try gc.dev.beginCommandBuffer(cb, &.{});

        gc.dev.cmdSetViewport(cb, 0, &.{viewport});
        gc.dev.cmdSetScissor(cb, 0, &.{scissor});

        const render_area: vk.Rect2D = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = extent,
        };

        const begin_info: vk.RenderPassBeginInfo = .{
            .render_pass = render_pass,
            .framebuffer = fb,
            .render_area = render_area,
            .clear_value_count = 1,
            .p_clear_values = @ptrCast(&clear),
        };
        gc.dev.cmdBeginRenderPass(cb, &begin_info, .@"inline");

        gc.dev.cmdBindPipeline(cb, .graphics, pipeline);
        const offset = [_]vk.DeviceSize{0};
        gc.dev.cmdBindVertexBuffers(cb, 0, &.{buffer}, &offset);
        gc.dev.cmdDraw(cb, vertices.len, 1, 0, 0);

        gc.dev.cmdEndRenderPass(cb);
        try gc.dev.endCommandBuffer(cb);
    }
    return cmdbufs;
}

fn destroyCommandbuffers(gc: *const GraphicsContext, pool: vk.CommandPool, gpa: Allocator, cmdbufs: []vk.CommandBuffer) void {
    gc.dev.freeCommandBuffers(pool, cmdbufs);
    gpa.free(cmdbufs);
}

fn createRenderPass(gc: *const GraphicsContext, swapchain: Swapchain) !vk.RenderPass {
    const color_attachment = vk.AttachmentDescription{
        .format = swapchain.surface_format.format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };

    const color_attachment_ref = vk.AttachmentReference{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };

    const subpass = vk.SubpassDescription{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_attachment_ref),
    };

    const create_info: vk.RenderPassCreateInfo = .{
        .attachment_count = 1,
        .p_attachments = @ptrCast(&color_attachment),
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
    };
    return try gc.dev.createRenderPass(&create_info, null);
}

const vert_spv align(@alignOf(u32)) = @embedFile("vertex_shader").*;
const frag_spv align(@alignOf(u32)) = @embedFile("fragment_shader").*;

const Vertex = struct {
    const Self = @This();

    const binding_description = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(Self),
        .input_rate = .vertex,
    };

    const attribute_description = [_]vk.VertexInputAttributeDescription{
        .{
            .binding = 0,
            .location = 0,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Self, "pos"),
        },
        .{
            .binding = 0,
            .location = 1,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Self, "color"),
        },
    };

    pos: [2]f32,
    color: [3]f32,
};

fn createFrameBuffers(gc: *const GraphicsContext, gpa: Allocator, render_pass: vk.RenderPass, swapchain: Swapchain) ![]vk.Framebuffer {
    const framebuffers = try gpa.alloc(vk.Framebuffer, swapchain.swap_images.len);
    errdefer gpa.free(framebuffers);

    var i: usize = 0;
    errdefer for (framebuffers[0..i]) |fb| gc.dev.destroyFramebuffer(fb, null);

    for (framebuffers) |*fb| {
        const fb_info: vk.FramebufferCreateInfo = .{
            .render_pass = render_pass,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&swapchain.swap_images[i].view),
            .width = swapchain.extent.width,
            .height = swapchain.extent.height,
            .layers = 1,
        };
        fb.* = try gc.dev.createFramebuffer(&fb_info, null);
        i += 1;
    }

    return framebuffers;
}

fn destroyFramebuffers(gc: *const GraphicsContext, gpa: Allocator, framebuffers: []const vk.Framebuffer) void {
    for (framebuffers) |fb| gc.dev.destroyFramebuffer(fb, null);
    gpa.free(framebuffers);
}

fn createPipeline(
    gc: *const GraphicsContext,
    layout: vk.PipelineLayout,
    render_pass: vk.RenderPass,
) !vk.Pipeline {
    const vert_info: vk.ShaderModuleCreateInfo = .{
        .code_size = vert_spv.len,
        .p_code = @ptrCast(&vert_spv),
    };
    const vert = try gc.dev.createShaderModule(&vert_info, null);
    defer gc.dev.destroyShaderModule(vert, null);

    const frag_info: vk.ShaderModuleCreateInfo = .{
        .code_size = frag_spv.len,
        .p_code = @ptrCast(&frag_spv),
    };
    const frag = try gc.dev.createShaderModule(&frag_info, null);
    defer gc.dev.destroyShaderModule(frag, null);

    const pssci = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .stage = .{ .vertex_bit = true },
            .module = vert,
            .p_name = "main",
        },
        .{
            .stage = .{ .fragment_bit = true },
            .module = frag,
            .p_name = "main",
        },
    };

    const pvisci: vk.PipelineVertexInputStateCreateInfo = .{
        .vertex_binding_description_count = 1,
        .p_vertex_attribute_descriptions = @ptrCast(&Vertex.attribute_description),
        .vertex_attribute_description_count = Vertex.attribute_description.len,
        .p_vertex_binding_descriptions = @ptrCast(&Vertex.binding_description),
    };

    const piasci: vk.PipelineInputAssemblyStateCreateInfo = .{
        .topology = .triangle_list,
        .primitive_restart_enable = .false,
    };

    const pvsci = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .p_viewports = undefined,
        .scissor_count = 1,
        .p_scissors = undefined,
    };

    const prsci: vk.PipelineRasterizationStateCreateInfo = .{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .cull_mode = .{ .back_bit = true },
        .front_face = .clockwise,
        .depth_bias_enable = .false,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };

    const pmsci: vk.PipelineMultisampleStateCreateInfo = .{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = .false,
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };

    const pcbas: vk.PipelineColorBlendAttachmentState = .{
        .blend_enable = .false,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };

    const pcbsci: vk.PipelineColorBlendStateCreateInfo = .{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&pcbas),
        .blend_constants = [_]f32{ 0, 0, 0, 0 },
    };

    const dyn_state = [_]vk.DynamicState{ .viewport, .scissor };

    const pdsci: vk.PipelineDynamicStateCreateInfo = .{
        .flags = .{},
        .dynamic_state_count = dyn_state.len,
        .p_dynamic_states = &dyn_state,
    };

    const gpci: vk.GraphicsPipelineCreateInfo = .{
        .flags = .{},
        .stage_count = 2,
        .p_stages = &pssci,
        .p_vertex_input_state = &pvisci,
        .p_input_assembly_state = &piasci,
        .p_tessellation_state = null,
        .p_viewport_state = &pvsci,
        .p_rasterization_state = &prsci,
        .p_multisample_state = &pmsci,
        .p_depth_stencil_state = null,
        .p_color_blend_state = &pcbsci,
        .p_dynamic_state = &pdsci,
        .layout = layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var pipeline: vk.Pipeline = undefined;
    _ = try gc.dev.createGraphicsPipelines(
        .null_handle,
        &.{gpci},
        null,
        (&pipeline)[0..1],
    );
    return pipeline;
}
