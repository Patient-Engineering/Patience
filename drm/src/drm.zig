const std = @import("std");

pub const DrmCrtc = struct {
    fb_id: u32 = 0,
    crtc_id: u32 = 0,
    connectors: []u32 = undefined,
    mode: ?drm_mode_modeinfo = undefined,
    x: u32 = 0,
    y: u32 = 0,
    gamma_size: u32 = 0,
};

pub const DrmConnector = struct {
    id: u32,
    connected: bool,
    encoder_id: u32,
    encoders: []u32,
    modes: []drm_mode_modeinfo,
    props: []u32,
    prop_values: []u64,
    alloc: *std.mem.Allocator,

    pub fn deinit(self: @This()) void {
        self.alloc.free(self.encoders);
        self.alloc.free(self.modes);
        self.alloc.free(self.props);
        self.alloc.free(self.prop_values);
    }
};

pub const DrmVersion = struct {
    major: i32,
    minor: i32,
    patchlevel: i32,
    name: []u8,
    date: []u8,
    desc: []u8,
    alloc: *std.mem.Allocator,

    pub fn format(
        self: @This(),
        fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.writeAll(@typeName(@This()) ++ "{\n");
        try writer.print("  version = {}.{}.{}\n", .{
            self.major,
            self.minor,
            self.patchlevel,
        });
        try writer.print("  name = \"{s}\"\n", .{self.name});
        try writer.print("  desc = \"{s}\"\n", .{self.desc});
        try writer.print("  date = \"{s}\"\n", .{self.date});
        try writer.writeAll("}");
    }

    pub fn deinit(self: @This()) void {
        self.alloc.free(self.name);
        self.alloc.free(self.date);
        self.alloc.free(self.desc);
    }
};

pub const DrmResources = struct {
    min_width: u32,
    max_width: u32,
    min_height: u32,
    max_height: u32,

    fb_ids: []u32,
    crtc_ids: []u32,
    connector_ids: []u32,
    encoder_ids: []u32,

    alloc: *std.mem.Allocator,

    pub fn format(
        self: @This(),
        fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.writeAll(@typeName(@This()) ++ "{\n");
        try writer.print("  min_width = {}\n", .{self.min_width});
        try writer.print("  max_width = {}\n", .{self.max_width});
        try writer.print("  min_height = {}\n", .{self.min_height});
        try writer.print("  max_height = {}\n", .{self.max_height});
        try writer.print("  fb_ids = {d}\n", .{self.fb_ids});
        try writer.print("  crtc_ids = {d}\n", .{self.crtc_ids});
        try writer.print("  connector_ids = {d}\n", .{self.connector_ids});
        try writer.print("  encoder_ids = {d}\n", .{self.encoder_ids});
        try writer.writeAll("}");
    }

    pub fn deinit(self: @This()) void {
        self.alloc.free(self.fb_ids);
        self.alloc.free(self.crtc_ids);
        self.alloc.free(self.connector_ids);
        self.alloc.free(self.encoder_ids);
    }
};

pub const DrmDevice = struct {
    fd: std.os.fd_t,
    alloc: *std.mem.Allocator,
    is_master: bool,

    const Self = @This();

    pub fn open(alloc: *std.mem.Allocator, path: []const u8) !DrmDevice {
        const fd = try std.os.open("/dev/dri/card0", std.os.O_RDWR, 0);
        return DrmDevice{
            .fd = fd,
            .alloc = alloc,
            .is_master = false,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.is_master) {
            self.drop_master() catch {};
        }
        std.os.close(self.fd);
    }

    pub fn get_version(self: Self) !DrmVersion {
        var version: drm_version = .{};
        try ioctl(self.fd, DRM_IOCTL_VERSION, @ptrToInt(&version));

        var name_buffer = try self.alloc.alloc(u8, version.name_len);
        version.name = @ptrToInt(name_buffer.ptr);
        errdefer self.alloc.free(name_buffer);

        var desc_buffer = try self.alloc.alloc(u8, version.desc_len);
        version.desc = @ptrToInt(desc_buffer.ptr);
        errdefer self.alloc.free(desc_buffer);

        var date_buffer = try self.alloc.alloc(u8, version.date_len);
        version.date = @ptrToInt(date_buffer.ptr);
        errdefer self.alloc.free(date_buffer);

        try ioctl(self.fd, DRM_IOCTL_VERSION, @ptrToInt(&version));

        return DrmVersion{
            .alloc = self.alloc,
            .major = version.version_major,
            .minor = version.version_minor,
            .patchlevel = version.version_patchlevel,
            .name = name_buffer,
            .desc = desc_buffer,
            .date = date_buffer,
        };
    }

    pub fn get_resources(self: Self) !DrmResources {
        const alloc = self.alloc;
        var res: drm_mode_card_res = .{};
        try ioctl(self.fd, DRM_IOCTL_MODE_GETRESOURCES, @ptrToInt(&res));

        var fb_buffer = try alloc.alloc(u32, res.count_fbs);
        errdefer alloc.free(fb_buffer);
        res.fb_id_ptr = @ptrToInt(fb_buffer.ptr);

        var crtc_buffer = try alloc.alloc(u32, res.count_crtcs);
        errdefer alloc.free(crtc_buffer);
        res.crtc_id_ptr = @ptrToInt(crtc_buffer.ptr);

        var connector_buffer = try alloc.alloc(u32, res.count_connectors);
        errdefer alloc.free(connector_buffer);
        res.connector_id_ptr = @ptrToInt(connector_buffer.ptr);

        var encoder_buffer = try alloc.alloc(u32, res.count_encoders);
        errdefer alloc.free(encoder_buffer);
        res.encoder_id_ptr = @ptrToInt(encoder_buffer.ptr);

        try ioctl(self.fd, DRM_IOCTL_MODE_GETRESOURCES, @ptrToInt(&res));

        return DrmResources{
            .alloc = alloc,
            .max_width = res.max_width,
            .min_width = res.min_width,
            .max_height = res.max_height,
            .min_height = res.min_height,
            .fb_ids = fb_buffer,
            .crtc_ids = crtc_buffer,
            .connector_ids = connector_buffer,
            .encoder_ids = encoder_buffer,
        };
    }

    pub fn get_connector(self: @This(), id: u32) !DrmConnector {
        var res: drm_mode_get_connector = .{
            .connector_id = id,
        };
        try ioctl(self.fd, DRM_IOCTL_MODE_GETCONNECTOR, @ptrToInt(&res));

        var encoder_buffer = try self.alloc.alloc(u32, res.count_encoders);
        errdefer self.alloc.free(encoder_buffer);
        res.encoders_ptr = @ptrToInt(encoder_buffer.ptr);

        var mode_buffer = try self.alloc.alloc(drm_mode_modeinfo, res.count_modes);
        errdefer self.alloc.free(mode_buffer);
        res.modes_ptr = @ptrToInt(mode_buffer.ptr);

        var prop_buffer = try self.alloc.alloc(u32, res.count_props);
        errdefer self.alloc.free(prop_buffer);
        res.props_ptr = @ptrToInt(prop_buffer.ptr);

        var prop_value_buffer = try self.alloc.alloc(u64, res.count_props);
        errdefer self.alloc.free(prop_value_buffer);
        res.prop_values_ptr = @ptrToInt(prop_value_buffer.ptr);

        try ioctl(self.fd, DRM_IOCTL_MODE_GETCONNECTOR, @ptrToInt(&res));
        return DrmConnector{
            .alloc = self.alloc,
            .connected = res.connection == DRM_MODE_CONNECTED,
            .id = id,
            .encoders = encoder_buffer,
            .modes = mode_buffer,
            .props = prop_buffer,
            .prop_values = prop_value_buffer,
            .encoder_id = res.encoder_id,
        };
    }

    pub fn set_crtc(self: *Self, crtc: *const DrmCrtc) !void {
        const scrtc: drm_mode_crtc = .{
            .set_connectors_ptr = @ptrToInt(crtc.connectors.ptr),
            .count_connectors = @truncate(u32, crtc.connectors.len),
            .crtc_id = crtc.crtc_id,
            .fb_id = crtc.fb_id,
            .mode_valid = if (crtc.mode != null) 1 else 0,
            .mode = if (crtc.mode != null) crtc.mode.? else undefined,
        };
        try ioctl(self.fd, DRM_IOCTL_MODE_SETCRTC, @ptrToInt(&scrtc));
    }

    pub fn get_crtc(self: *Self, id: u32) !DrmCrtc {
        const scrtc: drm_mode_crtc = .{
            .crtc_id = id,
        };
        try ioctl(self.fd, DRM_IOCTL_MODE_GETCRTC, @ptrToInt(&scrtc));
        return DrmCrtc{
            .fb_id = scrtc.fb_id,
            .crtc_id = scrtc.crtc_id,
            .connectors = &[0]u32{},
            .mode = if (scrtc.mode_valid == 1) scrtc.mode else null,
            .x = scrtc.x,
            .y = scrtc.y,
            .gamma_size = scrtc.gamma_size,
        };
    }

    pub fn set_master(self: *Self) !void {
        try ioctl(self.fd, DRM_IOCTL_SET_MASTER, 0);
        self.is_master = true;
    }

    pub fn drop_master(self: *Self) !void {
        try ioctl(self.fd, DRM_IOCTL_DROP_MASTER, 0);
        self.is_master = false;
    }
};

pub const drm_mode_crtc = extern struct {
    set_connectors_ptr: u64 = 0,
    count_connectors: u32 = 0,
    crtc_id: u32 = 0,
    fb_id: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    gamma_size: u32 = 0,
    mode_valid: u32 = 0,
    mode: drm_mode_modeinfo = .{},
};

pub const drm_mode_get_encoder = extern struct {
    encoder_id: u32 = 0,
    encoder_type: u32 = 0,
    crtc_id: u32 = 0,
    possible_crtcs: u32 = 0,
    possible_clones: u32 = 0,
};

pub const drm_mode_map_dumb = extern struct {
    handle: u32 = 0,
    pad: u32 = 0,
    offset: u64 = 0,
};

pub const drm_mode_fb_cmd = extern struct {
    fb_id: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    pitch: u32 = 0,
    bpp: u32 = 0,
    depth: u32 = 0,
    handle: u32 = 0,
};

pub const drm_mode_modeinfo = extern struct {
    clock: u32 = 0,
    hdisplay: u16 = 0,
    hsync_start: u16 = 0,
    hsync_end: u16 = 0,
    htotal: u16 = 0,
    hskew: u16 = 0,
    vdisplay: u16 = 0,
    vsync_start: u16 = 0,
    vsync_end: u16 = 0,
    vtotal: u16 = 0,
    vscan: u16 = 0,

    vrefresh: u32 = 0,

    flags: u32 = 0,
    typ: u32 = 0,
    name: [DRM_DISPLAY_MODE_LEN]u8 = undefined,
};

pub const drm_mode_create_dumb = extern struct {
    height: u32 = 0,
    width: u32 = 0,
    bpp: u32 = 0,
    flags: u32 = 0,
    handle: u32 = 0,
    pitch: u32 = 0,
    size: u64 = 0,
};

pub const drm_version = extern struct {
    version_major: i32 = 0,
    version_minor: i32 = 0,
    version_patchlevel: i32 = 0,
    name_len: usize = 0,
    name: u64 = 0,
    date_len: usize = 0,
    date: u64 = 0,
    desc_len: usize = 0,
    desc: u64 = 0,
};

pub const drm_mode_card_res = extern struct {
    fb_id_ptr: u64 = 0,
    crtc_id_ptr: u64 = 0,
    connector_id_ptr: u64 = 0,
    encoder_id_ptr: u64 = 0,
    count_fbs: u32 = 0,
    count_crtcs: u32 = 0,
    count_connectors: u32 = 0,
    count_encoders: u32 = 0,
    min_width: u32 = 0,
    max_width: u32 = 0,
    min_height: u32 = 0,
    max_height: u32 = 0,

    pub fn get_connector_ids(self: @This()) []u32 {
        return @intToPtr([*]u32, self.connector_id_ptr)[0..self.count_connectors];
    }

    pub fn get_crtc_ids(self: @This()) []u32 {
        return @intToPtr([*]u32, self.crtc_id_ptr)[0..self.count_crtcs];
    }

    pub fn get_fb_ids(self: @This()) []u32 {
        return @intToPtr([*]u32, self.fb_id_ptr)[0..self.count_fbs];
    }

    pub fn get_encoder_ids(self: @This()) []u32 {
        return @intToPtr([*]u32, self.encoder_id_ptr)[0..self.count_encoders];
    }

    pub fn deinit(self: *@This(), alloc: *std.mem.Allocator) void {
        if (self.fb_id_ptr != 0) {
            alloc.free(self.get_fb_ids());
        }
        if (self.crtc_id_ptr != 0) {
            alloc.free(self.get_crtc_ids());
        }
        if (self.connector_id_ptr != 0) {
            alloc.free(self.get_connector_ids());
        }
        if (self.encoder_id_ptr != 0) {
            alloc.free(self.get_encoder_ids());
        }
    }
};

pub const drm_mode_get_connector = extern struct {
    encoders_ptr: u64 = 0,
    modes_ptr: u64 = 0,
    props_ptr: u64 = 0,
    prop_values_ptr: u64 = 0,

    count_modes: u32 = 0,
    count_props: u32 = 0,
    count_encoders: u32 = 0,

    encoder_id: u32 = 0,
    connector_id: u32 = 0,
    connector_type: u32 = 0,
    connector_type_id: u32 = 0,

    connection: u32 = 0,
    mm_width: u32 = 0,
    mm_height: u32 = 0,
    subpixel: u32 = 0,
    pad: u32 = 0,

    pub fn get_encoders(self: @This()) []u32 {
        return @intToPtr([*]u32, self.encoders_ptr)[0..self.count_encoders];
    }

    pub fn get_modes(self: @This()) []drm_mode_modeinfo {
        return @intToPtr([*]drm_mode_modeinfo, self.modes_ptr)[0..self.count_modes];
    }

    pub fn get_props(self: @This()) []u32 {
        return @intToPtr([*]u32, self.props_ptr)[0..self.count_props];
    }

    pub fn get_prop_values(self: @This()) []u64 {
        return @intToPtr([*]u64, self.prop_values_ptr)[0..self.count_props];
    }

    pub fn deinit(self: *@This(), alloc: *std.mem.Allocator) void {
        if (self.encoders_ptr != 0) {
            alloc.free(self.get_encoders());
        }
        if (self.modes_ptr != 0) {
            alloc.free(self.get_modes());
        }
        if (self.props_ptr != 0) {
            alloc.free(self.get_props());
        }
        if (self.prop_values_ptr != 0) {
            alloc.free(self.get_prop_values());
        }
    }
};

pub const DRM_IOCTL_BASE = 'd';

pub const DRM_IOCTL_VERSION = DRM_IOWR(0x00, drm_version);
pub const DRM_IOCTL_MODE_GETRESOURCES = DRM_IOWR(0xA0, drm_mode_card_res);
pub const DRM_IOCTL_MODE_GETCRTC = DRM_IOWR(0xA1, drm_mode_crtc);
pub const DRM_IOCTL_MODE_SETCRTC = DRM_IOWR(0xA2, drm_mode_crtc);
pub const DRM_IOCTL_MODE_GETCONNECTOR = DRM_IOWR(0xA7, drm_mode_get_connector);
pub const DRM_IOCTL_MODE_GETENCODER = DRM_IOWR(0xA6, drm_mode_get_encoder);
pub const DRM_IOCTL_MODE_CREATE_DUMB = DRM_IOWR(0xB2, drm_mode_create_dumb);
pub const DRM_IOCTL_MODE_ADDFB = DRM_IOWR(0xAE, drm_mode_fb_cmd);
pub const DRM_IOCTL_MODE_MAP_DUMB = DRM_IOWR(0xB3, drm_mode_map_dumb);

pub const DRM_IOCTL_SET_MASTER = DRM_IO(0x1e);
pub const DRM_IOCTL_DROP_MASTER = DRM_IO(0x1f);

// #define DRM_IOWR(nr,type)		_IOWR(DRM_IOCTL_BASE,nr,type)
usingnamespace @import("ioctl.zig");
pub fn DRM_IOWR(nr: usize, comptime typ: type) usize {
    return _IOWR(DRM_IOCTL_BASE, nr, @sizeOf(typ));
}
pub fn DRM_IO(nr: usize) usize {
    return _IO(DRM_IOCTL_BASE, nr);
}

pub const DRM_MODE_CONNECTED = 1;
pub const DRM_MODE_DISCONNECTED = 2;
pub const DRM_MODE_UNKNOWNCONNECTION = 3;

pub const DRM_DISPLAY_MODE_LEN = 32;
