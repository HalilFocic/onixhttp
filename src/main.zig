const std = @import("std");
const posix = std.posix;
const windows = std.os.windows;
const builtin = @import("builtin");
const native_os = builtin.os.tag;
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    _ = gpa.allocator();
    const kernel_backlog = 128;
    var address = try std.net.Address.resolveIp("127.0.0.1", 8000);
    const nonblock: u32 = posix.SOCK.NONBLOCK;
    const sock_flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC | nonblock;
    const proto: u32 = if (address.any.family == posix.AF.UNIX) 0 else posix.IPPROTO.TCP;

    const sockfd = try posix.socket(address.any.family, sock_flags, proto);
    errdefer posix.close(sockfd);

    try posix.setsockopt(
        sockfd,
        posix.SOL.SOCKET,
        posix.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1)),
    );
    switch (native_os) {
        .windows => {},
        else => try posix.setsockopt(
            sockfd,
            posix.SOL.SOCKET,
            posix.SO.REUSEPORT,
            &std.mem.toBytes(@as(c_int, 1)),
        ),
    }
    var socklen = address.getOsSockLen();
    try posix.bind(sockfd, &address.any, socklen);
    try posix.listen(sockfd, kernel_backlog);
    try posix.getsockname(sockfd, &address.any, &socklen);
}
