const std = @import("std");

/// Global package cache manager
/// Cache location: ~/.cache/zap/
pub const Cache = struct {
    allocator: std.mem.Allocator,
    cache_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator) !Cache {
        // Get home directory
        const home = std.posix.getenv("HOME") orelse "/tmp";
        const cache_dir = try std.fmt.allocPrint(allocator, "{s}/.cache/zap", .{home});

        // Create cache directories
        std.fs.cwd().makePath(cache_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const wheels_dir = try std.fmt.allocPrint(allocator, "{s}/wheels", .{cache_dir});
        defer allocator.free(wheels_dir);
        std.fs.cwd().makePath(wheels_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        return Cache{
            .allocator = allocator,
            .cache_dir = cache_dir,
        };
    }

    pub fn deinit(self: *Cache) void {
        self.allocator.free(self.cache_dir);
    }

    /// Get path for cached wheel file
    pub fn getWheelPath(self: *Cache, package_name: []const u8, version: []const u8, filename: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(
            self.allocator,
            "{s}/wheels/{s}-{s}/{s}",
            .{ self.cache_dir, package_name, version, filename },
        );
    }

    /// Check if wheel is cached
    pub fn hasWheel(self: *Cache, package_name: []const u8, version: []const u8, filename: []const u8) !bool {
        const path = try self.getWheelPath(package_name, version, filename);
        defer self.allocator.free(path);

        std.fs.cwd().access(path, .{}) catch |err| {
            if (err == error.FileNotFound) return false;
            return err;
        };
        return true;
    }

    /// Get cache directory for a package version
    pub fn getPackageDir(self: *Cache, package_name: []const u8, version: []const u8) ![]const u8 {
        const dir = try std.fmt.allocPrint(
            self.allocator,
            "{s}/wheels/{s}-{s}",
            .{ self.cache_dir, package_name, version },
        );

        // Create if doesn't exist
        std.fs.cwd().makePath(dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                self.allocator.free(dir);
                return err;
            }
        };

        return dir;
    }

    /// Clean entire cache
    pub fn clean(self: *Cache) !void {
        std.fs.cwd().deleteTree(self.cache_dir) catch |err| {
            if (err != error.FileNotFound) return err;
        };
    }

    /// Get cache size in bytes
    pub fn getSize(self: *Cache) !u64 {
        var total: u64 = 0;

        var dir = std.fs.cwd().openDir(self.cache_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return 0;
            return err;
        };
        defer dir.close();

        var walker = dir.walk(self.allocator) catch return 0;
        defer walker.deinit();

        while (walker.next() catch null) |entry| {
            if (entry.kind == .file) {
                const stat = dir.statFile(entry.path) catch continue;
                total += stat.size;
            }
        }

        return total;
    }
};

/// Track installed packages to avoid version conflicts
pub const InstalledPackages = struct {
    allocator: std.mem.Allocator,
    packages: std.StringHashMap([]const u8), // name -> version

    pub fn init(allocator: std.mem.Allocator) InstalledPackages {
        return InstalledPackages{
            .allocator = allocator,
            .packages = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *InstalledPackages) void {
        var it = self.packages.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.packages.deinit();
    }

    /// Check if package is already installed
    pub fn isInstalled(self: *InstalledPackages, name: []const u8) bool {
        return self.packages.contains(name);
    }

    /// Get installed version
    pub fn getVersion(self: *InstalledPackages, name: []const u8) ?[]const u8 {
        return self.packages.get(name);
    }

    /// Mark package as installed
    pub fn markInstalled(self: *InstalledPackages, name: []const u8, version: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const version_copy = try self.allocator.dupe(u8, version);
        errdefer self.allocator.free(version_copy);

        // If already exists, free old values
        if (self.packages.fetchRemove(name_copy)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }

        try self.packages.put(name_copy, version_copy);
    }

    /// Load from site-packages directory
    pub fn loadFromSitePackages(self: *InstalledPackages, site_packages: []const u8) !void {
        var dir = std.fs.cwd().openDir(site_packages, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".dist-info")) {
                // Parse: package_name-version.dist-info
                // First strip .dist-info suffix, then find last hyphen
                const base_name = entry.name[0 .. entry.name.len - ".dist-info".len];

                if (std.mem.lastIndexOf(u8, base_name, "-")) |dash_idx| {
                    const name = base_name[0..dash_idx];
                    const version = base_name[dash_idx + 1 ..];
                    try self.markInstalled(name, version);
                }
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "InstalledPackages - init and deinit" {
    const allocator = std.testing.allocator;
    var installed = InstalledPackages.init(allocator);
    defer installed.deinit();

    try std.testing.expect(!installed.isInstalled("requests"));
}

test "InstalledPackages - markInstalled and isInstalled" {
    const allocator = std.testing.allocator;
    var installed = InstalledPackages.init(allocator);
    defer installed.deinit();

    try installed.markInstalled("requests", "2.31.0");

    try std.testing.expect(installed.isInstalled("requests"));
    try std.testing.expect(!installed.isInstalled("flask"));
}

test "InstalledPackages - getVersion" {
    const allocator = std.testing.allocator;
    var installed = InstalledPackages.init(allocator);
    defer installed.deinit();

    try installed.markInstalled("numpy", "1.24.0");

    const version = installed.getVersion("numpy");
    try std.testing.expect(version != null);
    try std.testing.expectEqualStrings("1.24.0", version.?);

    try std.testing.expect(installed.getVersion("pandas") == null);
}

test "InstalledPackages - update existing package" {
    const allocator = std.testing.allocator;
    var installed = InstalledPackages.init(allocator);
    defer installed.deinit();

    try installed.markInstalled("flask", "2.0.0");
    try std.testing.expectEqualStrings("2.0.0", installed.getVersion("flask").?);

    try installed.markInstalled("flask", "3.0.0");
    try std.testing.expectEqualStrings("3.0.0", installed.getVersion("flask").?);
}

test "InstalledPackages - multiple packages" {
    const allocator = std.testing.allocator;
    var installed = InstalledPackages.init(allocator);
    defer installed.deinit();

    try installed.markInstalled("requests", "2.31.0");
    try installed.markInstalled("flask", "3.0.0");
    try installed.markInstalled("django", "4.2.0");

    try std.testing.expect(installed.isInstalled("requests"));
    try std.testing.expect(installed.isInstalled("flask"));
    try std.testing.expect(installed.isInstalled("django"));
    try std.testing.expect(!installed.isInstalled("fastapi"));
}
