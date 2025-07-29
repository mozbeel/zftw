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

        std.debug.print("{} connected\n", .{ client_address });

        const http_answer = try get_http_answer("Hello and goodbye", .TEXT_PLAIN);
        defer gpa.allocator().free(http_answer);

        write(socket, http_answer) catch |err| {
            std.debug.print("error writing: {}\n", .{ err });
        };
        
    }
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
