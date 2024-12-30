const std = @import("std");
const types = @import("types.zig");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

pub const Server = struct {
    options: types.ServerOptions,

    allocator: std.mem.Allocator,

    running: bool = false,

    read_buffer: []u8,
    server: std.net.Server,

    pub fn init(allocator: std.mem.Allocator, options: types.ServerOptions) !Server {
        const address = try std.net.Address.resolveIp(options.hostname, options.port);
        const tcp_server = try address.listen(.{
            .reuse_address = true,
        });

        const read_buffer = try allocator.alloc(u8, options.buffer_size);

        return .{
            .allocator = allocator,
            .options = options,
            .server = tcp_server,
            .read_buffer = read_buffer,
        };
    }

    pub fn deinit(self: *Server) void {
        self.server.deinit();
        self.allocator.free(self.read_buffer);
    }

    pub fn start(self: *Server, handler: types.Handler) !void {
        self.running = true;
        std.debug.print("Server listening on {s}:{d}\n", .{ self.options.hostname, self.options.port });

        while (self.running) {
            const connection = self.server.accept() catch |err| {
                std.debug.print("Error accepting connection: {any}\n", .{err});
                continue;
            };
            defer connection.stream.close();

            try self.handleConnection(connection, handler);
        }
    }

    pub fn stop(self: *Server) void {
        self.running = false;
    }

    fn handleConnection(
        self: *Server,
        connection: std.net.Server.Connection,
        handler: types.Handler,
    ) !void {
        var http_server = std.http.Server.init(connection, self.read_buffer);

        const raw_request = http_server.receiveHead() catch |err| {
            std.debug.print("Error receiving request: {any}\n", .{err});
            return;
        };

        var request = try Request.init(raw_request, self.allocator);
        defer request.deinit();

        var response = Response.init(self.allocator, connection.stream);
        defer response.deinit();

        handler(&request, &response) catch |err| {
            std.debug.print("Error handling request: {any}\n", .{err});

            if (!response.sent) {
                response.status = .internal_server_error;
                response.text("Internal Server Error") catch {};
            }
        };
        std.debug.print("Handler finished\n {}\n", .{response.sent});
        if (!response.sent) {
            response.send() catch |err| {
                std.debug.print("Error sending response: {any}\n", .{err});
            };
        }
    }
};

pub fn staticHandler(content: []const u8) types.Handler {
    return struct {
        fn handle(request: *Request, response: *Response) !void {
            _ = request;
            try response.text(content);
        }
    }.handle;
}
