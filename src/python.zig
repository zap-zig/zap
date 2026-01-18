const std = @import("std");

pub const PythonInfo = struct {
    path: []const u8,
    version: []const u8,
};

/// Find executable in PATH (cross-platform replacement for `which`)
fn findInPath(allocator: std.mem.Allocator, executable: []const u8) !?[]const u8 {
    const path_env = std.posix.getenv("PATH") orelse return null;

    var path_iter = std.mem.splitScalar(u8, path_env, ':');
    while (path_iter.next()) |dir| {
        if (dir.len == 0) continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, executable });
        errdefer allocator.free(full_path);

        // Check if file exists and is executable
        const file = std.fs.cwd().openFile(full_path, .{}) catch {
            allocator.free(full_path);
            continue;
        };
        defer file.close();

        const stat = file.stat() catch {
            allocator.free(full_path);
            continue;
        };

        // Check if it's a regular file and has execute permission
        if (stat.kind == .file) {
            // Check execute permission (user, group, or other)
            const mode = stat.mode;
            const has_exec = (mode & 0o111) != 0;
            if (has_exec) {
                return full_path;
            }
        }

        allocator.free(full_path);
    }

    return null;
}

/// Detect Python installation and version
pub fn detectPython(allocator: std.mem.Allocator, requested_version: ?[]const u8) !PythonInfo {
    const python_candidates = if (requested_version) |ver|
        try std.fmt.allocPrint(allocator, "python{s}", .{ver})
    else
        null;
    defer if (python_candidates) |pc| allocator.free(pc);

    const search_order = [_][]const u8{
        if (python_candidates) |pc| pc else "python3.14",
        "python3.13",
        "python3.12",
        "python3.11",
        "python3.10",
        "python3.9",
        "python3",
        "python",
    };

    for (search_order) |py_cmd| {
        if (requested_version) |_| {
            // If a specific version was requested, only try that one
            if (!std.mem.eql(u8, py_cmd, python_candidates.?)) {
                continue;
            }
        }

        // Find Python in PATH using native Zig
        const py_path = findInPath(allocator, py_cmd) catch continue orelse continue;
        defer allocator.free(py_path);

        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ py_path, "--version" },
        }) catch continue;

        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.term.Exited == 0) {
            // Python version is in stdout or stderr
            const version_output = if (result.stdout.len > 0) result.stdout else result.stderr;

            // Parse version: "Python 3.11.5" -> "3.11.5"
            var version_str = std.mem.trim(u8, version_output, &std.ascii.whitespace);
            if (std.mem.startsWith(u8, version_str, "Python ")) {
                version_str = version_str[7..];
            }

            // Validate that Python is actually usable (can import sys)
            const validate_result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{ py_path, "-c", "import sys; import encodings" },
            }) catch continue;
            defer allocator.free(validate_result.stdout);
            defer allocator.free(validate_result.stderr);

            if (validate_result.term.Exited != 0) {
                // Python is broken, skip it
                continue;
            }

            return PythonInfo{
                .path = try allocator.dupe(u8, py_path),
                .version = try allocator.dupe(u8, version_str),
            };
        }
    }

    if (requested_version) |ver| {
        std.debug.print("Error: Python {s} not found\n", .{ver});
    } else {
        std.debug.print("Error: No Python installation found\n", .{});
    }
    return error.PythonNotFound;
}

/// Get pip path for a venv
pub fn getPipPath(allocator: std.mem.Allocator, venv_path: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}/bin/pip", .{venv_path});
}

/// Get python path for a venv
pub fn getPythonPath(allocator: std.mem.Allocator, venv_path: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}/bin/python", .{venv_path});
}
