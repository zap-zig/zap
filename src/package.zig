const std = @import("std");
const python = @import("python.zig");
const pypi = @import("pypi.zig");
const wheel = @import("wheel.zig");
const lock = @import("lock.zig");
const cache = @import("cache.zig");
const build = @import("build.zig");

/// Install a Python package directly from PyPI
/// Uses global cache and tracks installed packages to avoid duplicates
pub fn installPackage(allocator: std.mem.Allocator, package_name: []const u8) !void {
    // Use internal function with shared state
    var installed = cache.InstalledPackages.init(allocator);
    defer installed.deinit();

    var pkg_cache = try cache.Cache.init(allocator);
    defer pkg_cache.deinit();

    // Get Python version and site-packages path
    const lock_file = try lock.readLockFile(allocator);
    defer lock_file.deinit(allocator);

    const site_packages = try wheel.getSitePackagesDir(allocator, ".venv", lock_file.python_version);
    defer allocator.free(site_packages);

    // Load already-installed packages
    try installed.loadFromSitePackages(site_packages);

    try installPackageInternal(allocator, package_name, &installed, &pkg_cache, lock_file.python_version, site_packages);
}

/// Internal install function that tracks installed packages to avoid duplicates
fn installPackageInternal(
    allocator: std.mem.Allocator,
    package_name: []const u8,
    installed: *cache.InstalledPackages,
    pkg_cache: *cache.Cache,
    python_version: []const u8,
    site_packages: []const u8,
) !void {
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    // Normalize package name (PyPI uses lowercase with hyphens)
    var normalized_name: [256]u8 = undefined;
    const norm_len = @min(package_name.len, 255);
    for (0..norm_len) |i| {
        const c = package_name[i];
        normalized_name[i] = if (c == '_') '-' else std.ascii.toLower(c);
    }
    const norm_name = normalized_name[0..norm_len];

    // Check if already installed in this session
    if (installed.isInstalled(norm_name)) {
        try stdout.print("  Skipping {s} (already installed)\n", .{norm_name});
        try stdout.flush();
        return;
    }

    // Fetch package metadata from PyPI
    try stdout.print("  Fetching metadata for {s}...\n", .{package_name});
    try stdout.flush();

    const metadata = try pypi.fetchPackageMetadata(allocator, package_name, python_version);
    defer metadata.deinit(allocator);

    try stdout.print("  Found {s} {s}\n", .{ metadata.name, metadata.version });
    try stdout.flush();

    // Mark as installed early to prevent circular dependencies
    try installed.markInstalled(norm_name, metadata.version);

    // Install dependencies first (recursively)
    for (metadata.dependencies) |dep| {
        try stdout.print("  Installing dependency: {s}\n", .{dep});
        try stdout.flush();
        installPackageInternal(allocator, dep, installed, pkg_cache, python_version, site_packages) catch |err| {
            std.debug.print("Warning: Failed to install dependency {s}: {}\n", .{ dep, err });
        };
    }

    // Check global cache for wheel
    const cache_dir = try pkg_cache.getPackageDir(metadata.name, metadata.version);
    defer allocator.free(cache_dir);

    const wheel_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_dir, metadata.wheel_filename });
    defer allocator.free(wheel_path);

    const is_cached = try pkg_cache.hasWheel(metadata.name, metadata.version, metadata.wheel_filename);

    if (is_cached) {
        try stdout.print("  Using cached {s}\n", .{metadata.wheel_filename});
        try stdout.flush();
    } else {
        // Download wheel to global cache
        try stdout.print("  Downloading {s}...\n", .{metadata.wheel_filename});
        try stdout.flush();
        try pypi.downloadFile(allocator, metadata.wheel_url, wheel_path);
    }

    // Extract wheel
    try stdout.print("  Extracting...\n", .{});
    try stdout.flush();

    // Create temp extraction directory in cache (clean it first if exists)
    const extract_dir = try std.fmt.allocPrint(allocator, "{s}/extracted", .{cache_dir});
    defer allocator.free(extract_dir);

    // Remove existing extraction if present
    std.fs.cwd().deleteTree(extract_dir) catch |err| {
        if (err != error.FileNotFound) return err;
    };

    // Determine if this is a wheel or sdist
    const is_wheel = std.mem.endsWith(u8, metadata.wheel_filename, ".whl");
    const is_sdist = std.mem.endsWith(u8, metadata.wheel_filename, ".tar.gz") or
        std.mem.endsWith(u8, metadata.wheel_filename, ".zip");

    if (is_wheel) {
        // Direct wheel installation
        try wheel.extractWheel(allocator, wheel_path, extract_dir);

        // Install to site-packages
        try stdout.print("  Installing to site-packages...\n", .{});
        try stdout.flush();
        try wheel.installWheelToSitePackages(allocator, extract_dir, site_packages);
    } else if (is_sdist) {
        // Build wheel from sdist, then install
        try stdout.print("  Package only available as sdist, building...\n", .{});
        try stdout.flush();

        // Ensure pip and build deps are available
        try build.ensureBuildDeps(allocator);

        // Build wheel from sdist
        const built_wheel_dir = try std.fmt.allocPrint(allocator, "{s}/built", .{cache_dir});
        defer allocator.free(built_wheel_dir);

        const built_wheel_path = try build.buildSdist(allocator, wheel_path, built_wheel_dir);
        defer allocator.free(built_wheel_path);

        // Extract and install the built wheel
        try wheel.extractWheel(allocator, built_wheel_path, extract_dir);

        try stdout.print("  Installing to site-packages...\n", .{});
        try stdout.flush();
        try wheel.installWheelToSitePackages(allocator, extract_dir, site_packages);
    } else {
        std.debug.print("Error: Unknown package format: {s}\n", .{metadata.wheel_filename});
        return error.UnsupportedFormat;
    }

    try stdout.print("  Installed {s} {s}\n", .{ metadata.name, metadata.version });
    try stdout.flush();
}

/// Remove a Python package
pub fn removePackage(allocator: std.mem.Allocator, package_name: []const u8) !void {
    // Get Python version from lock file
    const lock_file = try lock.readLockFile(allocator);
    defer lock_file.deinit(allocator);

    const site_packages = try wheel.getSitePackagesDir(allocator, ".venv", lock_file.python_version);
    defer allocator.free(site_packages);

    // Remove package directory from site-packages
    const package_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ site_packages, package_name });
    defer allocator.free(package_path);

    std.fs.cwd().deleteTree(package_path) catch |err| {
        if (err != error.FileNotFound) {
            std.debug.print("Error removing package: {}\n", .{err});
            return error.PackageRemoveFailed;
        }
    };

    // Also try to remove .dist-info directory
    var dir = try std.fs.cwd().openDir(site_packages, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, package_name) and
            std.mem.endsWith(u8, entry.name, ".dist-info"))
        {
            const dist_info_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ site_packages, entry.name });
            defer allocator.free(dist_info_path);
            try std.fs.cwd().deleteTree(dist_info_path);
        }
    }
}

/// Get list of installed packages
pub fn getInstalledPackages(allocator: std.mem.Allocator) ![]PackageInfo {
    // Get Python version from lock file
    const lock_file = lock.readLockFile(allocator) catch {
        // If no lock file, return empty list
        return &[_]PackageInfo{};
    };
    defer lock_file.deinit(allocator);

    const site_packages = try wheel.getSitePackagesDir(allocator, ".venv", lock_file.python_version);
    defer allocator.free(site_packages);

    var packages: std.ArrayList(PackageInfo) = .empty;
    errdefer {
        for (packages.items) |p| {
            p.deinit(allocator);
        }
        packages.deinit(allocator);
    }

    // Scan .dist-info directories in site-packages
    var dir = std.fs.cwd().openDir(site_packages, .{ .iterate = true }) catch {
        return &[_]PackageInfo{};
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".dist-info")) {
            // Parse package name and version from dirname
            // Format: package_name-version.dist-info
            // First strip .dist-info suffix, then find last hyphen
            const base_name = entry.name[0 .. entry.name.len - ".dist-info".len];

            if (std.mem.lastIndexOf(u8, base_name, "-")) |dash_idx| {
                const name_part = base_name[0..dash_idx];
                const version_part = base_name[dash_idx + 1 ..];

                try packages.append(allocator, .{
                    .name = try allocator.dupe(u8, name_part),
                    .version = try allocator.dupe(u8, version_part),
                });
            }
        }
    }

    return try packages.toOwnedSlice(allocator);
}

pub const PackageInfo = struct {
    name: []const u8,
    version: []const u8,

    pub fn deinit(self: PackageInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
    }
};
