# AGENTS.md - Developer Guide for zap

This guide is for agentic coding assistants working in the zap codebase.

## Repository Structure

The zap project consists of three separate repositories:

1. **Core Project** (`/home/blx/zap`) - Main Zig codebase
2. **Documentation** (`~/zap-docs/docs`) - Astro-based website
3. **Install Script** (`~/zap-zig.github.io/install.sh`) - Shell installer

## Build & Test Commands

### Core Project (Zig)

```bash
# Build debug version
zig build

# Build release version
zig build -Doptimize=ReleaseFast

# Run all tests
zig build test

# Run tests from a single file
zig test src/version.zig
zig test src/pyproject.zig

# Cross-compile for different platforms
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux      # Linux ARM64
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-macos       # macOS Intel
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-macos      # macOS Apple Silicon

# Install locally (requires doas, not sudo on this system)
doas zig build -Doptimize=ReleaseFast --prefix /usr/local install
```

### Documentation Website

```bash
cd ~/zap-docs/docs

# Install dependencies (first time only)
npm install

# Development server
npm run dev

# Build for production
npm run build
```

### Testing the Install Script

```bash
# The install script is at ~/zap-zig.github.io/install.sh
# Test locally (creates ~/.zap/bin/zap)
bash ~/zap-zig.github.io/install.sh
```

## Code Style Guidelines

### Import Organization

```zig
const std = @import("std");           // Standard library first
const venv = @import("venv.zig");     // Local modules, alphabetically
const python = @import("python.zig");
const pkg = @import("package.zig");
```

### Naming Conventions

```zig
// Constants: SCREAMING_SNAKE_CASE
const VERSION = "0.1.1";
const PYTHON_RELEASES = [_]PythonRelease{ ... };

// Types: PascalCase
pub const Version = struct { ... };
pub const PreReleaseType = enum { ... };

// Functions: camelCase
pub fn printVersion() !void { ... }
pub fn initCommand(allocator: ...) !void { ... }

// Variables: snake_case
var py_info: PythonInfo = ...;
const package_name = "requests";
```

### Error Handling

```zig
// Use error union return types
pub fn downloadFile(allocator: std.mem.Allocator, url: []const u8) !void {
    // Custom error sets
    return error.HttpError;
    return error.BuildFailed;
}

// Always handle errors explicitly - no silent failures
const result = doSomething() catch |err| {
    std.debug.print("Failed: {}\n", .{err});
    return err;
};

// Propagate with try, or handle with catch
try someFunction();
someFunction() catch {}; // Only if truly safe to ignore
```

### Memory Management

```zig
// Always pass allocator explicitly
pub fn processData(allocator: std.mem.Allocator) !void {
    // Use defer for cleanup immediately after allocation
    const data = try allocator.alloc(u8, 1024);
    defer allocator.free(data);
    
    // For slices of allocated items
    defer {
        for (list.items) |item| allocator.free(item);
        list.deinit();
    }
}
```

### Documentation

```zig
/// Public API documentation (triple slash)
/// Parse a PEP 440 version string like "3.12.8" or "1.0.0a1"
pub fn parse(version_str: []const u8) !Version {
    // Internal comments for complex logic
    var parts = std.mem.splitScalar(u8, version_str, '.');
}
```

### Testing

```zig
// Tests are inline at bottom of source files
test "add - positive numbers" {
    const result = add(3, 7);
    try std.testing.expectEqual(@as(i32, 10), result);
}

test "memory allocation" {
    const allocator = std.testing.allocator;  // Use for memory tests
    const data = try allocator.alloc(u8, 10);
    defer allocator.free(data);
}
```

## Project-Specific Patterns

### Command Functions

```zig
pub fn myCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Buffered stdout for performance
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    
    try stdout.print("Message\n", .{});
    try stdout.flush();
}
```

### Native Implementations Preferred

```zig
// BAD: Shell out
const result = try std.process.Child.run(.{
    .argv = &[_][]const u8{ "which", "python" },
});

// GOOD: Native implementation
fn findInPath(allocator: std.mem.Allocator, executable: []const u8) !?[]const u8 {
    const path_env = std.posix.getenv("PATH") orelse return null;
    // ... scan PATH directly
}
```

### Temp File Handling (avoid race conditions)

```zig
var rand_buf: [8]u8 = undefined;
std.crypto.random.bytes(&rand_buf);
const rand_val = std.mem.readInt(u64, &rand_buf, .little);
const temp_path = try std.fmt.allocPrint(allocator, "/tmp/.zap_{d}", .{rand_val});
defer allocator.free(temp_path);
defer std.fs.cwd().deleteFile(temp_path) catch {};
```

## Module Organization

```
src/
├── main.zig              # CLI entry point, routes commands
├── cli.zig               # Command implementations
├── root.zig              # Library exports
├── python.zig            # Python detection
├── python_download.zig   # Python version downloads
├── venv.zig              # Virtual environment creation
├── pypi.zig              # PyPI API client
├── http.zig              # HTTP client utilities
├── package.zig           # Package installation/removal
├── pyproject.zig         # pyproject.toml parsing
├── lock.zig              # Lock file management
├── wheel.zig             # Wheel extraction
├── zip.zig               # ZIP utilities
├── cache.zig             # Global package cache
├── version.zig           # PEP 440 version parsing
├── build.zig             # Source distribution building
├── git.zig               # Git dependency handling
└── requirements.zig      # requirements.txt parsing
```

## Version Management

When releasing, update these files:

1. `src/cli.zig` - `const VERSION = "x.y.z";`
2. `build.zig.zon` - `.version = "x.y.z",`
3. `~/zap-zig.github.io/install.sh` - `VERSION="x.y.z"`
4. `~/zap-docs/docs/src/pages/docs/changelog.astro` - Add entry

## Important Notes

- **No logging framework** - User preference; use `std.debug.print` sparingly
- **Uses doas, not sudo** - This system uses doas
- **Zig version** - 0.15.2 via zvm at `~/.zvm/bin`
- **Native over external** - Prefer Zig stdlib, avoid shelling out

## Common Pitfalls

1. **Don't use sudo** - Use `doas` instead
2. **Don't add logging** - User explicitly forbids logging frameworks
3. **Don't shell out** - Write native Zig implementations
4. **Don't ignore errors** - Always handle or propagate
5. **Don't forget defer** - Memory leaks are unacceptable
6. **Don't use global state** - Pass allocators explicitly
