const std = @import("std");
const python = @import("python.zig");

/// Create a Python virtual environment manually (fast!)
pub fn createVenv(allocator: std.mem.Allocator, python_path: []const u8, venv_path: []const u8) !void {
    // Check if venv already exists
    if (std.fs.cwd().access(venv_path, .{})) {
        // Venv exists, remove it first
        try std.fs.cwd().deleteTree(venv_path);
    } else |err| {
        if (err != error.FileNotFound) return err;
        // Continue if not found, we'll create it
    }

    // Create venv directory structure manually
    try std.fs.cwd().makeDir(venv_path);

    const bin_dir = try std.fmt.allocPrint(allocator, "{s}/bin", .{venv_path});
    defer allocator.free(bin_dir);
    try std.fs.cwd().makeDir(bin_dir);

    // Get Python version for site-packages
    const version_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ python_path, "-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" },
    });
    defer allocator.free(version_result.stdout);
    defer allocator.free(version_result.stderr);

    const py_version = std.mem.trim(u8, version_result.stdout, &std.ascii.whitespace);

    // Create lib/pythonX.Y/site-packages
    const lib_dir = try std.fmt.allocPrint(allocator, "{s}/lib/python{s}/site-packages", .{ venv_path, py_version });
    defer allocator.free(lib_dir);
    try std.fs.cwd().makePath(lib_dir);

    // Symlink Python executable
    const venv_python = try std.fmt.allocPrint(allocator, "{s}/bin/python", .{venv_path});
    defer allocator.free(venv_python);

    std.fs.cwd().symLink(python_path, venv_python, .{}) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Create python3 symlink
    const venv_python3 = try std.fmt.allocPrint(allocator, "{s}/bin/python3", .{venv_path});
    defer allocator.free(venv_python3);

    std.fs.cwd().symLink("python", venv_python3, .{}) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Get Python prefix for pyvenv.cfg
    const prefix_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ python_path, "-c", "import sys; print(sys.prefix)" },
    });
    defer allocator.free(prefix_result.stdout);
    defer allocator.free(prefix_result.stderr);

    const prefix = std.mem.trim(u8, prefix_result.stdout, &std.ascii.whitespace);

    // Create pyvenv.cfg
    const pyvenv_cfg_path = try std.fmt.allocPrint(allocator, "{s}/pyvenv.cfg", .{venv_path});
    defer allocator.free(pyvenv_cfg_path);

    const cfg_file = try std.fs.cwd().createFile(pyvenv_cfg_path, .{});
    defer cfg_file.close();

    var buffer: [2048]u8 = undefined;
    var file_writer = cfg_file.writer(&buffer);
    const writer = &file_writer.interface;

    try writer.print("home = {s}\n", .{prefix});
    try writer.writeAll("include-system-site-packages = false\n");
    try writer.print("version = {s}\n", .{py_version});
    try writer.writeAll("executable = ");
    try writer.print("{s}\n", .{python_path});
    try writer.writeAll("command = ");
    try writer.print("{s} -m venv {s}\n", .{ python_path, venv_path });
    try writer.flush();

    // Create activate script (optional, for manual activation)
    try createActivateScript(allocator, venv_path);
}

/// Create bash activate script
fn createActivateScript(allocator: std.mem.Allocator, venv_path: []const u8) !void {
    const activate_path = try std.fmt.allocPrint(allocator, "{s}/bin/activate", .{venv_path});
    defer allocator.free(activate_path);

    const activate_file = try std.fs.cwd().createFile(activate_path, .{ .mode = 0o755 });
    defer activate_file.close();

    var buffer: [4096]u8 = undefined;
    var file_writer = activate_file.writer(&buffer);
    const writer = &file_writer.interface;

    // Get absolute path for VIRTUAL_ENV
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const venv_abs = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, venv_path });
    defer allocator.free(venv_abs);

    try writer.writeAll("# This file must be used with \"source bin/activate\" *from bash*\n");
    try writer.writeAll("# You cannot run it directly\n\n");
    try writer.writeAll("deactivate () {\n");
    try writer.writeAll("    if [ -n \"${_OLD_VIRTUAL_PATH:-}\" ] ; then\n");
    try writer.writeAll("        PATH=\"${_OLD_VIRTUAL_PATH:-}\"\n");
    try writer.writeAll("        export PATH\n");
    try writer.writeAll("        unset _OLD_VIRTUAL_PATH\n");
    try writer.writeAll("    fi\n");
    try writer.writeAll("    if [ -n \"${_OLD_VIRTUAL_PS1:-}\" ] ; then\n");
    try writer.writeAll("        PS1=\"${_OLD_VIRTUAL_PS1:-}\"\n");
    try writer.writeAll("        export PS1\n");
    try writer.writeAll("        unset _OLD_VIRTUAL_PS1\n");
    try writer.writeAll("    fi\n");
    try writer.writeAll("    unset VIRTUAL_ENV\n");
    try writer.writeAll("    if [ ! \"${1:-}\" = \"nondestructive\" ] ; then\n");
    try writer.writeAll("        unset -f deactivate\n");
    try writer.writeAll("    fi\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("deactivate nondestructive\n\n");
    try writer.print("VIRTUAL_ENV=\"{s}\"\n", .{venv_abs});
    try writer.writeAll("export VIRTUAL_ENV\n\n");
    try writer.writeAll("_OLD_VIRTUAL_PATH=\"$PATH\"\n");
    try writer.writeAll("PATH=\"$VIRTUAL_ENV/bin:$PATH\"\n");
    try writer.writeAll("export PATH\n\n");
    try writer.writeAll("if [ -z \"${VIRTUAL_ENV_DISABLE_PROMPT:-}\" ] ; then\n");
    try writer.writeAll("    _OLD_VIRTUAL_PS1=\"${PS1:-}\"\n");
    try writer.print("    PS1=\"({s}) ${{PS1:-}}\"\n", .{venv_path});
    try writer.writeAll("    export PS1\n");
    try writer.writeAll("fi\n");
    try writer.flush();
}

/// Check if venv exists
pub fn venvExists() !bool {
    std.fs.cwd().access(".venv", .{}) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };
    return true;
}

/// Run a Python script in the virtual environment
pub fn runInVenv(allocator: std.mem.Allocator, script_path: []const u8, args: []const []const u8) !void {
    const venv_python = try python.getPythonPath(allocator, ".venv");
    defer allocator.free(venv_python);

    // Build argv
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, venv_python);
    try argv.append(allocator, script_path);
    for (args) |arg| {
        try argv.append(allocator, arg);
    }

    // Execute Python script
    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.process.exit(code);
            }
        },
        else => {
            std.debug.print("Process terminated abnormally\n", .{});
            std.process.exit(1);
        },
    }
}

/// Execute a command in the virtual environment
pub fn execInVenv(allocator: std.mem.Allocator, argv: []const []const u8) !std.process.Child.RunResult {
    const venv_python = try python.getPythonPath(allocator, ".venv");
    defer allocator.free(venv_python);

    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
}
