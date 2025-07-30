const std = @import("std");

const http_answer_type = enum {
    TEXT_PLAIN,
    TEXT_HTML,
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const orange = "\x1b[38;5;210m";
const dark_orange = "\x1b[38;5;202m";
const reset_color = "\x1b[0m";

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

    std.debug.print("{s}[zftw] {s}Listening on 0.0.0.0:8080\n{s}", .{ orange, dark_orange, reset_color });
    
    while (true) {
        var client_address : std.net.Address = undefined;
        var client_address_len: std.posix.socklen_t = @sizeOf(std.net.Address);

        const socket = std.posix.accept(listener, &client_address.any, &client_address_len, 0) catch |err| {
            std.debug.print("{s}[zftw] {s}error accept: {}\n{s}", .{ orange, dark_orange, err, reset_color });
            continue;
        };
        defer std.posix.close(socket);

        handle_connection(socket, client_address) catch |err| {
            std.debug.print("{s}[zftw] {s}error hanndling request: {}\n{s}", .{ orange, dark_orange, err, reset_color });
            continue;
        };
    }
}

fn handle_connection(socket : std.posix.socket_t, client_address: std.net.Address) !void {
    const MAX_REQUEST_SIZE = 32768;
    const HEADER_END = "\r\n\r\n";

    var headers = std.ArrayList(u8).init(gpa.allocator());
    defer headers.deinit();

    while (true) {
        var temp: [2048]u8 = undefined;
        const n = try std.posix.read(socket, &temp);
        if (n == 0) {
            return error.NoRequest;
        }

        try headers.appendSlice(temp[0..n]);

        if (headers.items.len > MAX_REQUEST_SIZE) {
            std.debug.print("Request too large\n", .{});
            return error.RequestTooLarge;
        }

        if (std.mem.indexOf(u8, headers.items, HEADER_END)) |_| {
            break;
        }
         
    }

    var headers_iter = std.mem.splitSequence(u8, headers.items, "\r\n");

    var page_path: []const u8 = "";
    var supports_content_types : bool = false;
    var request_str : []const u8 = "";

    defer std.debug.print("\n", .{});

    while (headers_iter.next()) |header| {
        if (std.mem.eql(u8, header, "")) continue;
        
        if (std.mem.startsWith(u8, header, "GET")) {
            request_str = "GET";
            var get_iter = std.mem.splitSequence(u8, header, " ");
            while (get_iter.next()) |part| {
                if (std.mem.eql(u8, part, "GET")) continue;
                if (std.mem.startsWith(u8, part, "HTTP")) continue;

                if (std.mem.startsWith(u8, part, "/")) {
                    // /index.html => index.html      
                    const part1 = part[1..];

                    if (std.mem.eql(u8, part1, "")) {
                        page_path = "index.html";
                    }
                }
            }
        } else if(std.mem.startsWith(u8, header, "Accept")) {
            const accept_str: []const u8 = "Accept: ";

            const accepted_content = header[accept_str.len..];

            var accept_iter = std.mem.splitSequence(u8, accepted_content, ",");

            var accept_html: bool = false;

            while(accept_iter.next()) |a| {
                if (std.mem.eql(u8, a, "*/*")) {
                    accept_html = true;
                    break;
                }

                if (std.mem.eql(u8, a, "text/html")) accept_html = true;
            }

            if (accept_html) {
                supports_content_types = true;
            } 
        }

    }

    if (
        !supports_content_types or 
        std.mem.eql(u8, page_path, "") 
       ) {
        return error.NotCompatibleWithZLFW;
    }

    std.debug.print("{s}[zftw] [{s}] {s}{} connected\n", .{ orange, request_str, dark_orange, client_address });

    const htmlFile = std.fs.cwd().openFile(page_path, .{}) catch return error.CouldntFindHTMLFile;
    defer htmlFile.close();

    var data: [4096]u8 = undefined;
    
    // Streaming the html file in case it's large
    while (true) {
        const read = try htmlFile.read(&data);
        if (read == 0) break;

        const http_answer = try get_http_answer(data[0..read], .TEXT_HTML);

        try write(socket, http_answer);

    }
}

fn escapeVisible(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);

    defer list.deinit();

    for (input) |c| {
        switch (c) {
            '\\' => try list.appendSlice("\\\\"),
            '\n' => try list.appendSlice("\\n"),
            '\r' => try list.appendSlice("\\r"),
            '\t' => try list.appendSlice("\\t"),
            '\x08' => try list.appendSlice("\\b"),
            '\x0C' => try list.appendSlice("\\f"),
            '"' => try list.appendSlice("\\\""),
            '\'' => try list.appendSlice("\\'"),
            else => {
                try list.append(c);
            }
        }
    }

    return list.toOwnedSlice();
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
