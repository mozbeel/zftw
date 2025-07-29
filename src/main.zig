const std = @import("std");

const http_answer_type = enum {
    TEXT_PLAIN,
    TEXT_HTML,
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() !void {
    const address = try std.net.Address.parseIp("0.0.0.0", 8080);
    
    const tpe: u32 = std.posix.SOCK.STREAM;
    const protocol = std.posix.IPPROTO.TCP;
    const listener = try std.posix.socket(address.any.family, tpe, protocol);
    defer std.posix.close(listener);

    try std.posix.setsockopt(listener, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try std.posix.bind(listener, &address.any, address.getOsSockLen());
    try std.posix.listen(listener, 128);

    defer _ = gpa.deinit();

    std.debug.print("[zftw] Listening on 0.0.0.0:8080\n", .{});
    
    while (true) {
        var client_address : std.net.Address = undefined;
        var client_address_len: std.posix.socklen_t = @sizeOf(std.net.Address);

        const socket = std.posix.accept(listener, &client_address.any, &client_address_len, 0) catch |err| {
            std.debug.print("error accept: {}\n", .{ err });
            continue;
        };
        defer std.posix.close(socket);

        handle_connection(socket, client_address) catch |err| {
            std.debug.print("error hanndling request: {}", .{ err });
            continue;
        };
    }
}

fn handle_connection(socket : std.posix.socket_t, client_address: std.net.Address) !void {
    const MAX_REQUEST_SIZE = 8192;
    const HEADER_END = "\r\n\r\n";

    std.debug.print("{} connected\n", .{ client_address });

    var buf = std.ArrayList(u8).init(gpa.allocator());
    defer buf.deinit();

    while (true) {
        var temp: [512]u8 = undefined;
        const n = try std.posix.read(socket, &temp);
        if (n == 0) {
            return error.NoRequest;
        }

        try buf.appendSlice(temp[0..n]);

        if (buf.items.len > MAX_REQUEST_SIZE) {
            std.debug.print("Request too large\n", .{});
            return error.RequestTooLarge;
        }

        if (std.mem.indexOf(u8, buf.items, HEADER_END)) |_| {
            break;
        }
         
    }
    std.debug.print("Received headers:\n{s}\n", .{buf.items});
}

fn get_http_answer(string_data: []const u8, answer_type: http_answer_type) ![]const u8 {
    const http_version = "HTTP/1.1";
    const status = "200 OK";
    
    const allocator = gpa.allocator();
    const content_length = try std.fmt.allocPrint(allocator, "Content-Length: {}", .{ string_data.len });
    defer allocator.free(content_length);

    const content_type : []const u8 = switch (answer_type) {
        .TEXT_PLAIN => "Content-Type: text/plain",
        .TEXT_HTML => "Content-Type: text/html",
    };

    const final_http_answer = try std.fmt.allocPrint(allocator, "{s} {s}\r\n{!s}\r\n{s}\r\n\r\n{s}", .{ 
        http_version, status, content_length, content_type, string_data
    });

    return final_http_answer;
    
}

fn write(socket: std.posix.socket_t, msg: []const u8) !void {
    var pos : usize = 0;
    while (pos < msg.len) {
        const written = try std.posix.write(socket, msg[pos..]);
        if (written == 0) {
            return error.Closed;
        }
        pos += written;
    }
}
