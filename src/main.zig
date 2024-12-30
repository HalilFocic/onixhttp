const std = @import("std");
const Server = @import("http/server.zig").Server;
const Request = @import("http/request.zig").Request;
const Response = @import("http/response.zig").Response;
pub fn handler(req: *Request, res: *Response) !void {
    std.debug.print("HNADLER RECEIVED FUNCTION \n", .{});
    if (std.mem.eql(u8, req.path(), "/")) {
        try res.text("Hello, World! \n");
    } else {
        res.status = .not_found;
        try res.text("Not Found");
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try Server.init(allocator, .{
        .port = 8080,
        .hostname = "127.0.0.1",
    });
    defer server.deinit();

    try server.start(handler);
}
