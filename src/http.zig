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

    // Generate unique temp file path using timestamp and random value to avoid race conditions
    var rand_buf: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);
    const rand_val = std.mem.readInt(u64, &rand_buf, .little);
    const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/.zap_http_{d}_{d}", .{ std.time.nanoTimestamp(), rand_val });
    defer allocator.free(tmp_path);

    const file = try std.fs.cwd().createFile(tmp_path, .{});
    errdefer std.fs.cwd().deleteFile(tmp_path) catch {};

    var buf: [8192]u8 = undefined;
    var file_writer = file.writer(&buf);

    const result = client.fetch(.{
        .location = .{ .uri = uri },
        .response_writer = &file_writer.interface,
    }) catch |err| {
        file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {};
        std.debug.print("HTTP fetch error: {}\n", .{err});
        return error.HttpError;
    };

    file_writer.interface.flush() catch {};
    file.close();

    if (result.status != .ok) {
        std.fs.cwd().deleteFile(tmp_path) catch {};
        std.debug.print("HTTP error: {}\n", .{result.status});
        return error.HttpError;
    }

    // Read back from temp file and clean up
    const content = try std.fs.cwd().readFileAlloc(allocator, tmp_path, 10 * 1024 * 1024);
    std.fs.cwd().deleteFile(tmp_path) catch {};
    return content;
}
