const std = @import("std");
const cli = @import("cli.zig");
const venv = @import("venv.zig");
const python = @import("python.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try cli.printUsage();
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "run")) {
        try cli.runCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "sync")) {
        try cli.syncCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "append")) {
        try cli.appendCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "remove")) {
        try cli.removeCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "init")) {
        try cli.initCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "list")) {
        try cli.listCommand(allocator);
    } else if (std.mem.eql(u8, command, "cache")) {
        try cli.cacheCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "install")) {
        try cli.installCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "python")) {
        try cli.pythonCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version")) {
        try cli.printVersion();
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        try cli.printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        try cli.printUsage();
        std.process.exit(1);
    }
}
