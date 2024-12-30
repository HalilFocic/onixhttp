const std = @import("std");
const types = @import("types.zig");

pub const Response = struct {
    status: types.StatusCode = .ok,

    headers: std.StringHashMap([]const u8),

    body: ?[]const u8 = null,

    stream: std.net.Stream,

    allocator: std.mem.Allocator,

    sent: bool = false,

    pub fn init(allocator: std.mem.Allocator, stream: std.net.Stream) Response {
        return .{
            .allocator = allocator,
            .stream = stream,
            .headers = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit();
        if (self.body) |body| {
            self.allocator.free(body);
        }
    }

    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) !void {
        try self.headers.put(name, value);
    }

    pub fn setBody(self: *Response, body: []const u8) !void {
        if (self.body) |old_body| {
            self.allocator.free(old_body);
        }

        const new_body = try self.allocator.alloc(u8, body.len);
        @memcpy(new_body, body);
        self.body = new_body;

        var content_length_buf: [16]u8 = undefined;
        const content_length = try std.fmt.bufPrint(&content_length_buf, "{d}", .{body.len});
        try self.setHeader(types.HeaderName.content_length, content_length);
    }

    pub fn json(self: *Response, data: anytype, options: std.json.StringifyOptions) !void {
        const json_string = try std.json.stringifyAlloc(self.allocator, data, options);
        defer self.allocator.free(json_string);

        try self.setHeader(types.HeaderName.content_type, types.ContentType.application_json);
        try self.setBody(json_string);
        try self.send();
    }

    pub fn send(self: *Response) !void {
        if (self.sent) return error.ResponseAlreadySent;
        self.sent = true;

        if (!self.headers.contains(types.HeaderName.content_type)) {
            try self.setHeader(types.HeaderName.content_type, types.ContentType.text_plain);
        }

        if (self.body) |body| {
            if (!self.headers.contains(types.HeaderName.content_length)) {
                var content_length_buf: [16]u8 = undefined;
                const content_length = try std.fmt.bufPrint(&content_length_buf, "{d}", .{body.len});
                try self.setHeader(types.HeaderName.content_length, content_length);
            }
        } else {
            try self.setHeader(types.HeaderName.content_length, "0");
        }

        try self.stream.writer().print("HTTP/1.1 {d} {s}\r\n", .{
            @intFromEnum(self.status),
            self.status.phrase(),
        });

        var header_it = self.headers.iterator();
        while (header_it.next()) |entry| {
            try self.stream.writer().print("{s}: {s}\r\n", .{
                entry.key_ptr.*,
                entry.value_ptr.*,
            });
        }

        try self.stream.writeAll("\r\n");
        if (self.body) |body| {
            try self.stream.writeAll(body);
        }
    }
    pub fn text(self: *Response, content: []const u8) !void {
        try self.setHeader(types.HeaderName.content_type, types.ContentType.text_plain);
        try self.setBody(content);
        try self.send();
    }

    pub fn html(self: *Response, content: []const u8) !void {
        try self.setHeader(types.HeaderName.content_type, types.ContentType.text_html);
        try self.setBody(content);
        try self.send();
    }

    pub fn redirect(self: *Response, url: []const u8, temporary: bool) !void {
        self.status = if (temporary) .found else .moved_permanently;
        try self.setHeader("Location", url);
        try self.send();
    }
};
