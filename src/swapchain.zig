const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;

pub const Swapchain = struct {
    const Self = @This();

    pub const PresentState = enum {
        optimal,
        suboptimal,
    };

    gc: *const GraphicsContext,
    gpa: Allocator,

    surface_format: vk.SurfaceFormatKHR,
    present_mode: vk.PresentModeKHR,
    extent: vk.Extent2D,
    handle: vk.SwapchainKHR,

    swap_images: []SwapImage,
    image_index: u32,
    next_image_acquired: vk.Semaphore,

    pub fn init(gc: *const GraphicsContext, gpa: Allocator, extent: vk.Extent2D) !Swapchain {
        return try initRecycle(gc, gpa, extent, .null_handle);
    }

    pub fn initRecycle(gc: *const GraphicsContext, gpa: Allocator, extent: vk.Extent2D, old_handle: vk.SwapchainKHR) !Self {
        const caps = try gc.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(gc.pdev, gc.surface);
        const actual_extent = findActualExtent(caps, extent);
        if (actual_extent.width == 0 or actual_extent.height == 0) {
            return error.InvalidSurfaceDimensions;
        }

        const surface_format = try gc.findSurfaceFormat();
        const present_mode = try gc.findPresentMode();

        var image_count = caps.min_image_count + 1;
        if (caps.max_image_count > 0) {
            image_count = @min(image_count, caps.max_image_count);
        }

        const qfi = [_]u32{ gc.graphics_queue.family, gc.present_queue.family };

        const sharing_mode: vk.SharingMode = if (gc.graphics_queue.family != gc.present_queue.family) .concurrent else .exclusive;

        const create_info: vk.SwapchainCreateInfoKHR = .{
            .surface = gc.surface,
            .min_image_count = image_count,
            .image_format = surface_format.format,
            .image_color_space = surface_format.color_space,
            .image_extent = actual_extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
            .image_sharing_mode = sharing_mode,
            .queue_family_index_count = qfi.len,
            .p_queue_family_indices = &qfi,
            .pre_transform = caps.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = present_mode,
            .clipped = .true,
            .old_swapchain = old_handle,
        };
        const handle = gc.dev.createSwapchainKHR(&create_info, null) catch {
            return error.SwapchainCreationFailed;
        };
        errdefer gc.dev.destroySwapchainKHR(handle, null);

        if (old_handle != .null_handle) {
            gc.dev.destroySwapchainKHR(old_handle, null);
        }

        const swap_images = try initSwapChainImages(gc, handle, surface_format.format, gpa);
        errdefer {
            for (swap_images) |si| si.deinit(gc);
            gpa.free(swap_images);
        }

        var next_image_acquired = try gc.dev.createSemaphore(&.{}, null);
        errdefer gc.dev.destroySemaphore(next_image_acquired, null);

        const result = try gc.dev.acquireNextImageKHR(handle, std.math.maxInt(u64), next_image_acquired, .null_handle);
        if (result.result == .not_ready or result.result == .timeout) {
            return error.ImageAcquireFailed;
        }

        std.mem.swap(vk.Semaphore, &swap_images[result.image_index].image_acquired, &next_image_acquired);

        return Swapchain{
            .gc = gc,
            .gpa = gpa,
            .surface_format = surface_format,
            .present_mode = present_mode,
            .extent = extent,
            .handle = handle,
            .swap_images = swap_images,
            .image_index = result.image_index,
            .next_image_acquired = next_image_acquired,
        };
    }

    fn deinitExceptSwapchain(self: Self) void {
        for (self.swap_images) |si| si.deinit(self.gc);
        self.gpa.free(self.swap_images);
        self.gc.dev.destroySemaphore(self.next_image_acquired, null);
    }

    pub fn waitForAllFences(self: Self) !void {
        for (self.swap_images) |si| try si.waitForFence(self.gc);
    }

    pub fn deinit(self: Swapchain) void {
        if (self.handle == .null_handle) return;
        self.deinitExceptSwapchain();
        self.gc.dev.destroySwapchainKHR(self.handle, null);
    }

    pub fn recreate(self: *Self, new_extent: vk.Extent2D) !void {
        const gc = self.gc;
        const gpa = self.gpa;
        const old_handle = self.handle;

        try self.gc.dev.queueWaitIdle(self.gc.present_queue.handle);
        self.deinitExceptSwapchain();

        self.handle = .null_handle;
        self.* = initRecycle(gc, gpa, new_extent, old_handle) catch |err| switch (err) {
            error.SwapchainCreationFailed => {
                gc.dev.destroySwapchainKHR(old_handle, null);
                return err;
            },
            else => return err,
        };
    }

    pub fn currentImage(self: Self) vk.Image {
        return self.swap_images[self.image_index].image;
    }

    pub fn currentSwapImage(self: Self) *const SwapImage {
        return &self.swap_images[self.image_index];
    }

    pub fn present(self: *Self, cmdbuf: vk.CommandBuffer) !PresentState {
        const current = self.currentSwapImage();
        try current.waitForFence(self.gc);
        try self.gc.dev.resetFences(&.{current.frame_fence});

        const wait_stage = [_]vk.PipelineStageFlags{.{ .top_of_pipe_bit = true }};
        const submit_info: vk.SubmitInfo = .{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&current.image_acquired),
            .p_wait_dst_stage_mask = &wait_stage,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&cmdbuf),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&current.render_finished),
        };
        try self.gc.dev.queueSubmit(
            self.gc.graphics_queue.handle,
            &.{submit_info},
            current.frame_fence,
        );

        const present_info: vk.PresentInfoKHR = .{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&current.render_finished),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.handle),
            .p_image_indices = @ptrCast(&self.image_index),
        };
        const present_infos = [_]vk.PresentInfoKHR{present_info};
        _ = try self.gc.dev.queuePresentKHR(
            self.gc.present_queue.handle,
            @ptrCast(&present_infos),
        );

        const result = try self.gc.dev.acquireNextImageKHR(
            self.handle,
            std.math.maxInt(u64),
            self.next_image_acquired,
            .null_handle,
        );

        std.mem.swap(vk.Semaphore, &self.swap_images[result.image_index].image_acquired, &self.next_image_acquired);
        self.image_index = result.image_index;

        return switch (result.result) {
            .success => .optimal,
            .suboptimal_khr => .suboptimal,
            else => unreachable,
        };
    }
};

const SwapImage = struct {
    const Self = @This();

    image: vk.Image,
    view: vk.ImageView,
    image_acquired: vk.Semaphore,
    render_finished: vk.Semaphore,
    frame_fence: vk.Fence,

    fn init(gc: *const GraphicsContext, image: vk.Image, format: vk.Format) !Self {
        const create_info: vk.ImageViewCreateInfo = .{
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        const view = try gc.dev.createImageView(&create_info, null);
        errdefer gc.dev.destroyImageView(view, null);

        const image_acquired = try gc.dev.createSemaphore(&.{}, null);
        errdefer gc.dev.destroySemaphore(image_acquired, null);

        const render_finished = try gc.dev.createSemaphore(&.{}, null);
        errdefer gc.dev.destroySemaphore(render_finished, null);

        const frame_fence = try gc.dev.createFence(&.{
            .flags = .{ .signaled_bit = true },
        }, null);
        errdefer gc.dev.destroyFence(frame_fence, null);

        return .{
            .image = image,
            .view = view,
            .image_acquired = image_acquired,
            .render_finished = render_finished,
            .frame_fence = frame_fence,
        };
    }

    fn deinit(self: Self, gc: *const GraphicsContext) void {
        self.waitForFence(gc) catch return;
        gc.dev.destroyImageView(self.view, null);
        gc.dev.destroySemaphore(self.image_acquired, null);
        gc.dev.destroySemaphore(self.render_finished, null);
        gc.dev.destroyFence(self.frame_fence, null);
    }

    fn waitForFence(self: Self, gc: *const GraphicsContext) !void {
        const fences = [_]vk.Fence{self.frame_fence};
        _ = try gc.dev.waitForFences(&fences, .true, std.math.maxInt(u64));
    }
};

fn initSwapChainImages(gc: *const GraphicsContext, swapchain: vk.SwapchainKHR, format: vk.Format, gpa: Allocator) ![]SwapImage {
    const images = try gc.dev.getSwapchainImagesAllocKHR(swapchain, gpa);
    defer gpa.free(images);

    const swap_images = try gpa.alloc(SwapImage, images.len);
    errdefer gpa.free(swap_images);

    var i: usize = 0;
    errdefer for (swap_images[0..i]) |si| si.deinit(gc);

    for (images) |image| {
        swap_images[i] = try SwapImage.init(gc, image, format);
        i += 1;
    }

    return swap_images;
}

fn findActualExtent(caps: vk.SurfaceCapabilitiesKHR, extent: vk.Extent2D) vk.Extent2D {
    if (caps.current_extent.width != 0xFFFF_FFFF) {
        return caps.current_extent;
    } else {
        return .{
            .width = std.math.clamp(extent.width, caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(extent.height, caps.min_image_extent.height, caps.max_image_extent.height),
        };
    }
}
