const std = @import("std");
const net = std.net;
const os = std.os;
const zanzara = @import("src/zanzara.zig");
const DefaultClient = zanzara.mqtt4.DefaultClient;
const Subscribe = zanzara.mqtt4.packet.Subscribe;

const TcpConnectToAddressError = std.posix.SocketError || std.posix.ConnectError;

fn tcpConnectToAddressNonBlock(address: net.Address) TcpConnectToAddressError!net.Stream {
    const sock_flags = std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK;
    const sockfd = try std.posix.socket(address.any.family, sock_flags, std.posix.IPPROTO.TCP);
    errdefer net.Stream.close(.{ .handle = sockfd });

    std.posix.connect(sockfd, &address.any, address.getOsSockLen()) catch |err| {
        switch (err) {
            error.WouldBlock => std.time.sleep(1 * std.time.ns_per_s), // Todo: handle this better
            else => return err,
        }
    };

    return net.Stream{ .handle = sockfd };
}

fn tcpConnectToHostNonBlock(allocator: std.mem.Allocator, name: []const u8, port: u16) net.TcpConnectToHostError!net.Stream {
    const list = try net.getAddressList(allocator, name, port);
    defer list.deinit();

    if (list.addrs.len == 0) return error.UnknownHostName;

    for (list.addrs) |addr| {
        return tcpConnectToAddressNonBlock(addr) catch |err| switch (err) {
            error.ConnectionRefused => {
                continue;
            },
            else => return err,
        };
    }
    return std.posix.ConnectError.ConnectionRefused;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const stream = try tcpConnectToHostNonBlock(allocator, "mqtt.eclipseprojects.io", 1883);
    const socket = stream.handle;
    const writer = stream.writer();

    var mqtt_buf: [32 * 2048]u8 = undefined;
    var client = try DefaultClient.init(mqtt_buf[0 .. 1024 * 32], mqtt_buf[1024 * 32 ..]);

    // See ConnectOpts for additional options
    try client.connect(.{ .client_id = "zanzara" });

    var read_buf: [32 * 2048]u8 = undefined;

    while (true) {
        const bytes = std.posix.recv(socket, &read_buf, 0) catch |err|
            if (err == error.WouldBlock) 0 else return err;
        var rest = read_buf[0..bytes];
        while (true) {
            // The driving force of the client is the client.feed() function
            // This must be called periodically, either passing some data coming from the network
            // or with an empty slice (if no incoming data is present) to allow the client to handle
            // its periodic tasks, like pings etc.
            const event = client.feed(rest);
            switch (event.data) {
                .incoming_packet => |p| {
                    switch (p) {
                        .connack => {
                            std.debug.print("Connected, sending subscriptions\n", .{});
                            // Subscribe to the topic we're publishing on
                            const topics = [_]Subscribe.Topic{
                                .{ .topic_filter = "zig/zanzara_in", .qos = .qos2 },
                            };

                            _ = try client.subscribe(&topics);
                            _ = try client.publish("zig/zanzara_out", "Howdy!", .{});
                        },
                        .publish => |pb| {
                            std.debug.print("Received publish on topic {s} with payload {s}\n", .{ pb.topic, pb.payload });
                        },
                        else => std.debug.print("Received packet: {}\n", .{p}),
                    }
                },
                .outgoing_buf => |b| try writer.writeAll(b), // Write pending stuff to the socket
                .err => |e| std.debug.print("Error event: {}\n", .{e}),
                .none => {},
            }
            rest = rest[event.consumed..];
            if (rest.len == 0) break;
        }
    }
}
