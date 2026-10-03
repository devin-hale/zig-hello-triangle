const std = @import("std");
const c = @import("c");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;

const required_layer_names = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
const required_device_extensions = [_][*:0]const u8{vk.extensions.khr_swapchain.name};

const BaseWrapper = vk.BaseWrapper;
const Instancewrapper = vk.InstanceWrapper;
const DeviceWrapper = vk.DeviceWrapper;

const Instance = vk.InstanceProxy;
const Device = vk.DeviceProxy;

const preferred_sfmt = vk.SurfaceFormatKHR{
    .format = .b8g8r8a8_srgb,
    .color_space = .srgb_nonlinear_khr,
};
const preferred_present_modes = [_]vk.PresentModeKHR{
    .mailbox_khr,
    .immediate_khr,
};

fn getGlfwInstanceProcAddr(instance: ?vk.Instance, procname: [*:0]const u8) vk.PfnVoidFunction {
    const handle: c.VkInstance = if (instance) |i| @ptrFromInt(@intFromEnum(i)) else null;
    return @ptrCast(c.glfwGetInstanceProcAddress(handle, procname));
}

pub const GraphicsContext = struct {
    pub const Self = @This();
    pub const CommandBuffer = vk.CommandBufferProxy;

    gpa: Allocator,

    vkb: BaseWrapper,

    instance: Instance,
    debug_messenger: vk.DebugUtilsMessengerEXT,
    surface: vk.SurfaceKHR,
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    mem_props: vk.PhysicalDeviceMemoryProperties,

    dev: Device,
    graphics_queue: Queue,
    present_queue: Queue,

    pub fn init(gpa: Allocator, app_name: [*:0]const u8, window: *c.GLFWwindow) !Self {
        var self: Self = undefined;
        self.gpa = gpa;
        self.vkb = BaseWrapper.load(getGlfwInstanceProcAddr);

        if (try checkLayerSupport(&self.vkb, self.gpa) == false) {
            return error.MissingLayer;
        }

        var extension_names: std.ArrayList([*:0]const u8) = .empty;
        defer extension_names.deinit(gpa);

        try extension_names.append(gpa, vk.extensions.ext_debug_utils.name);
        try extension_names.append(gpa, vk.extensions.khr_portability_enumeration.name);
        try extension_names.append(gpa, vk.extensions.khr_get_physical_device_properties_2.name);

        var glfw_exts_count: u32 = 0;
        const glfw_exts = c.glfwGetRequiredInstanceExtensions(&glfw_exts_count);
        try extension_names.appendSlice(gpa, @ptrCast(glfw_exts[0..glfw_exts_count]));

        const app_info: vk.ApplicationInfo = .{
            .p_application_name = app_name,
            .application_version = vk.makeApiVersion(0, 0, 0, 0).toU32(),
            .p_engine_name = app_name,
            .engine_version = vk.makeApiVersion(0, 0, 0, 0).toU32(),
            .api_version = vk.API_VERSION_1_3.toU32(),
        };
        const create_info: vk.InstanceCreateInfo = .{
            .p_application_info = &app_info,
            .enabled_layer_count = required_layer_names.len,
            .pp_enabled_layer_names = @ptrCast(&required_layer_names),
            .enabled_extension_count = @intCast(extension_names.items.len),
            .pp_enabled_extension_names = extension_names.items.ptr,
            .flags = .{ .enumerate_portability_bit_khr = true },
        };
        const instance = try self.vkb.createInstance(&create_info, null);

        const vki = try gpa.create(Instancewrapper);
        errdefer gpa.destroy(vki);

        vki.* = Instancewrapper.load(instance, self.vkb.dispatch.vkGetInstanceProcAddr.?);
        self.instance = Instance.init(instance, vki);
        errdefer self.instance.destroyInstance(null);

        const debug_info: vk.DebugUtilsMessengerCreateInfoEXT = .{
            .message_severity = .{
                //.verbose_bit_ext = true,
                //.info_bit_ext = true,
                .warning_bit_ext = true,
                .error_bit_ext = true,
            },
            .message_type = .{
                .general_bit_ext = true,
                .validation_bit_ext = true,
                .performance_bit_ext = true,
            },
            .pfn_user_callback = &debugUtilsMessengerCallback,
            .p_user_data = null,
        };
        self.debug_messenger = try self.instance.createDebugUtilsMessengerEXT(&debug_info, null);

        self.surface = try createSurface(self.instance, window);
        errdefer self.instance.destroySurfaceKHR(self.surface, null);

        const candidate = try pickPhysicalDevice(self.instance, gpa, self.surface);
        self.pdev = candidate.pdev;
        self.props = candidate.props;

        const dev = try candidate.initialize(self.instance);

        const vkd = try gpa.create(DeviceWrapper);
        errdefer gpa.destroy(vkd);

        vkd.* = DeviceWrapper.load(dev, self.instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
        self.dev = Device.init(dev, vkd);
        errdefer self.dev.destroyDevice(null);

        self.graphics_queue = Queue.init(self.dev, candidate.queues.graphics_family);
        self.present_queue = Queue.init(self.dev, candidate.queues.present_family);

        self.mem_props = self.instance.getPhysicalDeviceMemoryProperties(self.pdev);

        return self;
    }

    pub fn deinit(self: Self) void {
        self.dev.destroyDevice(null);
        self.instance.destroySurfaceKHR(self.surface, null);
        self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
        self.instance.destroyInstance(null);

        self.gpa.destroy(self.dev.wrapper);
        self.gpa.destroy(self.instance.wrapper);
    }

    pub fn deviceName(self: *const Self) []const u8 {
        return std.mem.sliceTo(&self.props.device_name, 0);
    }

    pub fn findMemoryTypeIndex(self: Self, memory_types: u32, flags: vk.MemoryPropertyFlags) !u32 {
        for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |mem_type, i| {
            if (memory_types & (@as(u32, 1) << @truncate(i)) != 0 and mem_type.property_flags.contains(flags)) {
                return @truncate(i);
            }
        }
        return error.NoSuitableMemoryType;
    }

    pub fn alloc(self: Self, requirements: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags) !vk.DeviceMemory {
        const alloc_info: vk.MemoryAllocateInfo = .{
            .allocation_size = requirements.size,
            .memory_type_index = try self.findMemoryTypeIndex(requirements.memory_type_bits, flags),
        };
        return try self.dev.allocateMemory(&alloc_info, null);
    }

    pub fn findSurfaceFormat(self: *const Self) !vk.SurfaceFormatKHR {
        const surface_formats = try self.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(self.pdev, self.surface, self.gpa);
        defer self.gpa.free(surface_formats);

        for (surface_formats) |sfmt| {
            if (std.meta.eql(sfmt, preferred_sfmt)) {
                return preferred_sfmt;
            }
        }
        return surface_formats[0];
    }

    pub fn findPresentMode(self: *const Self) !vk.PresentModeKHR {
        const present_modes = try self.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(self.pdev, self.surface, self.gpa);
        defer self.gpa.free(present_modes);

        for (preferred_present_modes) |mode| {
            if (std.mem.findScalar(vk.PresentModeKHR, present_modes, mode) != null) {
                return mode;
            }
        }
        return .fifo_khr;
    }
};

pub const Queue = struct {
    handle: vk.Queue,
    family: u32,

    fn init(device: Device, family: u32) Queue {
        return .{
            .handle = device.getDeviceQueue(family, 0),
            .family = family,
        };
    }
};

const DeviceCandidate = struct {
    const Self = @This();

    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queues: QueueAllocation,

    pub fn initialize(self: Self, instance: Instance) !vk.Device {
        const priority = [_]f32{1};
        const qci = [_]vk.DeviceQueueCreateInfo{
            .{
                .queue_family_index = self.queues.graphics_family,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
            .{
                .queue_family_index = self.queues.present_family,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
        };

        const queue_count: u32 = if (self.queues.graphics_family == self.queues.present_family) 1 else 2;

        const create_info: vk.DeviceCreateInfo = .{
            .queue_create_info_count = queue_count,
            .p_queue_create_infos = &qci,
            .enabled_extension_count = required_device_extensions.len,
            .pp_enabled_extension_names = @ptrCast(&required_device_extensions),
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = null,
        };
        return try instance.createDevice(self.pdev, &create_info, null);
    }
};

const QueueAllocation = struct {
    graphics_family: u32,
    present_family: u32,
};

fn pickPhysicalDevice(
    instance: Instance,
    gpa: Allocator,
    surface: vk.SurfaceKHR,
) !DeviceCandidate {
    const pdevs = try instance.enumeratePhysicalDevicesAlloc(gpa);
    defer gpa.free(pdevs);

    for (pdevs) |pdev| {
        if (try checkSuitable(instance, pdev, gpa, surface)) |candidate| {
            return candidate;
        }
    }
    return error.NoSuitableDevice;
}

fn checkSuitable(
    instance: Instance,
    pdev: vk.PhysicalDevice,
    gpa: Allocator,
    surface: vk.SurfaceKHR,
) !?DeviceCandidate {
    if (!try checkExtensionSupport(instance, pdev, gpa)) {
        return null;
    }
    if (!try checkSurfaceSupport(instance, pdev, surface)) {
        return null;
    }

    if (try allocateQueues(instance, pdev, gpa, surface)) |allocation| {
        const props = instance.getPhysicalDeviceProperties(pdev);
        return DeviceCandidate{
            .pdev = pdev,
            .props = props,
            .queues = allocation,
        };
    }
    return null;
}

fn allocateQueues(instance: Instance, pdev: vk.PhysicalDevice, gpa: Allocator, surface: vk.SurfaceKHR) !?QueueAllocation {
    const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, gpa);
    defer gpa.free(families);

    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;

    for (families, 0..) |properties, i| {
        const family: u32 = @intCast(i);

        if (graphics_family == null and properties.queue_flags.graphics_bit) {
            graphics_family = family;
        }
        if (present_family == null and (try instance.getPhysicalDeviceSurfaceSupportKHR(pdev, family, surface)) == .true) {
            present_family = family;
        }
    }

    if (graphics_family != null and present_family != null) {
        return QueueAllocation{
            .graphics_family = graphics_family.?,
            .present_family = present_family.?,
        };
    }

    return null;
}

fn checkSurfaceSupport(instance: Instance, pdev: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    var format_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &format_count, null);

    var present_mode_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfacePresentModesKHR(pdev, surface, &present_mode_count, null);

    return format_count > 0 and present_mode_count > 0;
}

fn checkExtensionSupport(
    instance: Instance,
    pdev: vk.PhysicalDevice,
    gpa: Allocator,
) !bool {
    const propsv = try instance.enumerateDeviceExtensionPropertiesAlloc(pdev, null, gpa);
    defer gpa.free(propsv);

    for (required_device_extensions) |ext| {
        for (propsv) |props| {
            if (std.mem.eql(u8, std.mem.span(ext), std.mem.sliceTo(&props.extension_name, 0))) {
                break;
            }
        } else {
            return false;
        }
    }
    return true;
}

fn checkLayerSupport(vkb: *const BaseWrapper, gpa: Allocator) !bool {
    const available_layers = try vkb.enumerateInstanceLayerPropertiesAlloc(gpa);
    defer gpa.free(available_layers);

    for (required_layer_names) |required_layer| {
        for (available_layers) |layer| {
            if (std.mem.eql(u8, std.mem.span(required_layer), std.mem.sliceTo(&layer.layer_name, 0))) {
                break;
            }
        } else {
            return false;
        }
    }
    return true;
}

fn createSurface(instance: Instance, window: *c.GLFWwindow) !vk.SurfaceKHR {
    var surface: vk.SurfaceKHR = undefined;
    const result: vk.Result = @enumFromInt(@as(c_int, @intCast(c.glfwCreateWindowSurface(
        @ptrFromInt(@intFromEnum(instance.handle)),
        window,
        null,
        @ptrCast(&surface),
    ))));
    if (result != .success) {
        return error.SurfaceInitFailed;
    }
    return surface;
}

fn debugUtilsMessengerCallback(severity: vk.DebugUtilsMessageSeverityFlagsEXT, msg_type: vk.DebugUtilsMessageTypeFlagsEXT, callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT, _: ?*anyopaque) callconv(.c) vk.Bool32 {
    const severity_str = if (severity.verbose_bit_ext) "verbose" else if (severity.info_bit_ext) "info" else if (severity.warning_bit_ext) "waring" else if (severity.error_bit_ext) "error" else "unknown";
    const type_str = if (msg_type.general_bit_ext) "general" else if (msg_type.validation_bit_ext) "validation" else if (msg_type.performance_bit_ext) "performance" else if (msg_type.device_address_binding_bit_ext) "device addr" else "unknown";

    const message: [*c]const u8 = if (callback_data) |cb_data| cb_data.p_message else "NO MESSAGE!";
    std.debug.print("[{s}][{s}]. Message:\n  {s}\n", .{ severity_str, type_str, message });

    return .false;
}
