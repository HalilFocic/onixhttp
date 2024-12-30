const std = @import("std");

pub const ServerOptions = struct {
    port: u16 = 8080,
    hostname: []const u8 = "127.0.0.1",
    buffer_size: usize = 8192,
    max_header_size: usize = 8192,
    max_body_size: usize = 1024 * 1024,
};

pub const Handler = *const fn (request: *Request, response: *Response) anyerror!void;

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
    TRACE,
    CONNECT,

    pub fn fromString(str: []const u8) ?Method {
        inline for (@typeInfo(Method).Enum.fields) |field| {
            if (std.mem.eql(u8, str, field.name)) {
                return @field(Method, field.name);
            }
        }
        return null;
    }
};

pub const StatusCode = enum(u16) {
    ok = 200,
    created = 201,
    accepted = 202,
    no_content = 204,

    moved_permanently = 301,
    found = 302,
    see_other = 303,
    not_modified = 304,
    temporary_redirect = 307,
    permanent_redirect = 308,

    bad_request = 400,
    unauthorized = 401,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    not_acceptable = 406,
    request_timeout = 408,
    conflict = 409,
    gone = 410,
    payload_too_large = 413,
    uri_too_long = 414,
    unsupported_media_type = 415,

    internal_server_error = 500,
    not_implemented = 501,
    bad_gateway = 502,
    service_unavailable = 503,
    gateway_timeout = 504,

    pub fn phrase(self: StatusCode) []const u8 {
        return switch (self) {
            .ok => "OK",
            .created => "Created",
            .accepted => "Accepted",
            .no_content => "No Content",
            .moved_permanently => "Moved Permanently",
            .found => "Found",
            .see_other => "See Other",
            .not_modified => "Not Modified",
            .temporary_redirect => "Temporary Redirect",
            .permanent_redirect => "Permanent Redirect",
            .bad_request => "Bad Request",
            .unauthorized => "Unauthorized",
            .forbidden => "Forbidden",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .not_acceptable => "Not Acceptable",
            .request_timeout => "Request Timeout",
            .conflict => "Conflict",
            .gone => "Gone",
            .payload_too_large => "Payload Too Large",
            .uri_too_long => "URI Too Long",
            .unsupported_media_type => "Unsupported Media Type",
            .internal_server_error => "Internal Server Error",
            .not_implemented => "Not Implemented",
            .bad_gateway => "Bad Gateway",
            .service_unavailable => "Service Unavailable",
            .gateway_timeout => "Gateway Timeout",
        };
    }
};

pub const HeaderName = struct {
    pub const content_type = "Content-Type";
    pub const content_length = "Content-Length";
    pub const host = "Host";
    pub const user_agent = "User-Agent";
    pub const accept = "Accept";
    pub const connection = "Connection";
    pub const authorization = "Authorization";
};

pub const ContentType = struct {
    pub const text_plain = "text/plain";
    pub const text_html = "text/html";
    pub const text_css = "text/css";
    pub const text_javascript = "text/javascript";
    pub const application_json = "application/json";
    pub const application_xml = "application/xml";
    pub const application_form = "application/x-www-form-urlencoded";
    pub const multipart_form = "multipart/form-data";
};

pub const ServerError = error{
    RequestHeaderTooLarge,
    RequestBodyTooLarge,
    InvalidMethod,
    InvalidHeader,
    InvalidRequest,
    ConnectionClosed,
    InternalError,
};

pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;
