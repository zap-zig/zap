const std = @import("std");

/// Download a file using native Zig HTTP client
pub fn downloadFile(allocator: std.mem.Allocator, url: []const u8, output_path: []const u8) !void {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    // Write directly to file
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    var buf: [8192]u8 = undefined;
    var file_writer = file.writer(&buf);

    const result = try client.fetch(.{
        .location = .{ .uri = uri },
        .response_writer = &file_writer.interface,
    });

    try file_writer.interface.flush();

    if (result.status != .ok) {
        std.debug.print("HTTP error: {}\n", .{result.status});
        return error.HttpError;
    }
}

/// Fetch content from URL as string using native Zig HTTP
pub fn fetchString(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    // Write to temp file, then read back (Zig 0.15.2 doesn't have easy memory writer)
    const tmp_path = "/tmp/.zap_http_response";

    const file = try std.fs.cwd().createFile(tmp_path, .{});

    var buf: [8192]u8 = undefined;
    var file_writer = file.writer(&buf);

    const result = client.fetch(.{
        .location = .{ .uri = uri },
        .response_writer = &file_writer.interface,
    }) catch |err| {
        file.close();
        std.debug.print("HTTP fetch error: {}\n", .{err});
        return error.HttpError;
    };

    file_writer.interface.flush() catch {};
    file.close();

    if (result.status != .ok) {
        std.debug.print("HTTP error: {}\n", .{result.status});
        return error.HttpError;
    }

    // Read back from temp file
    return try std.fs.cwd().readFileAlloc(allocator, tmp_path, 10 * 1024 * 1024);
}
