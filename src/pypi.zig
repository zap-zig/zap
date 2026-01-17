const std = @import("std");
const http = @import("http.zig");

pub const PackageMetadata = struct {
    name: []const u8,
    version: []const u8,
    dependencies: [][]const u8,
    wheel_url: []const u8,
    wheel_filename: []const u8,

    pub fn deinit(self: PackageMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        for (self.dependencies) |dep| {
            allocator.free(dep);
        }
        allocator.free(self.dependencies);
        allocator.free(self.wheel_url);
        allocator.free(self.wheel_filename);
    }
};

/// Fetch package metadata from PyPI JSON API
pub fn fetchPackageMetadata(allocator: std.mem.Allocator, package_name: []const u8, python_version: []const u8) !PackageMetadata {
    // PyPI JSON API: https://pypi.org/pypi/{package}/json
    const url = try std.fmt.allocPrint(allocator, "https://pypi.org/pypi/{s}/json", .{package_name});
    defer allocator.free(url);

    // Fetch using native Zig HTTP client
    const json_str = try http.fetchString(allocator, url);
    defer allocator.free(json_str);

    return try parsePackageMetadata(allocator, json_str, python_version);
}

fn parsePackageMetadata(allocator: std.mem.Allocator, json_str: []const u8, python_version: []const u8) !PackageMetadata {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_str,
        .{},
    );
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidJson;

    const info = root.object.get("info") orelse return error.MissingInfo;
    if (info != .object) return error.InvalidInfo;

    // Get package name and version
    const name_val = info.object.get("name") orelse return error.MissingName;
    const version_val = info.object.get("version") orelse return error.MissingVersion;

    if (name_val != .string or version_val != .string) return error.InvalidData;

    const name = try allocator.dupe(u8, name_val.string);
    errdefer allocator.free(name);

    const version = try allocator.dupe(u8, version_val.string);
    errdefer allocator.free(version);

    // Parse dependencies
    var dependencies: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (dependencies.items) |dep| allocator.free(dep);
        dependencies.deinit(allocator);
    }

    if (info.object.get("requires_dist")) |requires_dist_val| {
        if (requires_dist_val == .array) {
            for (requires_dist_val.array.items) |dep_val| {
                if (dep_val != .string) continue;
                const dep_str = dep_val.string;

                // Parse dependency: "package-name (>=1.0.0)" or "package-name>=1.0.0" -> "package-name"
                var dep_name = dep_str;

                // Handle conditional dependencies (skip extras and environment markers)
                if (std.mem.indexOf(u8, dep_str, ";")) |semi_idx| {
                    dep_name = dep_str[0..semi_idx];
                }

                // Remove spaces and version specifiers
                if (std.mem.indexOf(u8, dep_name, " ")) |space_idx| {
                    dep_name = dep_name[0..space_idx];
                }

                // Remove version specifiers directly attached (no space)
                const operators = [_][]const u8{ ">=", "<=", "==", "~=", ">", "<", "!=", "[" };
                for (operators) |op| {
                    if (std.mem.indexOf(u8, dep_name, op)) |op_idx| {
                        dep_name = dep_name[0..op_idx];
                        break;
                    }
                }

                const cleaned = std.mem.trim(u8, dep_name, &std.ascii.whitespace);
                if (cleaned.len > 0) {
                    try dependencies.append(allocator, try allocator.dupe(u8, cleaned));
                }
            }
        }
    }

    // Find compatible wheel
    const urls = root.object.get("urls") orelse return error.MissingUrls;
    if (urls != .array) return error.InvalidUrls;

    var wheel_url: ?[]const u8 = null;
    var wheel_filename: ?[]const u8 = null;

    // Extract major.minor from python_version (e.g., "3.12.12" -> "3.12")
    const py_major_minor = blk: {
        var parts = std.mem.splitScalar(u8, python_version, '.');
        const major = parts.next() orelse break :blk "3";
        const minor = parts.next() orelse break :blk "3.12";
        break :blk try std.fmt.allocPrint(allocator, "{s}.{s}", .{ major, minor });
    };
    defer allocator.free(py_major_minor);

    // Try to find a compatible wheel (cp312, cp311, cp310, py3, or universal)
    for (urls.array.items) |url_item| {
        if (url_item != .object) continue;

        const packagetype = url_item.object.get("packagetype") orelse continue;
        if (packagetype != .string) continue;

        if (std.mem.eql(u8, packagetype.string, "bdist_wheel")) {
            const filename_val = url_item.object.get("filename") orelse continue;
            const url_val = url_item.object.get("url") orelse continue;

            if (filename_val != .string or url_val != .string) continue;

            const filename = filename_val.string;

            // Check if wheel is compatible
            const py_tag = try std.fmt.allocPrint(allocator, "cp{s}{s}", .{
                py_major_minor[0..1],
                py_major_minor[2..],
            });
            defer allocator.free(py_tag);

            if (std.mem.indexOf(u8, filename, py_tag) != null or
                std.mem.indexOf(u8, filename, "py3") != null or
                std.mem.indexOf(u8, filename, "py2.py3") != null or
                std.mem.indexOf(u8, filename, "none-any") != null)
            {
                wheel_url = try allocator.dupe(u8, url_val.string);
                wheel_filename = try allocator.dupe(u8, filename);
                break;
            }
        }
    }

    // If no wheel found, try to find sdist
    if (wheel_url == null) {
        for (urls.array.items) |url_item| {
            if (url_item != .object) continue;

            const packagetype = url_item.object.get("packagetype") orelse continue;
            if (packagetype != .string) continue;

            if (std.mem.eql(u8, packagetype.string, "sdist")) {
                const filename_val = url_item.object.get("filename") orelse continue;
                const url_val = url_item.object.get("url") orelse continue;

                if (filename_val != .string or url_val != .string) continue;

                wheel_url = try allocator.dupe(u8, url_val.string);
                wheel_filename = try allocator.dupe(u8, filename_val.string);
                break;
            }
        }
    }

    if (wheel_url == null) {
        std.debug.print("No compatible wheel or sdist found for {s}\n", .{name});
        return error.NoCompatibleWheel;
    }

    return PackageMetadata{
        .name = name,
        .version = version,
        .dependencies = try dependencies.toOwnedSlice(allocator),
        .wheel_url = wheel_url.?,
        .wheel_filename = wheel_filename.?,
    };
}

/// Download a file from URL (delegates to native HTTP module)
pub fn downloadFile(allocator: std.mem.Allocator, url: []const u8, output_path: []const u8) !void {
    try http.downloadFile(allocator, url, output_path);
}
