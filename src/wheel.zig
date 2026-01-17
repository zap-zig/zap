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
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "tar", "-xzf", sdist_path, "-C", dest_dir },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            std.debug.print("Error extracting sdist:\n{s}\n", .{result.stderr});
            return error.ExtractionFailed;
        }
    } else if (std.mem.endsWith(u8, sdist_path, ".zip")) {
        try extractWheel(allocator, sdist_path, dest_dir);
    } else {
        return error.UnsupportedFormat;
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

        // Copy everything to site-packages
        const src_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ wheel_extract_dir, entry.name });
        defer allocator.free(src_path);

        const dest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ site_packages, entry.name });
        defer allocator.free(dest_path);

        if (entry.kind == .directory) {
            const result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{ "cp", "-r", src_path, dest_path },
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
        } else if (entry.kind == .file) {
            const result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{ "cp", src_path, dest_path },
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
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
