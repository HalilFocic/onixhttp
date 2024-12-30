const std = @import("std");
const net = std.net;
const Address = net.Address;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    //    const allocator = gpa.allocator();

    var read_buffer: [8192]u8 = undefined;
    const address = try Address.parseIp("127.0.0.1", 8080);

    var tcp_server = try address.listen(.{
        .reuse_address = true,
    });
    defer tcp_server.deinit();

    std.debug.print("Server listening on {}\n", .{tcp_server.listen_address});

    while (true) {
        const connection = try tcp_server.accept();
        defer connection.stream.close();

        var http_server = std.http.Server.init(connection, &read_buffer);

        const request = try http_server.receiveHead();
        std.debug.print("{s} request from {s}\n", .{ @tagName(request.head.method), request.head.target });

        const status_line = "HTTP/1.1 200 OK\r\n";
        const headers = "Content-Type: text/plain\r\nContent-Length: 25\r\n\r\n";
        try connection.stream.writeAll(status_line);
        try connection.stream.writeAll(headers);
        try connection.stream.writeAll("Hello from Zig HTTP Server!\n");
    }
}
