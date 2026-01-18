const std = @import("std");
const zip = @import("zip.zig");

/// Extract a wheel file to a directory
pub fn extractWheel(allocator: std.mem.Allocator, wheel_path: []const u8, dest_dir: []const u8) !void {
    // Wheels are just zip files
    try zip.extractZip(allocator, wheel_path, dest_dir);
}

/// Extract a source distribution (tar.gz or zip)
pub fn extractSdist(allocator: std.mem.Allocator, sdist_path: []const u8, dest_dir: []const u8) !void {
    if (std.mem.endsWith(u8, sdist_path, ".tar.gz") or std.mem.endsWith(u8, sdist_path, ".tgz")) {
        try extractTarGz(allocator, sdist_path, dest_dir);
    } else if (std.mem.endsWith(u8, sdist_path, ".zip")) {
        try extractWheel(allocator, sdist_path, dest_dir);
    } else {
        return error.UnsupportedFormat;
    }
}

/// Extract a .tar.gz file using native Zig
fn extractTarGz(allocator: std.mem.Allocator, tar_path: []const u8, dest_dir: []const u8) !void {
    // Ensure destination directory exists
    std.fs.cwd().makePath(dest_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const file = try std.fs.cwd().openFile(tar_path, .{});
    defer file.close();

    // Create a buffered reader for the file
    var read_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(&read_buffer);

    // Create gzip decompressor using flate with gzip container
    var window_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&file_reader.interface, .gzip, &window_buffer);

    // Open destination directory
    var dest = try std.fs.cwd().openDir(dest_dir, .{});
    defer dest.close();

    // Extract tar
    _ = allocator; // Not needed for tar extraction in this Zig version
    std.tar.pipeToFileSystem(dest, &decompressor.reader, .{
        .strip_components = 0,
    }) catch |err| {
        std.debug.print("Error extracting tar.gz: {}\n", .{err});
        return error.ExtractionFailed;
    };
}

/// Copy a single file using native Zig
fn copyFile(src_path: []const u8, dest_path: []const u8) !void {
    const src_file = try std.fs.cwd().openFile(src_path, .{});
    defer src_file.close();

    const dest_file = try std.fs.cwd().createFile(dest_path, .{});
    defer dest_file.close();

    // Get source file size for efficient copying
    const stat = try src_file.stat();
    const size = stat.size;

    // Use copyRangeAll for efficient copying
    if (size > 0) {
        _ = try std.fs.File.copyRangeAll(src_file, 0, dest_file, 0, size);
    }

    // Preserve file mode
    dest_file.chmod(stat.mode) catch {};
}

/// Recursively copy a directory using native Zig
fn copyDirRecursive(allocator: std.mem.Allocator, src_dir_path: []const u8, dest_dir_path: []const u8) !void {
    // Create destination directory
    std.fs.cwd().makePath(dest_dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    var src_dir = try std.fs.cwd().openDir(src_dir_path, .{ .iterate = true });
    defer src_dir.close();

    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        const src_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_dir_path, entry.name });
        defer allocator.free(src_path);

        const dest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest_dir_path, entry.name });
        defer allocator.free(dest_path);

        switch (entry.kind) {
            .file => {
                try copyFile(src_path, dest_path);
            },
            .directory => {
                try copyDirRecursive(allocator, src_path, dest_path);
            },
            .sym_link => {
                // Read symlink target and create new symlink
                var target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const target = try src_dir.readLink(entry.name, &target_buf);
                std.fs.cwd().symLink(target, dest_path, .{}) catch |err| {
                    if (err != error.PathAlreadyExists) return err;
                };
            },
            else => {
                // Skip other types (block devices, etc.)
            },
        }
    }
}

/// Install wheel contents to site-packages
pub fn installWheelToSitePackages(allocator: std.mem.Allocator, wheel_extract_dir: []const u8, site_packages: []const u8) !void {
    var dir = try std.fs.cwd().openDir(wheel_extract_dir, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Skip .whl files, .dist-info for now (copy later), and .data
        if (std.mem.endsWith(u8, entry.name, ".whl") or
            std.mem.endsWith(u8, entry.name, ".data"))
        {
            continue;
        }

        // Copy everything to site-packages using native Zig
        const src_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ wheel_extract_dir, entry.name });
        defer allocator.free(src_path);

        const dest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ site_packages, entry.name });
        defer allocator.free(dest_path);

        if (entry.kind == .directory) {
            try copyDirRecursive(allocator, src_path, dest_path);
        } else if (entry.kind == .file) {
            try copyFile(src_path, dest_path);
        } else if (entry.kind == .sym_link) {
            var target_buf: [std.fs.max_path_bytes]u8 = undefined;
            const target = try dir.readLink(entry.name, &target_buf);
            std.fs.cwd().symLink(target, dest_path, .{}) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
        }
    }
}

/// Get site-packages directory for a venv
pub fn getSitePackagesDir(allocator: std.mem.Allocator, venv_path: []const u8, python_version: []const u8) ![]const u8 {
    // Extract major.minor version
    var parts = std.mem.splitScalar(u8, python_version, '.');
    const major = parts.next() orelse "3";
    const minor = parts.next() orelse "12";

    return try std.fmt.allocPrint(
        allocator,
        "{s}/lib/python{s}.{s}/site-packages",
        .{ venv_path, major, minor },
    );
}

// ============================================================================
// Tests
// ============================================================================

test "getSitePackagesDir - full version" {
    const allocator = std.testing.allocator;
    const path = try getSitePackagesDir(allocator, ".venv", "3.12.1");
    defer allocator.free(path);
    try std.testing.expectEqualStrings(".venv/lib/python3.12/site-packages", path);
}

test "getSitePackagesDir - major.minor only" {
    const allocator = std.testing.allocator;
    const path = try getSitePackagesDir(allocator, "/home/user/myenv", "3.11");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/home/user/myenv/lib/python3.11/site-packages", path);
}

test "getSitePackagesDir - different python versions" {
    const allocator = std.testing.allocator;

    const path39 = try getSitePackagesDir(allocator, ".venv", "3.9.18");
    defer allocator.free(path39);
    try std.testing.expectEqualStrings(".venv/lib/python3.9/site-packages", path39);

    const path313 = try getSitePackagesDir(allocator, ".venv", "3.13.0");
    defer allocator.free(path313);
    try std.testing.expectEqualStrings(".venv/lib/python3.13/site-packages", path313);
}
