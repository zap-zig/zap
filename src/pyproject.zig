const std = @import("std");

pub const PyProject = struct {
    name: ?[]const u8,
    version: ?[]const u8,
    dependencies: [][]const u8,
    python_version: ?[]const u8,
    build_type: ?[]const u8,

    pub fn deinit(self: PyProject, allocator: std.mem.Allocator) void {
        if (self.name) |n| allocator.free(n);
        if (self.version) |v| allocator.free(v);
        for (self.dependencies) |dep| {
            allocator.free(dep);
        }
        allocator.free(self.dependencies);
        if (self.python_version) |pv| allocator.free(pv);
        if (self.build_type) |bt| allocator.free(bt);
    }
};

/// Parse pyproject.toml file
pub fn parsePyProject(allocator: std.mem.Allocator, file_path: []const u8) !PyProject {
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            // Return empty project if file doesn't exist
            return PyProject{
                .name = null,
                .version = null,
                .dependencies = &[_][]const u8{},
                .python_version = null,
                .build_type = null,
            };
        }
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    return try parseTomlContent(allocator, content);
}

fn parseTomlContent(allocator: std.mem.Allocator, content: []const u8) !PyProject {
    var name: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var dependencies: std.ArrayList([]const u8) = .empty;
    var python_version: ?[]const u8 = null;
    var build_type: ?[]const u8 = null;

    errdefer {
        if (name) |n| allocator.free(n);
        if (version) |v| allocator.free(v);
        for (dependencies.items) |dep| allocator.free(dep);
        dependencies.deinit(allocator);
        if (python_version) |pv| allocator.free(pv);
        if (build_type) |bt| allocator.free(bt);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    var in_project_section = false;
    var in_dependencies_array = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Check for [project] section
        if (std.mem.eql(u8, trimmed, "[project]")) {
            in_project_section = true;
            in_dependencies_array = false;
            continue;
        }

        // Check for other sections (exit project section)
        if (trimmed[0] == '[' and !in_dependencies_array) {
            in_project_section = false;
            continue;
        }

        if (in_project_section) {
            // Parse name
            if (std.mem.startsWith(u8, trimmed, "name = \"")) {
                const start = "name = \"".len;
                if (std.mem.indexOf(u8, trimmed[start..], "\"")) |end| {
                    name = try allocator.dupe(u8, trimmed[start .. start + end]);
                }
                continue;
            }

            // Parse version
            if (std.mem.startsWith(u8, trimmed, "version = \"")) {
                const start = "version = \"".len;
                if (std.mem.indexOf(u8, trimmed[start..], "\"")) |end| {
                    version = try allocator.dupe(u8, trimmed[start .. start + end]);
                }
                continue;
            }

            // Parse requires-python
            if (std.mem.startsWith(u8, trimmed, "requires-python = \"")) {
                const start = "requires-python = \"".len;
                if (std.mem.indexOf(u8, trimmed[start..], "\"")) |end| {
                    const req = trimmed[start .. start + end];
                    // Extract version from >=3.11 or similar
                    python_version = try parsePythonRequirement(allocator, req);
                }
                continue;
            }

            // Parse build_type
            if (std.mem.startsWith(u8, trimmed, "build_type = \"")) {
                const start = "build_type = \"".len;
                if (std.mem.indexOf(u8, trimmed[start..], "\"")) |end| {
                    build_type = try allocator.dupe(u8, trimmed[start .. start + end]);
                }
                continue;
            }

            // Parse dependencies array start
            if (std.mem.eql(u8, trimmed, "dependencies = [")) {
                in_dependencies_array = true;
                continue;
            }

            // Parse single-line dependencies
            if (std.mem.startsWith(u8, trimmed, "dependencies = [") and std.mem.endsWith(u8, trimmed, "]")) {
                // Single line: dependencies = ["package1", "package2"]
                const start = "dependencies = [".len;
                const end = trimmed.len - 1;
                const deps_str = trimmed[start..end];
                try parseInlineDependencies(allocator, &dependencies, deps_str);
                continue;
            }
        }

        // Parse multi-line dependencies
        if (in_dependencies_array) {
            if (std.mem.eql(u8, trimmed, "]")) {
                in_dependencies_array = false;
                continue;
            }

            // Parse dependency line: "package>=1.0.0",
            if (trimmed[0] == '"') {
                var dep_str = trimmed;
                // Remove leading quote
                if (dep_str.len > 0 and dep_str[0] == '"') dep_str = dep_str[1..];
                // Remove trailing quote and comma
                while (dep_str.len > 0 and (dep_str[dep_str.len - 1] == '"' or
                    dep_str[dep_str.len - 1] == ',' or
                    std.ascii.isWhitespace(dep_str[dep_str.len - 1])))
                {
                    dep_str = dep_str[0 .. dep_str.len - 1];
                }

                if (dep_str.len > 0) {
                    // Extract package name (before version specifier)
                    const package_name = try extractPackageName(allocator, dep_str);
                    try dependencies.append(allocator, package_name);
                }
            }
        }
    }

    return PyProject{
        .name = name,
        .version = version,
        .dependencies = try dependencies.toOwnedSlice(allocator),
        .python_version = python_version,
        .build_type = build_type,
    };
}

fn parsePythonRequirement(allocator: std.mem.Allocator, requirement: []const u8) ![]const u8 {
    // Parse >=3.11 -> 3.11, ==3.10 -> 3.10, etc.
    var req = requirement;

    // Remove operators
    if (std.mem.startsWith(u8, req, ">=")) {
        req = req[2..];
    } else if (std.mem.startsWith(u8, req, "==")) {
        req = req[2..];
    } else if (std.mem.startsWith(u8, req, ">")) {
        req = req[1..];
    } else if (std.mem.startsWith(u8, req, "~=")) {
        req = req[2..];
    }

    const trimmed = std.mem.trim(u8, req, &std.ascii.whitespace);
    return try allocator.dupe(u8, trimmed);
}

fn extractPackageName(allocator: std.mem.Allocator, dep_spec: []const u8) ![]const u8 {
    // For git dependencies like "pkg @ git+https://...", preserve the full spec
    if (std.mem.indexOf(u8, dep_spec, "@ git+") != null or
        std.mem.indexOf(u8, dep_spec, "@git+") != null or
        std.mem.startsWith(u8, dep_spec, "git+") or
        std.mem.startsWith(u8, dep_spec, "git="))
    {
        return try allocator.dupe(u8, dep_spec);
    }

    // Extract "requests>=2.28.0" -> "requests"
    // Extract "numpy" -> "numpy"

    const operators = [_][]const u8{ ">=", "<=", "==", "~=", ">", "<", "!=" };

    for (operators) |op| {
        if (std.mem.indexOf(u8, dep_spec, op)) |idx| {
            const name = std.mem.trim(u8, dep_spec[0..idx], &std.ascii.whitespace);
            return try allocator.dupe(u8, name);
        }
    }

    // No version specifier, just package name
    return try allocator.dupe(u8, dep_spec);
}

fn parseInlineDependencies(allocator: std.mem.Allocator, dependencies: *std.ArrayList([]const u8), deps_str: []const u8) !void {
    var parts = std.mem.splitScalar(u8, deps_str, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        // Remove quotes
        var dep = trimmed;
        if (dep.len > 0 and dep[0] == '"') dep = dep[1..];
        if (dep.len > 0 and dep[dep.len - 1] == '"') dep = dep[0 .. dep.len - 1];

        if (dep.len > 0) {
            const package_name = try extractPackageName(allocator, dep);
            try dependencies.append(allocator, package_name);
        }
    }
}

/// Write pyproject.toml file
pub fn writePyProject(_: std.mem.Allocator, project: PyProject, file_path: []const u8) !void {
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&buffer);
    const writer = &file_writer.interface;

    // Write [project] section
    try writer.writeAll("[project]\n");

    if (project.name) |name| {
        try writer.print("name = \"{s}\"\n", .{name});
    }

    if (project.version) |version| {
        try writer.print("version = \"{s}\"\n", .{version});
    }

    if (project.python_version) |pv| {
        try writer.print("requires-python = \">={s}\"\n", .{pv});
    }

    if (project.build_type) |bt| {
        try writer.print("build_type = \"{s}\"\n", .{bt});
    }

    // Write dependencies
    if (project.dependencies.len > 0) {
        try writer.writeAll("dependencies = [\n");
        for (project.dependencies) |dep| {
            try writer.print("    \"{s}\",\n", .{dep});
        }
        try writer.writeAll("]\n");
    } else {
        try writer.writeAll("dependencies = []\n");
    }

    try writer.flush();
}

/// Add a dependency to pyproject.toml
pub fn addDependency(allocator: std.mem.Allocator, file_path: []const u8, package_name: []const u8) !void {
    var project = try parsePyProject(allocator, file_path);
    defer project.deinit(allocator);

    // Check if dependency already exists
    for (project.dependencies) |dep| {
        if (std.mem.eql(u8, dep, package_name)) {
            return; // Already exists
        }
    }

    // Add new dependency
    var new_deps: std.ArrayList([]const u8) = .empty;
    defer new_deps.deinit(allocator);

    for (project.dependencies) |dep| {
        try new_deps.append(allocator, try allocator.dupe(u8, dep));
    }
    try new_deps.append(allocator, try allocator.dupe(u8, package_name));

    // Update project
    const old_deps = project.dependencies;
    project.dependencies = try new_deps.toOwnedSlice(allocator);

    // Write updated project
    try writePyProject(allocator, project, file_path);

    // Clean up old deps
    for (old_deps) |dep| {
        allocator.free(dep);
    }
    allocator.free(old_deps);
}

/// Remove a dependency from pyproject.toml
pub fn removeDependency(allocator: std.mem.Allocator, file_path: []const u8, package_name: []const u8) !void {
    var project = try parsePyProject(allocator, file_path);
    defer project.deinit(allocator);

    // Filter out the dependency
    var new_deps: std.ArrayList([]const u8) = .empty;
    defer new_deps.deinit(allocator);

    for (project.dependencies) |dep| {
        if (!std.mem.eql(u8, dep, package_name)) {
            try new_deps.append(allocator, try allocator.dupe(u8, dep));
        }
    }

    // Update project
    const old_deps = project.dependencies;
    project.dependencies = try new_deps.toOwnedSlice(allocator);

    // Write updated project
    try writePyProject(allocator, project, file_path);

    // Clean up old deps
    for (old_deps) |dep| {
        allocator.free(dep);
    }
    allocator.free(old_deps);
}

// ============================================================================
// Tests
// ============================================================================

test "extractPackageName - simple package name" {
    const allocator = std.testing.allocator;
    const name = try extractPackageName(allocator, "requests");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("requests", name);
}

test "extractPackageName - with >= version" {
    const allocator = std.testing.allocator;
    const name = try extractPackageName(allocator, "requests>=2.28.0");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("requests", name);
}

test "extractPackageName - with == version" {
    const allocator = std.testing.allocator;
    const name = try extractPackageName(allocator, "numpy==1.24.0");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("numpy", name);
}

test "extractPackageName - with ~= version" {
    const allocator = std.testing.allocator;
    const name = try extractPackageName(allocator, "django~=4.2");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("django", name);
}

test "extractPackageName - with < version" {
    const allocator = std.testing.allocator;
    const name = try extractPackageName(allocator, "flask<3.0");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("flask", name);
}

test "parsePythonRequirement - >= operator" {
    const allocator = std.testing.allocator;
    const version = try parsePythonRequirement(allocator, ">=3.11");
    defer allocator.free(version);
    try std.testing.expectEqualStrings("3.11", version);
}

test "parsePythonRequirement - == operator" {
    const allocator = std.testing.allocator;
    const version = try parsePythonRequirement(allocator, "==3.10");
    defer allocator.free(version);
    try std.testing.expectEqualStrings("3.10", version);
}

test "parsePythonRequirement - ~= operator" {
    const allocator = std.testing.allocator;
    const version = try parsePythonRequirement(allocator, "~=3.9");
    defer allocator.free(version);
    try std.testing.expectEqualStrings("3.9", version);
}

test "parsePythonRequirement - no operator" {
    const allocator = std.testing.allocator;
    const version = try parsePythonRequirement(allocator, "3.12");
    defer allocator.free(version);
    try std.testing.expectEqualStrings("3.12", version);
}

test "parseTomlContent - basic project" {
    const allocator = std.testing.allocator;
    const content =
        \\[project]
        \\name = "my-project"
        \\version = "1.0.0"
        \\requires-python = ">=3.11"
        \\dependencies = []
    ;

    const project = try parseTomlContent(allocator, content);
    defer project.deinit(allocator);

    try std.testing.expectEqualStrings("my-project", project.name.?);
    try std.testing.expectEqualStrings("1.0.0", project.version.?);
    try std.testing.expectEqualStrings("3.11", project.python_version.?);
    try std.testing.expectEqual(@as(usize, 0), project.dependencies.len);
}

test "parseTomlContent - with dependencies" {
    const allocator = std.testing.allocator;
    const content =
        \\[project]
        \\name = "test-project"
        \\version = "0.1.0"
        \\dependencies = [
        \\    "requests>=2.28.0",
        \\    "numpy",
        \\]
    ;

    const project = try parseTomlContent(allocator, content);
    defer project.deinit(allocator);

    try std.testing.expectEqualStrings("test-project", project.name.?);
    try std.testing.expectEqual(@as(usize, 2), project.dependencies.len);
    try std.testing.expectEqualStrings("requests", project.dependencies[0]);
    try std.testing.expectEqualStrings("numpy", project.dependencies[1]);
}

test "parseTomlContent - inline dependencies" {
    const allocator = std.testing.allocator;
    const content =
        \\[project]
        \\name = "inline-test"
        \\dependencies = ["flask", "django>=4.0"]
    ;

    const project = try parseTomlContent(allocator, content);
    defer project.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), project.dependencies.len);
    try std.testing.expectEqualStrings("flask", project.dependencies[0]);
    try std.testing.expectEqualStrings("django", project.dependencies[1]);
}

test "parseTomlContent - empty content" {
    const allocator = std.testing.allocator;
    const content = "";

    const project = try parseTomlContent(allocator, content);
    defer project.deinit(allocator);

    try std.testing.expect(project.name == null);
    try std.testing.expect(project.version == null);
    try std.testing.expectEqual(@as(usize, 0), project.dependencies.len);
}

test "parseTomlContent - with comments" {
    const allocator = std.testing.allocator;
    const content =
        \\# This is a comment
        \\[project]
        \\# Another comment
        \\name = "commented-project"
        \\version = "1.0.0"
        \\dependencies = []
    ;

    const project = try parseTomlContent(allocator, content);
    defer project.deinit(allocator);

    try std.testing.expectEqualStrings("commented-project", project.name.?);
}

test "parseInlineDependencies - multiple packages" {
    const allocator = std.testing.allocator;
    var deps: std.ArrayList([]const u8) = .empty;
    defer {
        for (deps.items) |d| allocator.free(d);
        deps.deinit(allocator);
    }

    try parseInlineDependencies(allocator, &deps, "\"requests\", \"flask>=2.0\", \"numpy\"");

    try std.testing.expectEqual(@as(usize, 3), deps.items.len);
    try std.testing.expectEqualStrings("requests", deps.items[0]);
    try std.testing.expectEqualStrings("flask", deps.items[1]);
    try std.testing.expectEqualStrings("numpy", deps.items[2]);
}
