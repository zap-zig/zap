const std = @import("std");

pub const PythonInfo = struct {
    path: []const u8,
    version: []const u8,
};

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

        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ py_cmd, "--version" },
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

            // Find the full path
            const which_result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{ "which", py_cmd },
            }) catch continue;
            defer allocator.free(which_result.stdout);
            defer allocator.free(which_result.stderr);

            if (which_result.term.Exited == 0) {
                const path = std.mem.trim(u8, which_result.stdout, &std.ascii.whitespace);

                // Validate that Python is actually usable (can import sys)
                const validate_result = std.process.Child.run(.{
                    .allocator = allocator,
                    .argv = &[_][]const u8{ py_cmd, "-c", "import sys; import encodings" },
                }) catch continue;
                defer allocator.free(validate_result.stdout);
                defer allocator.free(validate_result.stderr);

                if (validate_result.term.Exited != 0) {
                    // Python is broken, skip it
                    continue;
                }

                return PythonInfo{
                    .path = try allocator.dupe(u8, path),
                    .version = try allocator.dupe(u8, version_str),
                };
            }
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
