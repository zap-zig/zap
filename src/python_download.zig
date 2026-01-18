const std = @import("std");
const http = @import("http.zig");
const builtin = @import("builtin");

/// Python version info
pub const PythonVersion = struct {
    major: u8,
    minor: u8,
    patch: u8,

    pub fn format(self: PythonVersion, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
    }

    pub fn parse(version_str: []const u8) !PythonVersion {
        var parts = std.mem.splitScalar(u8, version_str, '.');
        const major_str = parts.next() orelse return error.InvalidVersion;
        const minor_str = parts.next() orelse return error.InvalidVersion;
        const patch_str = parts.next() orelse "0";

        return PythonVersion{
            .major = std.fmt.parseInt(u8, major_str, 10) catch return error.InvalidVersion,
            .minor = std.fmt.parseInt(u8, minor_str, 10) catch return error.InvalidVersion,
            .patch = std.fmt.parseInt(u8, patch_str, 10) catch 0,
        };
    }
};

/// Platform detection
pub const Platform = struct {
    arch: []const u8,
    os: []const u8,
    variant: []const u8,

    pub fn detect() Platform {
        const arch = switch (builtin.cpu.arch) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            .arm => "armv7",
            else => "unknown",
        };

        const os_info = switch (builtin.os.tag) {
            .linux => .{ .os = "unknown-linux", .variant = "gnu" },
            .macos => .{ .os = "apple", .variant = "darwin" },
            .windows => .{ .os = "pc-windows", .variant = "msvc" },
            else => .{ .os = "unknown", .variant = "unknown" },
        };

        return Platform{
            .arch = arch,
            .os = os_info.os,
            .variant = os_info.variant,
        };
    }

    /// Format as target triple for python-build-standalone
    /// e.g., "x86_64-unknown-linux-gnu" or "aarch64-apple-darwin"
    pub fn formatTriple(self: Platform, allocator: std.mem.Allocator) ![]const u8 {
        if (std.mem.eql(u8, self.os, "apple")) {
            // macOS: aarch64-apple-darwin
            return try std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ self.arch, self.os, self.variant });
        } else if (std.mem.eql(u8, self.os, "pc-windows")) {
            // Windows: x86_64-pc-windows-msvc
            return try std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ self.arch, self.os, self.variant });
        } else {
            // Linux: x86_64-unknown-linux-gnu
            return try std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ self.arch, self.os, self.variant });
        }
    }
};

/// Python release info
pub const PythonRelease = struct {
    version: []const u8,
    release_date: []const u8,
};

/// Available Python versions with their release dates
/// These are the latest patch versions for each minor release
const PYTHON_RELEASES = [_]PythonRelease{
    // Python 3.13
    .{ .version = "3.13.1", .release_date = "20241206" },
    .{ .version = "3.13.0", .release_date = "20241016" },

    // Python 3.12
    .{ .version = "3.12.8", .release_date = "20241206" },
    .{ .version = "3.12.7", .release_date = "20241016" },
    .{ .version = "3.12.6", .release_date = "20240909" },

    // Python 3.11
    .{ .version = "3.11.11", .release_date = "20241206" },
    .{ .version = "3.11.10", .release_date = "20240909" },
    .{ .version = "3.11.9", .release_date = "20240415" },

    // Python 3.10
    .{ .version = "3.10.16", .release_date = "20241206" },
    .{ .version = "3.10.15", .release_date = "20240909" },
    .{ .version = "3.10.14", .release_date = "20240415" },

    // Python 3.9
    .{ .version = "3.9.21", .release_date = "20241206" },
    .{ .version = "3.9.20", .release_date = "20240909" },
    .{ .version = "3.9.19", .release_date = "20240415" },

    // Python 3.8 (Последние доступные сборки)
    .{ .version = "3.8.20", .release_date = "20240909" },
    .{ .version = "3.8.19", .release_date = "20240415" },
};

/// Get the zap Python installation directory
pub fn getZapPythonDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    return try std.fmt.allocPrint(allocator, "{s}/.zap/python", .{home});
}

/// Get the path to a specific Python version
pub fn getPythonPath(allocator: std.mem.Allocator, version: []const u8) ![]const u8 {
    const base_dir = try getZapPythonDir(allocator);
    defer allocator.free(base_dir);
    return try std.fmt.allocPrint(allocator, "{s}/{s}/bin/python3", .{ base_dir, version });
}

/// Check if a Python version is already installed
pub fn isInstalled(allocator: std.mem.Allocator, version: []const u8) !bool {
    const python_path = try getPythonPath(allocator, version);
    defer allocator.free(python_path);

    std.fs.cwd().access(python_path, .{}) catch return false;
    return true;
}

/// Find the release date for a given Python version
fn findReleaseDate(version: []const u8) ?[]const u8 {
    // Extract major.minor from the requested version
    var parts = std.mem.splitScalar(u8, version, '.');
    const major = parts.next() orelse return null;
    const minor = parts.next() orelse return null;

    // Find matching release
    for (PYTHON_RELEASES) |release| {
        var release_parts = std.mem.splitScalar(u8, release.version, '.');
        const rel_major = release_parts.next() orelse continue;
        const rel_minor = release_parts.next() orelse continue;

        if (std.mem.eql(u8, major, rel_major) and std.mem.eql(u8, minor, rel_minor)) {
            return release.release_date;
        }
    }

    return null;
}

/// Get the full version string for a minor version request
fn getFullVersion(requested: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, requested, '.');
    const major = parts.next() orelse return null;
    const minor = parts.next() orelse return null;

    for (PYTHON_RELEASES) |release| {
        var release_parts = std.mem.splitScalar(u8, release.version, '.');
        const rel_major = release_parts.next() orelse continue;
        const rel_minor = release_parts.next() orelse continue;

        if (std.mem.eql(u8, major, rel_major) and std.mem.eql(u8, minor, rel_minor)) {
            return release.version;
        }
    }

    return null;
}

/// Build the download URL for a Python version
pub fn buildDownloadUrl(allocator: std.mem.Allocator, version: []const u8) ![]const u8 {
    const platform = Platform.detect();
    const triple = try platform.formatTriple(allocator);
    defer allocator.free(triple);

    // Get the full version and release date
    const full_version = getFullVersion(version) orelse version;
    const release_date = findReleaseDate(version) orelse "20250114"; // fallback to recent

    // URL format: cpython-{version}+{date}-{triple}-install_only.tar.gz
    return try std.fmt.allocPrint(
        allocator,
        "https://github.com/astral-sh/python-build-standalone/releases/download/{s}/cpython-{s}+{s}-{s}-install_only.tar.gz",
        .{ release_date, full_version, release_date, triple },
    );
}

/// Download and install a Python version
pub fn installPython(allocator: std.mem.Allocator, version: []const u8) !void {
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    // Check if already installed
    if (try isInstalled(allocator, version)) {
        try stdout.print("Python {s} is already installed\n", .{version});
        try stdout.flush();
        return;
    }

    // Get the full version
    const full_version = getFullVersion(version) orelse version;

    try stdout.print("Installing Python {s}...\n", .{full_version});
    try stdout.flush();

    // Build download URL
    const url = try buildDownloadUrl(allocator, version);
    defer allocator.free(url);

    try stdout.print("  Downloading from python-build-standalone...\n", .{});
    try stdout.flush();

    // Create temp file for download
    var rand_buf: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);
    const rand_val = std.mem.readInt(u64, &rand_buf, .little);
    const temp_path = try std.fmt.allocPrint(allocator, "/tmp/.zap_python_{d}.tar.gz", .{rand_val});
    defer allocator.free(temp_path);
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    // Download the tarball
    try http.downloadFile(allocator, url, temp_path);

    try stdout.writeAll("  Extracting...\n");
    try stdout.flush();

    // Create installation directory
    const base_dir = try getZapPythonDir(allocator);
    defer allocator.free(base_dir);

    const install_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, full_version });
    defer allocator.free(install_dir);

    // Remove existing installation if present
    std.fs.cwd().deleteTree(install_dir) catch {};

    // Create parent directories
    try std.fs.cwd().makePath(base_dir);

    // Extract tarball using tar command (the archive contains a 'python' directory)
    const extract_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "tar",
            "-xzf",
            temp_path,
            "-C",
            base_dir,
        },
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(extract_result.stdout);
    defer allocator.free(extract_result.stderr);

    if (extract_result.term.Exited != 0) {
        std.debug.print("Error extracting Python: {s}\n", .{extract_result.stderr});
        return error.ExtractionFailed;
    }

    // The archive extracts to a 'python' directory, rename it to the version
    const extracted_dir = try std.fmt.allocPrint(allocator, "{s}/python", .{base_dir});
    defer allocator.free(extracted_dir);

    std.fs.cwd().rename(extracted_dir, install_dir) catch |err| {
        // If rename fails, it might already be named correctly
        if (err != error.FileNotFound) {
            std.debug.print("Warning: Could not rename extracted directory: {}\n", .{err});
        }
    };

    try stdout.print("  Python {s} installed to {s}\n", .{ full_version, install_dir });
    try stdout.flush();

    // Verify installation
    const python_path = try getPythonPath(allocator, full_version);
    defer allocator.free(python_path);

    const verify_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ python_path, "--version" },
        .max_output_bytes = 1024,
    });
    defer allocator.free(verify_result.stdout);
    defer allocator.free(verify_result.stderr);

    if (verify_result.term.Exited == 0) {
        const version_output = std.mem.trim(u8, verify_result.stdout, &std.ascii.whitespace);
        try stdout.print("  Verified: {s}\n", .{version_output});
        try stdout.flush();
    }
}

/// List installed Python versions
pub fn listInstalled(allocator: std.mem.Allocator) ![][]const u8 {
    const base_dir = try getZapPythonDir(allocator);
    defer allocator.free(base_dir);

    var versions: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (versions.items) |v| allocator.free(v);
        versions.deinit(allocator);
    }

    var dir = std.fs.cwd().openDir(base_dir, .{ .iterate = true }) catch {
        return try versions.toOwnedSlice(allocator);
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            // Check if it looks like a version directory (starts with 3.)
            if (std.mem.startsWith(u8, entry.name, "3.")) {
                try versions.append(allocator, try allocator.dupe(u8, entry.name));
            }
        }
    }

    return try versions.toOwnedSlice(allocator);
}

/// List available Python versions for download
pub fn listAvailable() []const PythonRelease {
    return &PYTHON_RELEASES;
}

/// Find the best matching installed Python for a version request
/// e.g., "3.12" might match "3.12.8"
pub fn findInstalledMatch(allocator: std.mem.Allocator, requested: []const u8) !?[]const u8 {
    const installed = try listInstalled(allocator);
    defer {
        for (installed) |v| allocator.free(v);
        allocator.free(installed);
    }

    // Parse requested version
    var req_parts = std.mem.splitScalar(u8, requested, '.');
    const req_major = req_parts.next() orelse return null;
    const req_minor = req_parts.next() orelse return null;
    const req_patch = req_parts.next();

    for (installed) |version| {
        var parts = std.mem.splitScalar(u8, version, '.');
        const major = parts.next() orelse continue;
        const minor = parts.next() orelse continue;
        const patch = parts.next();

        if (std.mem.eql(u8, major, req_major) and std.mem.eql(u8, minor, req_minor)) {
            // If patch was requested, it must match
            if (req_patch) |rp| {
                if (patch) |p| {
                    if (!std.mem.eql(u8, p, rp)) continue;
                }
            }
            return try allocator.dupe(u8, version);
        }
    }

    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "PythonVersion.parse" {
    const v = try PythonVersion.parse("3.12.8");
    try std.testing.expectEqual(@as(u8, 3), v.major);
    try std.testing.expectEqual(@as(u8, 12), v.minor);
    try std.testing.expectEqual(@as(u8, 8), v.patch);
}

test "PythonVersion.parse - minor only" {
    const v = try PythonVersion.parse("3.12");
    try std.testing.expectEqual(@as(u8, 3), v.major);
    try std.testing.expectEqual(@as(u8, 12), v.minor);
    try std.testing.expectEqual(@as(u8, 0), v.patch);
}

test "Platform.detect" {
    const platform = Platform.detect();
    // Just verify it doesn't crash and returns something
    try std.testing.expect(platform.arch.len > 0);
    try std.testing.expect(platform.os.len > 0);
}

test "buildDownloadUrl" {
    const allocator = std.testing.allocator;
    const url = try buildDownloadUrl(allocator, "3.12");
    defer allocator.free(url);

    try std.testing.expect(std.mem.indexOf(u8, url, "python-build-standalone") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "cpython-3.12") != null);
    try std.testing.expect(std.mem.endsWith(u8, url, ".tar.gz"));
}
