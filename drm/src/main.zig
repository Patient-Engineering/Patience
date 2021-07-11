const std = @import("std");
const linux = std.os.linux;

usingnamespace @import("drm.zig");
usingnamespace @import("ioctl.zig");

const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn init(r: u8, g: u8, b: u8) Color {
        return Color{ .r = r, .g = g, .b = b };
    }

    pub fn as_u32(self: @This()) u32 {
        return @as(u32, self.r) << 16 | @as(u32, self.g) << 8 | @as(u32, self.b);
    }
};

fn get_encoder(fd: std.os.fd_t, id: u32) !*drm_mode_get_encoder {
    const alloc = &gpa.allocator;
    var res = try alloc.create(drm_mode_get_encoder);
    res.* = .{
        .encoder_id = id,
    };
    try ioctl(fd, DRM_IOCTL_MODE_GETENCODER, @ptrToInt(res));
    return res;
}

var frame_buffer: []u8 = undefined;
var pitch_: u32 = undefined;

fn set_pixel(x: u32, y: u32, color: Color) void {
    const offset = y * pitch_ + x * 4;
    std.mem.copy(u8, frame_buffer[offset .. offset + 4], std.mem.asBytes(&color.as_u32())[0..4]);
}

fn draw_rect(rect: Rect, color: Color) void {
    var i = rect.y;
    while (i < rect.y + rect.height) : (i += 1) {
        var j = rect.x;
        while (j < rect.x + rect.width) : (j += 1) {
            set_pixel(j, i, color);
        }
    }
}

fn create_framebuffer(fd: std.os.fd_t, width: u32, height: u32) !u32 {
    var creq: drm_mode_create_dumb = .{
        .width = width,
        .height = height,
        .bpp = 32,
    };
    try ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, @ptrToInt(&creq));

    pitch_ = creq.pitch;

    var fb_cmd: drm_mode_fb_cmd = .{
        .width = width,
        .height = height,
        .bpp = 32,
        .depth = 24,
        .pitch = creq.pitch,
        .handle = creq.handle,
    };
    try ioctl(fd, DRM_IOCTL_MODE_ADDFB, @ptrToInt(&fb_cmd));

    var mcmd: drm_mode_map_dumb = .{
        .handle = creq.handle,
    };
    try ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, @ptrToInt(&mcmd));

    const ptr = try std.os.mmap(
        null,
        creq.size,
        std.os.PROT_READ | std.os.PROT_WRITE,
        std.os.MAP_SHARED,
        fd,
        mcmd.offset,
    );
    std.mem.set(u8, ptr, 0x00);
    frame_buffer = ptr;

    return fb_cmd.fb_id;
}

fn find_crtc(fd: std.os.fd_t, conn: *const DrmConnector) !u32 {
    const alloc = &gpa.allocator;
    const encoder = try get_encoder(fd, conn.encoder_id);
    defer alloc.destroy(encoder);
    std.debug.print("{}\n", .{encoder});
    return encoder.crtc_id;
}

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

fn show_version(drm_device: DrmDevice) !void {
    const version = try drm_device.get_version();
    defer version.deinit();
    std.debug.print("{}\n", .{version});
}

const Image = struct {
    width: u32,
    height: u32,
    data: []u8,
};

pub fn read_ppm(path: []const u8) !Image {
    const alloc: *std.mem.Allocator = &gpa.allocator;
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var reader = file.reader();
    const magic = try reader.readUntilDelimiterAlloc(alloc, '\n', 0x10);
    defer alloc.free(magic);
    std.debug.assert(std.mem.eql(u8, magic, "P6"));

    const dims = try reader.readUntilDelimiterAlloc(alloc, '\n', 0x20);
    defer alloc.free(dims);
    var it = std.mem.split(dims, " ");
    const width_s = it.next().?;
    const height_s = it.next().?;
    const width = try std.fmt.parseInt(u32, width_s, 10);
    const height = try std.fmt.parseInt(u32, height_s, 10);
    var buffer = try alloc.alloc(u8, width * height * 3);
    _ = try reader.readAll(buffer);
    return Image{
        .width = width,
        .height = height,
        .data = buffer,
    };
}

pub fn main() !void {
    defer _ = gpa.deinit();
    const alloc: *std.mem.Allocator = &gpa.allocator;

    var args = std.process.args();
    _ = args.skip();
    const fname = try args.next(alloc).?;
    defer alloc.free(fname);

    const image = try read_ppm(fname);
    defer alloc.free(image.data);

    var drm_device = try DrmDevice.open(alloc, "/dev/dri/card0");
    defer drm_device.deinit();

    drm_device.set_master() catch {
        std.log.err("Failed to become master", .{});
        return;
    };

    try show_version(drm_device);

    const res = try drm_device.get_resources();
    defer res.deinit();

    std.debug.print("{}\n", .{res});

    const connector = try drm_device.get_connector(res.connector_ids[0]);
    defer connector.deinit();

    if (!connector.connected) {
        std.log.err("Connector disconnected. Aborting", .{});
        return;
    }

    var mode = connector.modes[0];
    const fb_id = try create_framebuffer(drm_device.fd, mode.hdisplay, mode.vdisplay);
    const crtc = try find_crtc(drm_device.fd, &connector);

    var scrtc: DrmCrtc = .{
        .fb_id = fb_id,
        .crtc_id = crtc,
        .connectors = &[1]u32{connector.id},
        .mode = mode,
    };

    var saved_crtc = try drm_device.get_crtc(crtc);
    saved_crtc.connectors = &[1]u32{connector.id};

    try drm_device.set_crtc(&scrtc);
    defer drm_device.set_crtc(&saved_crtc) catch {};

    var start_x: u32 = mode.hdisplay / 2 - @truncate(u32, image.width) / 2;
    var start_y: u32 = mode.vdisplay / 2 - @truncate(u32, image.height) / 2;
    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const offset = (y * image.width + x) * 3;
            const r = image.data[offset];
            const g = image.data[offset + 1];
            const b = image.data[offset + 2];
            set_pixel(start_x + x, start_y + y, Color.init(r, g, b));
        }
    }

    std.time.sleep(1000 * 1000 * 1000 * 10);
}
