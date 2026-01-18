const std = @import("std");
const venv = @import("venv.zig");
const python = @import("python.zig");
const python_download = @import("python_download.zig");
const pkg = @import("package.zig");
const lock = @import("lock.zig");
const pyproject = @import("pyproject.zig");
const cache = @import("cache.zig");
const git = @import("git.zig");
const requirements = @import("requirements.zig");

const VERSION = "0.1.1";

pub fn printVersion() !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("zap version {s}\n", .{VERSION});
    try stdout.flush();
}

pub fn printUsage() !void {
    var stdout_buffer: [4096]u8 = undefined;
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
        \\  install -r <requirements.txt> Install from requirements file
        \\  list                          List installed packages
        \\  python install <version>      Download and install a Python version
        \\  python list                   List installed/available Python versions
        \\  cache clean                   Clear the global package cache
        \\  cache info                    Show cache location and size
        \\  version, --version            Show version
        \\  help, --help                  Show this help
        \\
        \\Package Specifiers:
        \\  zap append requests           Install from PyPI
        \\  zap append requests>=2.28     Install with version constraint
        \\  zap append git=<url>          Install from git repository
        \\  zap append git=<url>@branch   Install specific branch
        \\  zap append git=<url>@v1.0.0   Install specific tag
        \\
        \\Python Management:
        \\  zap python install 3.12       Install Python 3.12 (latest patch)
        \\  zap python install 3.11.8     Install specific Python version
        \\  zap python list               Show installed and available versions
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

    // First, check if the requested version is managed by zap
    var py_path: ?[]const u8 = null;
    var py_version_str: ?[]const u8 = null;
    var using_managed = false;

    if (python_version) |req_ver| {
        // Check if zap has this version installed
        if (try python_download.findInstalledMatch(allocator, req_ver)) |matched_ver| {
            const managed_path = try python_download.getPythonPath(allocator, matched_ver);
            // Verify it exists
            std.fs.cwd().access(managed_path, .{}) catch {
                allocator.free(managed_path);
                allocator.free(matched_ver);
                // Fall through to system detection
                py_path = null;
            };
            if (py_path == null) {
                py_path = managed_path;
                py_version_str = matched_ver;
                using_managed = true;
            }
        }
    }

    // Fall back to system Python detection
    if (py_path == null) {
        const py_info = try python.detectPython(allocator, python_version);
        py_path = py_info.path;
        py_version_str = py_info.version;
    }

    defer allocator.free(py_path.?);
    defer allocator.free(py_version_str.?);

    if (using_managed) {
        try stdout.print("Using zap-managed Python {s}\n", .{py_version_str.?});
    } else {
        try stdout.print("Using Python {s} at {s}\n", .{ py_version_str.?, py_path.? });
    }
    try stdout.flush();

    // Create venv
    try stdout.writeAll("Creating virtual environment...\n");
    try stdout.flush();
    try venv.createVenv(allocator, py_path.?, ".venv");

    // Initialize lock file
    try lock.initLockFile(allocator, py_version_str.?);

    // Create initial pyproject.toml only if it doesn't exist
    std.fs.cwd().access("pyproject.toml", .{}) catch {
        const pyproj = pyproject.PyProject{
            .name = null,
            .version = null,
            .dependencies = &[_][]const u8{},
            .python_version = try allocator.dupe(u8, py_version_str.?),
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

    for (args) |package_spec| {
        // Check if this is a git dependency
        if (git.isGitSpec(package_spec)) {
            try git.installFromGit(allocator, package_spec);
        } else {
            try stdout.print("Installing {s}...\n", .{package_spec});
            try stdout.flush();
            try pkg.installPackage(allocator, package_spec);

            // Add to pyproject.toml
            pyproject.addDependency(allocator, "pyproject.toml", package_spec) catch |err| {
                std.debug.print("Warning: Could not update pyproject.toml: {}\n", .{err});
            };
        }
    }

    // Update lock file
    try lock.updateLockFile(allocator);

    try stdout.writeAll("Packages installed successfully!\n");
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
        // Check if this is a git dependency (contains @ git+ or starts with git=)
        const is_git_dep = std.mem.indexOf(u8, dep, "@ git+") != null or
            std.mem.indexOf(u8, dep, "@git+") != null or
            std.mem.startsWith(u8, dep, "git=") or
            std.mem.startsWith(u8, dep, "git+");

        if (is_git_dep) {
            // Extract git URL from dependency spec like "package @ git+https://..."
            var git_url = dep;
            if (std.mem.indexOf(u8, dep, "@ git+")) |idx| {
                git_url = dep[idx + 2 ..]; // skip "@ "
            } else if (std.mem.indexOf(u8, dep, "@git+")) |idx| {
                git_url = dep[idx + 1 ..]; // skip "@"
            }
            // Convert git+https://... to git=https://...
            if (std.mem.startsWith(u8, git_url, "git+")) {
                const url_part = git_url[4..]; // skip "git+"
                const git_spec = try std.fmt.allocPrint(allocator, "git={s}", .{url_part});
                defer allocator.free(git_spec);
                git.installFromGit(allocator, git_spec) catch |err| {
                    std.debug.print("Warning: Failed to install {s}: {}\n", .{ dep, err });
                };
            } else {
                git.installFromGit(allocator, git_url) catch |err| {
                    std.debug.print("Warning: Failed to install {s}: {}\n", .{ dep, err });
                };
            }
        } else {
            try stdout.print("Installing {s}...\n", .{dep});
            try stdout.flush();

            pkg.installPackage(allocator, dep) catch |err| {
                std.debug.print("Warning: Failed to install {s}: {}\n", .{ dep, err });
            };
        }
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

pub fn installCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    // Parse arguments
    var requirements_file: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-r") or std.mem.eql(u8, args[i], "--requirements")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: -r requires a file path\n", .{});
                std.process.exit(1);
            }
            requirements_file = args[i + 1];
            i += 1;
        }
    }

    if (requirements_file == null) {
        // Default to requirements.txt if it exists
        std.fs.cwd().access("requirements.txt", .{}) catch {
            std.debug.print("Error: No requirements file specified. Use -r <file>\n", .{});
            std.debug.print("Usage: zap install -r requirements.txt\n", .{});
            std.process.exit(1);
        };
        requirements_file = "requirements.txt";
    }

    // Ensure venv exists
    if (!try venv.venvExists()) {
        std.debug.print("Error: Virtual environment not found. Run 'zap init' first.\n", .{});
        std.process.exit(1);
    }

    // Parse requirements file
    const deps = try requirements.parseRequirementsFile(allocator, requirements_file.?);
    defer {
        for (deps) |d| allocator.free(d);
        allocator.free(deps);
    }

    if (deps.len == 0) {
        try stdout.print("No dependencies found in {s}\n", .{requirements_file.?});
        try stdout.flush();
        return;
    }

    try stdout.print("Installing {d} packages from {s}...\n", .{ deps.len, requirements_file.? });
    try stdout.flush();

    var installed_count: usize = 0;
    var failed_count: usize = 0;

    for (deps) |dep| {
        // Check if it's a git dependency
        const is_git_dep = std.mem.startsWith(u8, dep, "git+") or
            std.mem.indexOf(u8, dep, "@ git+") != null;

        if (is_git_dep) {
            var git_url = dep;
            if (std.mem.indexOf(u8, dep, "@ git+")) |idx| {
                git_url = dep[idx + 2 ..];
            }
            if (std.mem.startsWith(u8, git_url, "git+")) {
                const url_part = git_url[4..];
                const git_spec = try std.fmt.allocPrint(allocator, "git={s}", .{url_part});
                defer allocator.free(git_spec);
                git.installFromGit(allocator, git_spec) catch |err| {
                    std.debug.print("Warning: Failed to install {s}: {}\n", .{ dep, err });
                    failed_count += 1;
                    continue;
                };
                installed_count += 1;
            }
        } else {
            // Regular package - extract name for display
            const pkg_name = try requirements.extractPackageName(allocator, dep);
            defer allocator.free(pkg_name);

            try stdout.print("Installing {s}...\n", .{pkg_name});
            try stdout.flush();

            pkg.installPackage(allocator, pkg_name) catch |err| {
                std.debug.print("Warning: Failed to install {s}: {}\n", .{ pkg_name, err });
                failed_count += 1;
                continue;
            };

            // Add to pyproject.toml
            pyproject.addDependency(allocator, "pyproject.toml", pkg_name) catch {};
            installed_count += 1;
        }
    }

    // Update lock file
    lock.updateLockFile(allocator) catch {};

    if (failed_count > 0) {
        try stdout.print("Installed {d} packages, {d} failed\n", .{ installed_count, failed_count });
    } else {
        try stdout.print("Successfully installed {d} packages\n", .{installed_count});
    }
    try stdout.flush();
}

pub fn pythonCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (args.len == 0) {
        try stdout.writeAll("Usage: zap python <subcommand>\n");
        try stdout.writeAll("Subcommands:\n");
        try stdout.writeAll("  install <version>   Download and install a Python version\n");
        try stdout.writeAll("  list                List installed and available versions\n");
        try stdout.writeAll("\nExamples:\n");
        try stdout.writeAll("  zap python install 3.12      Install latest Python 3.12.x\n");
        try stdout.writeAll("  zap python install 3.11.8    Install specific version\n");
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, args[0], "install")) {
        if (args.len < 2) {
            std.debug.print("Error: 'python install' requires a version\n", .{});
            std.debug.print("Example: zap python install 3.12\n", .{});
            std.process.exit(1);
        }

        const version = args[1];
        try python_download.installPython(allocator, version);
    } else if (std.mem.eql(u8, args[0], "list")) {
        // List installed versions
        const installed = try python_download.listInstalled(allocator);
        defer {
            for (installed) |v| allocator.free(v);
            allocator.free(installed);
        }

        try stdout.writeAll("Installed Python versions:\n");
        if (installed.len == 0) {
            try stdout.writeAll("  (none)\n");
        } else {
            for (installed) |v| {
                const path = try python_download.getPythonPath(allocator, v);
                defer allocator.free(path);
                try stdout.print("  {s}  ({s})\n", .{ v, path });
            }
        }

        // List available versions
        try stdout.writeAll("\nAvailable for download:\n");
        const available = python_download.listAvailable();
        for (available) |release| {
            // Check if already installed
            const is_installed = blk: {
                for (installed) |v| {
                    if (std.mem.eql(u8, v, release.version)) break :blk true;
                }
                break :blk false;
            };
            if (is_installed) {
                try stdout.print("  {s}  (installed)\n", .{release.version});
            } else {
                try stdout.print("  {s}\n", .{release.version});
            }
        }
        try stdout.flush();
    } else {
        try stdout.print("Unknown python subcommand: {s}\n", .{args[0]});
        try stdout.writeAll("Use 'zap python' to see available subcommands.\n");
        try stdout.flush();
    }
}
