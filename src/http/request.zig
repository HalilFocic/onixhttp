const std = @import("std");
const types = @import("types.zig");

pub const Request = struct {
    inner: std.http.Server.Request,

    allocator: std.mem.Allocator,

    body: ?[]u8 = null,

    headers: std.StringHashMap([]const u8),

    pub fn init(inner: std.http.Server.Request, allocator: std.mem.Allocator) !Request {
        const headers = std.StringHashMap([]const u8).init(allocator);

        return .{
            .inner = inner,
            .allocator = allocator,
            .headers = headers,
            .body = null,
        };
    }

    pub fn deinit(self: *Request) void {
        if (self.body) |body| {
            self.allocator.free(body);
        }
        self.headers.deinit();
    }

    pub fn method(self: Request) types.Method {
        return types.Method.fromString(@tagName(self.inner.head.method)) orelse .GET;
    }

    pub fn path(self: Request) []const u8 {
        return self.inner.head.target;
    }

    pub fn getHeader(self: Request, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    pub fn readBody(self: *Request) ![]u8 {
        if (self.body) |body| {
            return body;
        }

        if (!self.inner.head.method.requestHasBody()) {
            return &[_]u8{};
        }

        const content_length = if (self.getHeader(types.HeaderName.content_length)) |len|
            try std.fmt.parseInt(usize, len, 10)
        else
            return &[_]u8{};

        var body = try self.allocator.alloc(u8, content_length);
        errdefer self.allocator.free(body);

        var total_read: usize = 0;
        while (total_read < content_length) {
            const bytes_read = try self.inner.read(body[total_read..]);
            if (bytes_read == 0) break;
            total_read += bytes_read;
        }

        self.body = body;
        return body;
    }

    pub fn readJson(self: *Request, comptime T: type) !T {
        const body = try self.readBody();
        var stream = std.json.TokenStream.init(body);
        return try std.json.parse(T, &stream, .{
            .allocator = self.allocator,
        });
    }

    pub fn query(self: Request, name: []const u8) ?[]const u8 {
        const target = self.inner.head.target;
        const query_start = std.mem.indexOf(u8, target, "?") orelse return null;
        const query_str = target[query_start + 1 ..];

        var it = std.mem.split(u8, query_str, "&");
        while (it.next()) |pair| {
            var pair_it = std.mem.split(u8, pair, "=");
            const key = pair_it.next() orelse continue;
            const value = pair_it.next() orelse continue;

            if (std.mem.eql(u8, key, name)) {
                return value;
            }
        }

        return null;
    }
};
