const std = @import("std");
const venv = @import("venv.zig");
const python = @import("python.zig");
const pkg = @import("package.zig");
const lock = @import("lock.zig");
const pyproject = @import("pyproject.zig");
const cache = @import("cache.zig");

const VERSION = "0.1.0";

pub fn printVersion() !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("zap version {s}\n", .{VERSION});
    try stdout.flush();
}

pub fn printUsage() !void {
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(
        \\zap - Fast and Safe Python Package Manager
        \\
        \\Usage:
        \\  zap <command> [options]
        \\
        \\Commands:
        \\  init [--python <version>]     Initialize a new Python project with venv
        \\  sync                          Sync dependencies from pyproject.toml
        \\  run <script.py>               Run Python script in venv
        \\  append <package>...           Install Python packages
        \\  remove <package>...           Remove Python packages
        \\  list                          List installed packages
        \\  cache clean                   Clear the global package cache
        \\  cache info                    Show cache location and size
        \\  version, --version            Show version
        \\  help, --help                  Show this help
        \\
    );
    try stdout.flush();
}

pub fn initCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var python_version: ?[]const u8 = null;

    // Parse arguments
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--python")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --python requires a version argument\n", .{});
                std.process.exit(1);
            }
            python_version = args[i + 1];
            i += 1;
        }
    }

    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    // Detect Python
    const py_info = try python.detectPython(allocator, python_version);
    defer allocator.free(py_info.path);
    defer allocator.free(py_info.version);

    try stdout.print("Using Python {s} at {s}\n", .{ py_info.version, py_info.path });
    try stdout.flush();

    // Create venv
    try stdout.writeAll("Creating virtual environment...\n");
    try stdout.flush();
    try venv.createVenv(allocator, py_info.path, ".venv");

    // Initialize lock file
    try lock.initLockFile(allocator, py_info.version);

    // Create initial pyproject.toml only if it doesn't exist
    std.fs.cwd().access("pyproject.toml", .{}) catch {
        const pyproj = pyproject.PyProject{
            .name = null,
            .version = null,
            .dependencies = &[_][]const u8{},
            .python_version = try allocator.dupe(u8, py_info.version),
        };
        defer if (pyproj.python_version) |pv| allocator.free(pv);

        pyproject.writePyProject(allocator, pyproj, "pyproject.toml") catch |err| {
            std.debug.print("Warning: Could not create pyproject.toml: {}\n", .{err});
        };
    };

    try stdout.writeAll("✓ Project initialized successfully!\n");
    try stdout.writeAll("  Virtual environment: .venv\n");
    try stdout.writeAll("  Lock file: zap.lock\n");
    try stdout.writeAll("  Project file: pyproject.toml\n");
    try stdout.flush();
}

pub fn runCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Error: 'run' command requires a Python script\n", .{});
        std.process.exit(1);
    }

    const script_path = args[0];
    const script_args = args[1..];

    // Ensure venv exists
    if (!try venv.venvExists()) {
        std.debug.print("Error: Virtual environment not found. Run 'zap init' first.\n", .{});
        std.process.exit(1);
    }

    try venv.runInVenv(allocator, script_path, script_args);
}

pub fn appendCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Error: 'append' command requires at least one package name\n", .{});
        std.process.exit(1);
    }

    // Ensure venv exists
    if (!try venv.venvExists()) {
        std.debug.print("Error: Virtual environment not found. Run 'zap init' first.\n", .{});
        std.process.exit(1);
    }

    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    for (args) |package_name| {
        try stdout.print("Installing {s}...\n", .{package_name});
        try stdout.flush();
        try pkg.installPackage(allocator, package_name);

        // Add to pyproject.toml
        pyproject.addDependency(allocator, "pyproject.toml", package_name) catch |err| {
            std.debug.print("Warning: Could not update pyproject.toml: {}\n", .{err});
        };
    }

    // Update lock file
    try lock.updateLockFile(allocator);

    try stdout.writeAll("✓ Packages installed successfully!\n");
    try stdout.flush();
}

pub fn removeCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Error: 'remove' command requires at least one package name\n", .{});
        std.process.exit(1);
    }

    // Ensure venv exists
    if (!try venv.venvExists()) {
        std.debug.print("Error: Virtual environment not found. Run 'zap init' first.\n", .{});
        std.process.exit(1);
    }

    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    for (args) |package_name| {
        try stdout.print("Removing {s}...\n", .{package_name});
        try stdout.flush();
        try pkg.removePackage(allocator, package_name);

        // Remove from pyproject.toml
        pyproject.removeDependency(allocator, "pyproject.toml", package_name) catch |err| {
            std.debug.print("Warning: Could not update pyproject.toml: {}\n", .{err});
        };
    }

    // Update lock file
    try lock.updateLockFile(allocator);

    try stdout.writeAll("✓ Packages removed successfully!\n");
    try stdout.flush();
}

pub fn syncCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = args;

    // Ensure venv exists
    if (!try venv.venvExists()) {
        std.debug.print("Error: Virtual environment not found. Run 'zap init' first.\n", .{});
        std.process.exit(1);
    }

    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    // Parse pyproject.toml
    const project = try pyproject.parsePyProject(allocator, "pyproject.toml");
    defer project.deinit(allocator);

    if (project.dependencies.len == 0) {
        try stdout.writeAll("No dependencies found in pyproject.toml\n");
        try stdout.flush();
        return;
    }

    try stdout.print("Syncing {d} dependencies from pyproject.toml...\n", .{project.dependencies.len});
    try stdout.flush();

    // Install each dependency
    for (project.dependencies) |dep| {
        try stdout.print("Installing {s}...\n", .{dep});
        try stdout.flush();

        pkg.installPackage(allocator, dep) catch |err| {
            std.debug.print("Warning: Failed to install {s}: {}\n", .{ dep, err });
        };
    }

    // Update lock file
    try lock.updateLockFile(allocator);

    try stdout.writeAll("Done\n");
    try stdout.flush();
}

pub fn listCommand(allocator: std.mem.Allocator) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    // Ensure venv exists
    if (!try venv.venvExists()) {
        std.debug.print("Error: Virtual environment not found. Run 'zap init' first.\n", .{});
        std.process.exit(1);
    }

    const packages = try pkg.getInstalledPackages(allocator);
    defer {
        for (packages) |p| p.deinit(allocator);
        allocator.free(packages);
    }

    if (packages.len == 0) {
        try stdout.writeAll("No packages installed.\n");
        try stdout.flush();
        return;
    }

    try stdout.print("Installed packages ({d}):\n", .{packages.len});
    for (packages) |p| {
        try stdout.print("  {s} {s}\n", .{ p.name, p.version });
    }
    try stdout.flush();
}

pub fn cacheCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (args.len == 0) {
        try stdout.writeAll("Usage: zap cache <subcommand>\n");
        try stdout.writeAll("Subcommands:\n");
        try stdout.writeAll("  clean    Clear the global package cache\n");
        try stdout.writeAll("  info     Show cache location and size\n");
        try stdout.flush();
        return;
    }

    var pkg_cache = try cache.Cache.init(allocator);
    defer pkg_cache.deinit();

    if (std.mem.eql(u8, args[0], "clean")) {
        try stdout.writeAll("Clearing cache...\n");
        try stdout.flush();
        try pkg_cache.clean();
        try stdout.writeAll("Cache cleared.\n");
        try stdout.flush();
    } else if (std.mem.eql(u8, args[0], "info")) {
        const size = try pkg_cache.getSize();
        try stdout.print("Cache location: {s}\n", .{pkg_cache.cache_dir});

        // Format size nicely
        if (size < 1024) {
            try stdout.print("Cache size: {d} B\n", .{size});
        } else if (size < 1024 * 1024) {
            try stdout.print("Cache size: {d:.1} KB\n", .{@as(f64, @floatFromInt(size)) / 1024.0});
        } else if (size < 1024 * 1024 * 1024) {
            try stdout.print("Cache size: {d:.1} MB\n", .{@as(f64, @floatFromInt(size)) / (1024.0 * 1024.0)});
        } else {
            try stdout.print("Cache size: {d:.1} GB\n", .{@as(f64, @floatFromInt(size)) / (1024.0 * 1024.0 * 1024.0)});
        }
        try stdout.flush();
    } else {
        try stdout.print("Unknown cache subcommand: {s}\n", .{args[0]});
        try stdout.writeAll("Use 'zap cache' to see available subcommands.\n");
        try stdout.flush();
    }
}
