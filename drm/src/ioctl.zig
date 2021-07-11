const std = @import("std");
const linux = std.os.linux;

const _IOC_NONE = 0;
const _IOC_WRITE = 1;
const _IOC_READ = 2;

const _IOC_NRBITS = 8;
const _IOC_TYPEBITS = 8;
const _IOC_SIZEBITS = 14;
//#define _IOC_NRSHIFT	0
const _IOC_NRSHIFT = 0;
//#define _IOC_TYPESHIFT	(_IOC_NRSHIFT+_IOC_NRBITS)
const _IOC_TYPESHIFT = _IOC_NRSHIFT + _IOC_NRBITS;
//#define _IOC_SIZESHIFT	(_IOC_TYPESHIFT+_IOC_TYPEBITS)
const _IOC_SIZESHIFT = _IOC_TYPESHIFT + _IOC_TYPEBITS;
//#define _IOC_DIRSHIFT	(_IOC_SIZESHIFT+_IOC_SIZEBITS)
const _IOC_DIRSHIFT = _IOC_SIZESHIFT + _IOC_SIZEBITS;

//#define _IOWR(type,nr,size)	_IOC(_IOC_READ|_IOC_WRITE,(type),(nr),(_IOC_TYPECHECK(size)))
pub fn _IOWR(typ: usize, nr: usize, size: usize) usize {
    return _IOC(_IOC_READ | _IOC_WRITE, typ, nr, size);
}

pub fn _IO(typ: usize, nr: usize) usize {
    return _IOC(_IOC_NONE, typ, nr, 0);
}

//#define _IOC(dir,type,nr,size) \
//	(((dir)  << _IOC_DIRSHIFT) | \
//	 ((type) << _IOC_TYPESHIFT) | \
//	 ((nr)   << _IOC_NRSHIFT) | \
//	 ((size) << _IOC_SIZESHIFT))

fn _IOC(dir: usize, typ: usize, nr: usize, size: usize) usize {
    return (dir << _IOC_DIRSHIFT) |
        (typ << _IOC_TYPESHIFT) |
        (nr << _IOC_NRSHIFT) |
        (size << _IOC_SIZESHIFT);
}

pub fn ioctl(fd: std.os.fd_t, request: usize, addr: usize) !void {
    const err = linux.getErrno(linux.syscall3(
        .ioctl,
        @as(usize, @bitCast(u32, fd)),
        request,
        addr,
    ));
    if (err != 0) {
        std.debug.print("ioctl returned: {}\n", .{err});
        return error.IoctlError;
    }
}
