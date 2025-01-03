const std = @import("std");
const net = std.net;
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
    while (true) {
        var client_address: net.Address = undefined;
        var client_address_len: posix.socklen_t = @sizeOf(net.Address);

        const socket = posix.accept(sockfd, &client_address.any, &client_address_len, posix.SOCK.CLOEXEC) catch |err| {
            switch (err) {
                posix.AcceptError.WouldBlock => {},
                else => std.debug.print("Error while accepting: {any}\n", .{err}),
            }
            continue;
        };
        defer posix.close(socket);

        std.debug.print("User connect from address {}", .{client_address});
        write(socket, "Hello from zig") catch |err| {
            std.debug.print("error writing: {}\n", .{err});
        };
    }
}

fn write(socket: posix.socket_t, msg: []const u8) !void {
    const response = try std.fmt.allocPrint(std.heap.page_allocator, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\n\r\n{s}", .{ msg.len, msg });
    defer std.heap.page_allocator.free(response);
    var pos: usize = 0;
    while (pos < response.len) {
        const written = try posix.write(socket, response[pos..]);
        if (written == 0) {
            return error.Closed;
        }
        pos += written;
    }
}
