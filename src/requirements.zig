const std = @import("std");

/// Parse a requirements.txt file and return list of dependencies
pub fn parseRequirementsFile(allocator: std.mem.Allocator, file_path: []const u8) ![][]const u8 {
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return &[_][]const u8{};
        }
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    return try parseRequirementsContent(allocator, content);
}

/// Parse requirements.txt content string
pub fn parseRequirementsContent(allocator: std.mem.Allocator, content: []const u8) ![][]const u8 {
    var deps: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (deps.items) |d| allocator.free(d);
        deps.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const dep = try parseLine(allocator, line);
        if (dep) |d| {
            try deps.append(allocator, d);
        }
    }

    return try deps.toOwnedSlice(allocator);
}

/// Parse a single line from requirements.txt
fn parseLine(allocator: std.mem.Allocator, line: []const u8) !?[]const u8 {
    var trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

    // Skip empty lines
    if (trimmed.len == 0) return null;

    // Skip comments
    if (trimmed[0] == '#') return null;

    // Handle inline comments: package>=1.0  # comment
    if (std.mem.indexOf(u8, trimmed, " #")) |idx| {
        trimmed = std.mem.trim(u8, trimmed[0..idx], &std.ascii.whitespace);
    }

    // Skip -r, -e, -i, -f, --index-url, etc. options
    if (trimmed[0] == '-') return null;

    // Handle environment markers: package>=1.0; python_version >= "3.8"
    // For now, strip the marker and just return the package spec
    if (std.mem.indexOf(u8, trimmed, ";")) |idx| {
        trimmed = std.mem.trim(u8, trimmed[0..idx], &std.ascii.whitespace);
    }

    // Handle git URLs
    if (std.mem.startsWith(u8, trimmed, "git+") or
        std.mem.startsWith(u8, trimmed, "git://") or
        std.mem.indexOf(u8, trimmed, "@ git+") != null)
    {
        return try allocator.dupe(u8, trimmed);
    }

    // Handle URL-based installs: package @ https://...
    if (std.mem.indexOf(u8, trimmed, " @ ")) |_| {
        return try allocator.dupe(u8, trimmed);
    }

    // Handle direct URLs: https://example.com/package.whl
    if (std.mem.startsWith(u8, trimmed, "http://") or
        std.mem.startsWith(u8, trimmed, "https://"))
    {
        return try allocator.dupe(u8, trimmed);
    }

    // Regular package spec: package, package>=1.0, package[extra]>=1.0
    if (trimmed.len > 0) {
        return try allocator.dupe(u8, trimmed);
    }

    return null;
}

/// Extract just the package name from a requirement spec
/// "requests>=2.28.0" -> "requests"
/// "package[extra]>=1.0" -> "package"
pub fn extractPackageName(allocator: std.mem.Allocator, req: []const u8) ![]const u8 {
    var name = req;

    // Handle git URLs - extract from "pkg @ git+..." or "git+.../repo.git"
    if (std.mem.indexOf(u8, name, "@ git+")) |idx| {
        name = std.mem.trim(u8, name[0..idx], &std.ascii.whitespace);
        return try allocator.dupe(u8, name);
    }

    // For bare git URLs, extract repo name
    if (std.mem.startsWith(u8, name, "git+")) {
        // git+https://github.com/user/repo.git -> repo
        if (std.mem.lastIndexOf(u8, name, "/")) |idx| {
            var repo_name = name[idx + 1 ..];
            if (std.mem.endsWith(u8, repo_name, ".git")) {
                repo_name = repo_name[0 .. repo_name.len - 4];
            }
            return try allocator.dupe(u8, repo_name);
        }
    }

    // Handle extras: package[extra] -> package
    if (std.mem.indexOf(u8, name, "[")) |idx| {
        name = name[0..idx];
    }

    // Handle version specifiers
    // Also handle comma-separated constraints like "pluggy<2,>=1.5"
    // Find the earliest operator position (not just first match in list)
    const operators = [_][]const u8{ ">=", "<=", "==", "~=", "!=", ">", "<", "@", "," };
    var earliest_pos: ?usize = null;
    for (operators) |op| {
        if (std.mem.indexOf(u8, name, op)) |idx| {
            if (earliest_pos == null or idx < earliest_pos.?) {
                earliest_pos = idx;
            }
        }
    }
    if (earliest_pos) |pos| {
        name = name[0..pos];
    }

    name = std.mem.trim(u8, name, &std.ascii.whitespace);
    return try allocator.dupe(u8, name);
}

// ============================================================================
// Tests
// ============================================================================

test "parseLine - simple package" {
    const allocator = std.testing.allocator;
    const result = try parseLine(allocator, "requests");
    defer if (result) |r| allocator.free(r);
    try std.testing.expectEqualStrings("requests", result.?);
}

test "parseLine - package with version" {
    const allocator = std.testing.allocator;
    const result = try parseLine(allocator, "requests>=2.28.0");
    defer if (result) |r| allocator.free(r);
    try std.testing.expectEqualStrings("requests>=2.28.0", result.?);
}

test "parseLine - skip comment" {
    const allocator = std.testing.allocator;
    const result = try parseLine(allocator, "# this is a comment");
    try std.testing.expect(result == null);
}

test "parseLine - skip empty" {
    const allocator = std.testing.allocator;
    const result = try parseLine(allocator, "   ");
    try std.testing.expect(result == null);
}

test "parseLine - inline comment" {
    const allocator = std.testing.allocator;
    const result = try parseLine(allocator, "requests>=2.0  # http library");
    defer if (result) |r| allocator.free(r);
    try std.testing.expectEqualStrings("requests>=2.0", result.?);
}

test "parseLine - skip options" {
    const allocator = std.testing.allocator;
    try std.testing.expect((try parseLine(allocator, "-r other.txt")) == null);
    try std.testing.expect((try parseLine(allocator, "-e .")) == null);
    try std.testing.expect((try parseLine(allocator, "--index-url https://pypi.org/simple")) == null);
}

test "parseLine - environment marker" {
    const allocator = std.testing.allocator;
    const result = try parseLine(allocator, "pywin32; sys_platform == 'win32'");
    defer if (result) |r| allocator.free(r);
    try std.testing.expectEqualStrings("pywin32", result.?);
}

test "parseLine - git URL" {
    const allocator = std.testing.allocator;
    const result = try parseLine(allocator, "git+https://github.com/user/repo.git");
    defer if (result) |r| allocator.free(r);
    try std.testing.expectEqualStrings("git+https://github.com/user/repo.git", result.?);
}

test "parseRequirementsContent - multiple packages" {
    const allocator = std.testing.allocator;
    const content =
        \\# Requirements
        \\requests>=2.28.0
        \\numpy
        \\
        \\# Development
        \\pytest>=7.0
    ;

    const deps = try parseRequirementsContent(allocator, content);
    defer {
        for (deps) |d| allocator.free(d);
        allocator.free(deps);
    }

    try std.testing.expectEqual(@as(usize, 3), deps.len);
    try std.testing.expectEqualStrings("requests>=2.28.0", deps[0]);
    try std.testing.expectEqualStrings("numpy", deps[1]);
    try std.testing.expectEqualStrings("pytest>=7.0", deps[2]);
}

test "extractPackageName - simple" {
    const allocator = std.testing.allocator;
    const name = try extractPackageName(allocator, "requests");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("requests", name);
}

test "extractPackageName - with version" {
    const allocator = std.testing.allocator;
    const name = try extractPackageName(allocator, "requests>=2.28.0");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("requests", name);
}

test "extractPackageName - with extras" {
    const allocator = std.testing.allocator;
    const name = try extractPackageName(allocator, "requests[security]>=2.0");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("requests", name);
}

test "extractPackageName - git URL" {
    const allocator = std.testing.allocator;
    const name = try extractPackageName(allocator, "mypackage @ git+https://github.com/user/repo");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("mypackage", name);
}

test "extractPackageName - comma separated constraints" {
    const allocator = std.testing.allocator;
    // This is the real-world case: pluggy<2,>=1.5 should extract "pluggy"
    const name = try extractPackageName(allocator, "pluggy<2,>=1.5");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("pluggy", name);
}

test "extractPackageName - multiple constraints with != first" {
    const allocator = std.testing.allocator;
    // pytest!=8.1.*,>=7.0 should extract "pytest"
    const name = try extractPackageName(allocator, "pytest!=8.1.*,>=7.0");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("pytest", name);
}
