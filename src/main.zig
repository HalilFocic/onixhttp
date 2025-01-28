// Multithreaded server with a ThreadPool
const std = @import("std");
const net = std.net;
const posix = std.posix;
const log = std.log;
const Allocator = std.mem.Allocator;
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try Server.init(allocator, 4096);
    defer server.deinit();

    const address = try std.net.Address.parseIp("127.0.0.1", 8000);
    try server.run(address);
}

const READ_TIMEOUT_MS = 60_000;

const ClientList = std.DoublyLinkedList(*Client);
const ClientNode = ClientList.Node;
const Client = struct {
    socket: posix.socket_t,
    address: std.net.Address,
    reader: Reader,
    to_write: []u8,
    write_buf: []u8,
    read_timeout: i64,
    read_timeout_node: *ClientNode,

    fn init(allocator: Allocator, socket: posix.socket_t, address: std.net.Address) !Client {
        const reader = try Reader.init(allocator, 4096);
        errdefer reader.deinit(allocator);

        const write_buf = try allocator.alloc(u8, 4096);
        errdefer allocator.free(write_buf);
        return .{
            .reader = reader,
            .socket = socket,
            .address = address,
            .to_write = &.{},
            .write_buf = write_buf,
            .read_timeout = 0,
            .read_timeout_node = undefined,
        };
    }

    fn deinit(self: *const Client, allocator: Allocator) void {
        self.reader.deinit(allocator);
        allocator.free(self.write_buf);
    }

    fn handle(self: Client) void {
        defer posix.close(self.socket);
        self._handle() catch |err| switch (err) {
            error.Closed => {},
            error.WouldBlock => {}, // read or write timeout
            else => std.debug.print("[{any}] client handle error: {}\n", .{ self.address, err }),
        };
    }

    fn _handle(self: Client) !void {
        const socket = self.socket;
        std.debug.print("[{}] connected\n", .{self.address});

        const timeout = posix.timeval{ .sec = 2, .usec = 500_000 };
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(timeout));
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(timeout));

        var buf: [1024]u8 = undefined;
        var reader = Reader{ .pos = 0, .buf = &buf, .socket = socket };

        while (true) {
            const msg = try reader.readMessage();
            std.debug.print("[{}] sent: {s}\n", .{ self.address, msg });
        }
    }

    fn readMessage(self: *Client) !?[]const u8 {
        return self.reader.readMessage(self.socket) catch |err| switch (err) {
            error.WouldBlock => null,
            else => return err,
        };
    }

    fn writeMessage(self: *Client, msg: []const u8) !bool {
        if (self.to_write.len > 0) {
            return error.PendingMessage;
        }

        if (msg.len + 4 > self.write_buf.len) {
            return error.MessageTooLarge;
        }

        std.mem.writeInt(u32, self.write_buf[0..4], @intCast(msg.len), .little);

        const end = msg.len + 4;
        @memcpy(self.write_buf[4..end], msg);

        self.to_write = self.write_buf[0..4];
        return self.write();
    }

    fn write(self: *Client) !bool {
        var buf = self.to_write;
        defer self.to_write = buf;

        while (buf.len > 0) {
            const n = posix.write(self.socket, buf) catch |err| switch (err) {
                error.WouldBlock => return false,
                else => return err,
            };
            if (n == 0) {
                return error.Closed;
            }

            buf = buf[n..];
        } else {
            return true;
        }
    }
};

const Reader = struct {
    buf: []u8,
    pos: usize = 0,
    start: usize = 0,

    fn init(allocator: Allocator, size: usize) !Reader {
        const buf = try allocator.alloc(u8, size);
        return .{
            .pos = 0,
            .start = 0,
            .buf = buf,
        };
    }

    fn deinit(self: *const Reader, allocator: Allocator) void {
        allocator.free(self.buf);
    }

    fn readMessage(self: *Reader, socket: posix.socket_t) ![]u8 {
        var buf = self.buf;

        while (true) {
            if (try self.bufferedMessage()) |msg| {
                return msg;
            }
            const pos = self.pos;
            const n = try posix.read(socket, buf[pos..]);
            if (n == 0) {
                return error.Closed;
            }
            self.pos = pos + n;
        }
    }

    fn bufferedMessage(self: *Reader) !?[]u8 {
        const buf = self.buf;
        const pos = self.pos;
        const start = self.start;

        std.debug.assert(pos >= start);
        const unprocessed = buf[start..pos];
        if (unprocessed.len < 4) {
            self.ensureSpace(4 - unprocessed.len) catch unreachable;
            return null;
        }

        const message_len = std.mem.readInt(u32, unprocessed[0..4], .little);

        // the length of our message + the length of our prefix
        const total_len = message_len + 4;

        if (unprocessed.len < total_len) {
            try self.ensureSpace(total_len);
            return null;
        }

        self.start += total_len;
        return unprocessed[4..total_len];
    }

    fn ensureSpace(self: *Reader, space: usize) error{BufferTooSmall}!void {
        const buf = self.buf;
        if (buf.len < space) {
            return error.BufferTooSmall;
        }

        const start = self.start;
        const spare = buf.len - start;
        if (spare >= space) {
            return;
        }

        const unprocessed = buf[start..self.pos];
        std.mem.copyForwards(u8, buf[0..unprocessed.len], unprocessed);
        self.start = 0;
        self.pos = unprocessed.len;
    }
};

const Server = struct {
    allocator: Allocator,
    connected: usize,
    polls: []posix.pollfd,
    client_polls: []posix.pollfd,
    client_pool: std.heap.MemoryPool(Client),
    clients: []*Client,
    read_timeout_list: ClientList,
    client_node_pool: std.heap.MemoryPool(ClientList.Node),

    fn init(allocator: Allocator, max: usize) !Server {
        const polls = try allocator.alloc(posix.pollfd, max + 1); // <== Plus one is because of listening socket
        errdefer allocator.free(polls);

        const clients = try allocator.alloc(*Client, max);
        errdefer allocator.free(clients);

        return .{
            .polls = polls,
            .clients = clients,
            .client_polls = polls[1..],
            .connected = 0,
            .allocator = allocator,
            .client_pool = std.heap.MemoryPool(Client).init(allocator),
            .client_node_pool = std.heap.MemoryPool(ClientNode).init(allocator),
            .read_timeout_list = .{},
        };
    }

    fn deinit(self: *Server) void {
        self.allocator.free(self.clients);
        self.allocator.free(self.polls);
        self.client_pool.deinit();
        self.client_node_pool.deinit();
    }

    fn run(self: *Server, address: std.net.Address) !void {
        const tpe: u32 = posix.SOCK.STREAM | posix.SOCK.NONBLOCK;
        const protocol = posix.IPPROTO.TCP;
        const listener = try posix.socket(address.any.family, tpe, protocol);
        defer posix.close(listener);

        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.bind(listener, &address.any, address.getOsSockLen());
        try posix.listen(listener, 128);

        self.polls[0] = .{
            .fd = listener,
            .revents = 0,
            .events = posix.POLL.IN,
        };

        var read_timeout_list = &self.read_timeout_list;
        while (true) {
            const next_timeout = self.enforceTimeout();
            _ = try posix.poll(self.polls[0 .. self.connected + 1], next_timeout);

            if (self.polls[0].revents != 0) {
                self.accept(listener) catch |err| log.err("failed to accept: {} \n", .{err});
            }

            var i: usize = 0;
            while (i < self.connected) {
                const revents = self.client_polls[i].revents;
                if (revents == 0) {
                    i += 1;
                    continue;
                }

                var client = self.clients[i];
                if (revents & posix.POLL.IN == posix.POLL.IN) {
                    while (true) {
                        const msg = client.readMessage() catch {
                            self.removeClient(i);
                            break;
                        } orelse {
                            i += 1;
                            break;
                        };
                        client.read_timeout = std.time.milliTimestamp() + READ_TIMEOUT_MS;
                        read_timeout_list.remove(client.read_timeout_node);
                        read_timeout_list.append(client.read_timeout_node);
                        const written = client.writeMessage(msg) catch {
                            self.removeClient(i);
                            break;
                        };

                        if (written == false) {
                            self.client_polls[i].events = posix.POLL.OUT;
                        }
                        std.debug.print("got: {s}\n", .{msg});
                    }
                } else if (revents & posix.POLL.OUT == posix.POLL.OUT) {
                    const written = client.write() catch {
                        self.removeClient(i);
                        continue;
                    };
                    if (written) {
                        self.client_polls[i].events = posix.POLL.IN;
                    }
                }
            }
        }
    }

    fn enforceTimeout(self: *Server) i32 {
        const now = std.time.milliTimestamp();

        var node = self.read_timeout_list.first;
        while (node) |n| {
            const client = n.data;
            const diff = client.read_timeout - now;
            if (diff > 0) {
                return @intCast(diff);
            }
            posix.shutdown(client.socket, .recv) catch {};
            node = n.next;
        } else {
            return -1;
        }
    }

    fn accept(self: *Server, listener: posix.socket_t) !void {
        const space = self.client_polls.len - self.connected;
        for (0..space) |_| {
            var address: std.net.Address = undefined;
            var address_len: posix.socklen_t = @sizeOf(net.Address);
            const socket = posix.accept(listener, &address.any, &address_len, posix.SOCK.NONBLOCK) catch |err| switch (err) {
                error.WouldBlock => return,
                else => break,
            };
            const client = try self.client_pool.create();
            errdefer self.client_pool.destroy(client);
            client.* = Client.init(self.allocator, socket, address) catch |err| {
                posix.close(socket);
                log.err("failed to initalize client: {}", .{err});
                return;
            };
            std.debug.print("client connected\n", .{});
            const connected = self.connected;
            self.clients[connected] = client;
            self.client_polls[connected] = .{
                .fd = socket,
                .revents = 0,
                .events = posix.POLL.IN | posix.POLL.OUT,
            };
            self.connected = connected + 1;
        } else {
            self.polls[0].events = 0;
        }
    }

    fn removeClient(self: *Server, at: usize) void {
        var client = self.clients[at];
        defer self.client_pool.destroy(client);
        posix.close(client.socket);
        client.deinit(self.allocator);

        const last_index = self.connected - 1;
        self.clients[at] = self.clients[last_index];
        self.client_polls[at] = self.client_polls[last_index];
        self.connected = last_index;
        self.polls[0].events = posix.POLL.IN;
    }
};
