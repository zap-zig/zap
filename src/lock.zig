const std = @import("std");
const pkg = @import("package.zig");

const LOCK_FILE_NAME = "zap.lock";

pub const LockFile = struct {
    python_version: []const u8,
    packages: []PackageEntry,

    pub const PackageEntry = struct {
        name: []const u8,
        version: []const u8,
    };

    pub fn deinit(self: LockFile, allocator: std.mem.Allocator) void {
        allocator.free(self.python_version);
        for (self.packages) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.version);
        }
        allocator.free(self.packages);
    }
};

/// Initialize a new lock file
pub fn initLockFile(_: std.mem.Allocator, python_version: []const u8) !void {
    const file = try std.fs.cwd().createFile(LOCK_FILE_NAME, .{});
    defer file.close();

    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&buffer);
    const writer = &file_writer.interface;

    // Write header
    try writer.writeAll("# zap.lock - Fast and Safe Python Package Manager\n");
    try writer.writeAll("# This file is auto-generated. Do not edit manually.\n\n");

    // Write Python version
    try writer.print("python = \"{s}\"\n\n", .{python_version});

    // Write packages section
    try writer.writeAll("[[packages]]\n");
    try writer.flush();
}

/// Update lock file with current installed packages
pub fn updateLockFile(allocator: std.mem.Allocator) !void {
    // Get current Python version from existing lock file
    const python_version = try readPythonVersion(allocator);
    defer allocator.free(python_version);

    // Get installed packages
    const packages = try pkg.getInstalledPackages(allocator);
    defer {
        for (packages) |package| {
            package.deinit(allocator);
        }
        allocator.free(packages);
    }

    // Write new lock file
    const file = try std.fs.cwd().createFile(LOCK_FILE_NAME, .{});
    defer file.close();

    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&buffer);
    const writer = &file_writer.interface;

    // Write header
    try writer.writeAll("# zap.lock - Fast and Safe Python Package Manager\n");
    try writer.writeAll("# This file is auto-generated. Do not edit manually.\n\n");

    // Write Python version
    try writer.print("python = \"{s}\"\n\n", .{python_version});

    // Write packages
    for (packages) |package| {
        try writer.writeAll("[[packages]]\n");
        try writer.print("name = \"{s}\"\n", .{package.name});
        try writer.print("version = \"{s}\"\n\n", .{package.version});
    }
    try writer.flush();
}

/// Read Python version from lock file
fn readPythonVersion(allocator: std.mem.Allocator) ![]const u8 {
    const file = try std.fs.cwd().openFile(LOCK_FILE_NAME, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (std.mem.startsWith(u8, trimmed, "python = \"")) {
            const start = "python = \"".len;
            const end = std.mem.indexOf(u8, trimmed[start..], "\"") orelse continue;
            return try allocator.dupe(u8, trimmed[start .. start + end]);
        }
    }

    return error.PythonVersionNotFound;
}

/// Read lock file
pub fn readLockFile(allocator: std.mem.Allocator) !LockFile {
    const file = try std.fs.cwd().openFile(LOCK_FILE_NAME, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var python_version: ?[]const u8 = null;
    var packages: std.ArrayList(LockFile.PackageEntry) = .empty;
    errdefer {
        if (python_version) |pv| allocator.free(pv);
        for (packages.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.version);
        }
        packages.deinit(allocator);
    }

    var current_package_name: ?[]const u8 = null;
    var current_package_version: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

        // Skip comments and empty lines
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Parse Python version
        if (std.mem.startsWith(u8, trimmed, "python = \"")) {
            const start = "python = \"".len;
            const end = std.mem.indexOf(u8, trimmed[start..], "\"") orelse continue;
            python_version = try allocator.dupe(u8, trimmed[start .. start + end]);
            continue;
        }

        // Parse package section
        if (std.mem.eql(u8, trimmed, "[[packages]]")) {
            // Save previous package if exists
            if (current_package_name != null and current_package_version != null) {
                try packages.append(allocator, .{
                    .name = current_package_name.?,
                    .version = current_package_version.?,
                });
                current_package_name = null;
                current_package_version = null;
            }
            continue;
        }

        // Parse package name
        if (std.mem.startsWith(u8, trimmed, "name = \"")) {
            const start = "name = \"".len;
            const end = std.mem.indexOf(u8, trimmed[start..], "\"") orelse continue;
            current_package_name = try allocator.dupe(u8, trimmed[start .. start + end]);
            continue;
        }

        // Parse package version
        if (std.mem.startsWith(u8, trimmed, "version = \"")) {
            const start = "version = \"".len;
            const end = std.mem.indexOf(u8, trimmed[start..], "\"") orelse continue;
            current_package_version = try allocator.dupe(u8, trimmed[start .. start + end]);
            continue;
        }
    }

    // Save last package
    if (current_package_name != null and current_package_version != null) {
        try packages.append(allocator, .{
            .name = current_package_name.?,
            .version = current_package_version.?,
        });
    }

    return LockFile{
        .python_version = python_version orelse return error.PythonVersionNotFound,
        .packages = try packages.toOwnedSlice(allocator),
    };
}
