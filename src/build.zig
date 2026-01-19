const std = @import("std");
const wheel = @import("wheel.zig");
const venv = @import("venv.zig");
const pyproject = @import("pyproject.zig");

/// Find the zig executable path
/// Returns the path to zig, or null if not found
fn findZigPath(allocator: std.mem.Allocator) !?[]const u8 {
    // First check if we can find zig in PATH
    const path_env = std.posix.getenv("PATH") orelse return null;

    var path_iter = std.mem.splitScalar(u8, path_env, ':');
    while (path_iter.next()) |dir| {
        if (dir.len == 0) continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/zig", .{dir});
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

        if (stat.kind == .file) {
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

/// Create environment map with CC and CXX set based on build_type
/// build_type: "native_compiler" -> use gcc/g++, "zig_compiler" or null -> use zig cc/c++
/// This is public so git.zig can use it for building git dependencies
pub fn createBuildEnv(allocator: std.mem.Allocator, build_type: ?[]const u8) !std.process.EnvMap {
    var env = std.process.EnvMap.init(allocator);
    errdefer env.deinit();

    // Copy existing environment
    const environ = std.os.environ;
    for (environ) |entry| {
        const entry_slice: []const u8 = std.mem.sliceTo(entry, 0);
        if (std.mem.indexOf(u8, entry_slice, "=")) |eq_pos| {
            const key = entry_slice[0..eq_pos];
            const value = entry_slice[eq_pos + 1 ..];
            try env.put(key, value);
        }
    }

    // Set CC/CXX based on build_type
    // Default to native compiler to avoid issues with zig and Python 3.13+ headers
    const use_native = build_type == null or (build_type != null and std.mem.eql(u8, build_type.?, "native_compiler"));
    const use_zig = build_type != null and std.mem.eql(u8, build_type.?, "zig_compiler");

    if (use_native) {
        // Use native compiler (gcc/g++)
        if (env.get("CC") == null) {
            try env.put("CC", "gcc");
        }
        if (env.get("CXX") == null) {
            try env.put("CXX", "g++");
        }
    } else if (use_zig) {
        // Use zig compiler
        if (try findZigPath(allocator)) |zig_path| {
            defer allocator.free(zig_path);

            if (env.get("CC") == null) {
                const cc_cmd = try std.fmt.allocPrint(allocator, "{s} cc", .{zig_path});
                defer allocator.free(cc_cmd);
                try env.put("CC", cc_cmd);
            }

            if (env.get("CXX") == null) {
                const cxx_cmd = try std.fmt.allocPrint(allocator, "{s} c++", .{zig_path});
                defer allocator.free(cxx_cmd);
                try env.put("CXX", cxx_cmd);
            }
        }
    }

    return env;
}

/// Build a wheel from a source distribution (sdist)
/// Uses pip wheel to build, which handles all PEP 517 build backends
pub fn buildSdist(allocator: std.mem.Allocator, sdist_path: []const u8, output_dir: []const u8) ![]const u8 {
    // Create temp directory for extraction
    var rand_buf: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);
    const rand_val = std.mem.readInt(u64, &rand_buf, .little);
    const extract_dir = try std.fmt.allocPrint(allocator, "/tmp/.zap_build_{d}", .{rand_val});
    defer allocator.free(extract_dir);

    // Clean up extract dir on exit
    defer std.fs.cwd().deleteTree(extract_dir) catch {};

    // Create extract directory
    try std.fs.cwd().makePath(extract_dir);

    // Extract sdist
    try wheel.extractSdist(allocator, sdist_path, extract_dir);

    // Find the actual source directory (sdist usually extracts to package-version/)
    const src_dir = try findSourceDir(allocator, extract_dir);
    defer allocator.free(src_dir);

    // Check for pyproject.toml or setup.py
    const has_pyproject = blk: {
        const path = try std.fmt.allocPrint(allocator, "{s}/pyproject.toml", .{src_dir});
        defer allocator.free(path);
        std.fs.cwd().access(path, .{}) catch break :blk false;
        break :blk true;
    };

    const has_setup_py = blk: {
        const path = try std.fmt.allocPrint(allocator, "{s}/setup.py", .{src_dir});
        defer allocator.free(path);
        std.fs.cwd().access(path, .{}) catch break :blk false;
        break :blk true;
    };

    if (!has_pyproject and !has_setup_py) {
        std.debug.print("Error: sdist has no pyproject.toml or setup.py\n", .{});
        return error.NoBuildFile;
    }

    // Ensure output directory exists
    std.fs.cwd().makePath(output_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("  Building wheel from source...\n", .{});
    try stdout.flush();

    // Try python -m build first (PEP 517 compliant), fallback to pip wheel
    const venv_python = ".venv/bin/python";

    // Parse pyproject.toml for build_type
    const project = pyproject.parsePyProject(allocator, "pyproject.toml") catch pyproject.PyProject{
        .name = null,
        .version = null,
        .dependencies = &[_][]const u8{},
        .python_version = null,
        .build_type = null,
    };
    defer project.deinit(allocator);

    // Create environment with CC/CXX set based on build_type
    var env = try createBuildEnv(allocator, project.build_type);
    defer env.deinit();

    // First, try using build module (cleaner, PEP 517)
    const build_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            venv_python,
            "-m",
            "build",
            "--wheel",
            "--no-isolation",
            "--outdir",
            output_dir,
            src_dir,
        },
        .env_map = &env,
        .max_output_bytes = 1024 * 1024,
    }) catch {
        // build module not available, try pip wheel
        return try buildWithPip(allocator, src_dir, output_dir);
    };
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);

    if (build_result.term.Exited != 0) {
        // build module failed, try pip wheel as fallback
        return try buildWithPip(allocator, src_dir, output_dir);
    }

    // Find the built wheel in output_dir
    const wheel_name = try findBuiltWheel(allocator, output_dir);
    return wheel_name;
}

/// Fallback: build wheel using pip
fn buildWithPip(allocator: std.mem.Allocator, src_dir: []const u8, output_dir: []const u8) ![]const u8 {
    const venv_pip = getPipPath();

    // Parse pyproject.toml for build_type (from src_dir)
    const pyproject_path = try std.fmt.allocPrint(allocator, "{s}/pyproject.toml", .{src_dir});
    defer allocator.free(pyproject_path);

    const project = pyproject.parsePyProject(allocator, pyproject_path) catch pyproject.PyProject{
        .name = null,
        .version = null,
        .dependencies = &[_][]const u8{},
        .python_version = null,
        .build_type = null,
    };
    defer project.deinit(allocator);

    // Create environment with CC/CXX set based on build_type
    var env = try createBuildEnv(allocator, project.build_type);
    defer env.deinit();

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            venv_pip,
            "wheel",
            "--no-deps",
            "--wheel-dir",
            output_dir,
            src_dir,
        },
        .env_map = &env,
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.debug.print("Error building wheel:\n{s}\n", .{result.stderr});
        return error.BuildFailed;
    }

    return try findBuiltWheel(allocator, output_dir);
}

/// Find the source directory inside an extracted sdist
/// sdists usually extract to a single directory like "package-1.0.0/"
fn findSourceDir(allocator: std.mem.Allocator, extract_dir: []const u8) ![]const u8 {
    var dir = try std.fs.cwd().openDir(extract_dir, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            // Return the first directory found
            return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ extract_dir, entry.name });
        }
    }

    // No subdirectory found, source is directly in extract_dir
    return try allocator.dupe(u8, extract_dir);
}

/// Find the wheel file that was built
pub fn findBuiltWheel(allocator: std.mem.Allocator, wheel_dir: []const u8) ![]const u8 {
    var dir = try std.fs.cwd().openDir(wheel_dir, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".whl")) {
            return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ wheel_dir, entry.name });
        }
    }

    return error.WheelNotFound;
}

/// Get the pip executable path in the venv
pub fn getPipPath() []const u8 {
    // Check for pip, pip3 in order of preference
    const candidates = [_][]const u8{ ".venv/bin/pip", ".venv/bin/pip3" };
    for (candidates) |path| {
        std.fs.cwd().access(path, .{}) catch continue;
        return path;
    }
    return ".venv/bin/pip";
}

/// Check if pip is available in the venv
pub fn ensurePip(allocator: std.mem.Allocator) !void {
    // Check for pip or pip3
    const pip_exists = blk: {
        std.fs.cwd().access(".venv/bin/pip", .{}) catch {
            std.fs.cwd().access(".venv/bin/pip3", .{}) catch break :blk false;
        };
        break :blk true;
    };

    if (!pip_exists) {
        // pip not found, try to install it
        var stdout_buffer: [2048]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        const stdout = &stdout_writer.interface;

        try stdout.writeAll("  Installing pip (required for building packages)...\n");
        try stdout.flush();

        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{
                ".venv/bin/python",
                "-m",
                "ensurepip",
                "--upgrade",
            },
            .max_output_bytes = 1024 * 1024,
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            std.debug.print("Error installing pip:\n{s}\n", .{result.stderr});
            return error.PipInstallFailed;
        }
    }
}

/// Check if build dependencies are installed (needed for building some packages)
pub fn ensureBuildDeps(allocator: std.mem.Allocator) !void {
    try ensurePip(allocator);

    // Ensure wheel and setuptools are installed (common build dependencies)
    const venv_pip = getPipPath();

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            venv_pip,
            "install",
            "--quiet",
            "wheel",
            "setuptools",
        },
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Ignore errors - these might already be installed or not needed
}
