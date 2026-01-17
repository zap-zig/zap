const std = @import("std");

/// Extract a ZIP file to a directory using native Zig std.zip
pub fn extractZip(allocator: std.mem.Allocator, zip_path: []const u8, dest_dir: []const u8) !void {
    _ = allocator; // Not needed for native extraction

    // Open the ZIP file
    const zip_file = try std.fs.cwd().openFile(zip_path, .{});
    defer zip_file.close();

    // Create destination directory if it doesn't exist
    std.fs.cwd().makePath(dest_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Open destination directory
    var dest = try std.fs.cwd().openDir(dest_dir, .{});
    defer dest.close();

    // Create file reader
    var read_buffer: [8192]u8 = undefined;
    var file_reader = zip_file.reader(&read_buffer);

    // Extract using std.zip
    try std.zip.extract(dest, &file_reader, .{});
}
