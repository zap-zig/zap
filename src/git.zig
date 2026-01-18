const std = @import("std");
const build = @import("build.zig");
const wheel = @import("wheel.zig");
const lock = @import("lock.zig");
const cache = @import("cache.zig");
const pyproject = @import("pyproject.zig");
const requirements = @import("requirements.zig");
const pkg = @import("package.zig");

/// Git dependency specification
pub const GitSpec = struct {
    url: []const u8,
    branch: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    commit: ?[]const u8 = null,

    /// Parse a git specifier string
    /// Formats:
    ///   git=https://github.com/user/repo
    ///   git=https://github.com/user/repo@branch
    ///   git=https://github.com/user/repo@tag
    ///   git=https://github.com/user/repo#commit=abc123
    ///   git=https://github.com/user/repo#branch=main
    pub fn parse(allocator: std.mem.Allocator, spec: []const u8) !GitSpec {
        var result = GitSpec{ .url = undefined };

        // Remove "git=" prefix if present
        var remaining = spec;
        if (std.mem.startsWith(u8, remaining, "git=")) {
            remaining = remaining[4..];
        } else if (std.mem.startsWith(u8, remaining, "git+")) {
            remaining = remaining[4..];
        }

        // Check for fragment (#branch=main, #commit=abc)
        if (std.mem.indexOf(u8, remaining, "#")) |hash_idx| {
            const fragment = remaining[hash_idx + 1 ..];
            remaining = remaining[0..hash_idx];

            if (std.mem.startsWith(u8, fragment, "branch=")) {
                result.branch = try allocator.dupe(u8, fragment[7..]);
            } else if (std.mem.startsWith(u8, fragment, "commit=")) {
                result.commit = try allocator.dupe(u8, fragment[7..]);
            } else if (std.mem.startsWith(u8, fragment, "tag=")) {
                result.tag = try allocator.dupe(u8, fragment[4..]);
            }
        }

        // Check for @ suffix (branch or tag shorthand)
        if (std.mem.lastIndexOf(u8, remaining, "@")) |at_idx| {
            // Make sure it's not part of git@ SSH URL
            if (at_idx > 0 and remaining[at_idx - 1] != ':') {
                const ref = remaining[at_idx + 1 ..];
                remaining = remaining[0..at_idx];

                // Assume it's a branch unless it looks like a version tag
                if (std.mem.startsWith(u8, ref, "v") and ref.len > 1 and std.ascii.isDigit(ref[1])) {
                    result.tag = try allocator.dupe(u8, ref);
                } else {
                    result.branch = try allocator.dupe(u8, ref);
                }
            }
        }

        result.url = try allocator.dupe(u8, remaining);
        return result;
    }

    pub fn deinit(self: *GitSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        if (self.branch) |b| allocator.free(b);
        if (self.tag) |t| allocator.free(t);
        if (self.commit) |c| allocator.free(c);
    }
};

/// Install a package from a git repository
pub fn installFromGit(allocator: std.mem.Allocator, git_spec: []const u8) !void {
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    // Check venv exists first
    std.fs.cwd().access(".venv/bin/python", .{}) catch {
        std.debug.print("Error: Virtual environment not found. Run 'zap init' first.\n", .{});
        return error.VenvNotFound;
    };

    // Parse git specification
    var spec = try GitSpec.parse(allocator, git_spec);
    defer spec.deinit(allocator);

    try stdout.print("Installing from git: {s}\n", .{spec.url});
    if (spec.branch) |b| try stdout.print("  Branch: {s}\n", .{b});
    if (spec.tag) |t| try stdout.print("  Tag: {s}\n", .{t});
    if (spec.commit) |c| try stdout.print("  Commit: {s}\n", .{c});
    try stdout.flush();

    // Create temp directory for cloning
    var rand_buf: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);
    const rand_val = std.mem.readInt(u64, &rand_buf, .little);
    const clone_dir = try std.fmt.allocPrint(allocator, "/tmp/.zap_git_{d}", .{rand_val});
    defer allocator.free(clone_dir);

    // Clean up clone dir on exit
    defer std.fs.cwd().deleteTree(clone_dir) catch {};

    // Clone the repository
    try stdout.writeAll("  Cloning repository...\n");
    try stdout.flush();

    var clone_args: std.ArrayList([]const u8) = .empty;
    defer clone_args.deinit(allocator);

    try clone_args.append(allocator, "git");
    try clone_args.append(allocator, "clone");
    try clone_args.append(allocator, "--depth");
    try clone_args.append(allocator, "1");

    if (spec.branch) |branch| {
        try clone_args.append(allocator, "--branch");
        try clone_args.append(allocator, branch);
    } else if (spec.tag) |tag| {
        try clone_args.append(allocator, "--branch");
        try clone_args.append(allocator, tag);
    }

    try clone_args.append(allocator, spec.url);
    try clone_args.append(allocator, clone_dir);

    const clone_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = clone_args.items,
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(clone_result.stdout);
    defer allocator.free(clone_result.stderr);

    if (clone_result.term.Exited != 0) {
        std.debug.print("Error cloning repository:\n{s}\n", .{clone_result.stderr});
        return error.GitCloneFailed;
    }

    // If specific commit requested, checkout that commit
    if (spec.commit) |commit| {
        const checkout_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "-C", clone_dir, "checkout", commit },
            .max_output_bytes = 1024 * 1024,
        });
        defer allocator.free(checkout_result.stdout);
        defer allocator.free(checkout_result.stderr);

        if (checkout_result.term.Exited != 0) {
            std.debug.print("Error checking out commit:\n{s}\n", .{checkout_result.stderr});
            return error.GitCheckoutFailed;
        }
    }

    // Get package name from pyproject.toml or setup.py
    const package_name = try getPackageName(allocator, clone_dir);
    defer allocator.free(package_name);

    try stdout.print("  Found package: {s}\n", .{package_name});
    try stdout.flush();

    // Get lock file for Python version and site-packages path
    const lock_file = try lock.readLockFile(allocator);
    defer lock_file.deinit(allocator);

    const site_packages = try wheel.getSitePackagesDir(allocator, ".venv", lock_file.python_version);
    defer allocator.free(site_packages);

    // Ensure build dependencies are available
    try build.ensureBuildDeps(allocator);

    // Build wheel from the cloned repo
    try stdout.writeAll("  Building wheel...\n");
    try stdout.flush();

    var pkg_cache = try cache.Cache.init(allocator);
    defer pkg_cache.deinit();

    const wheel_dir = try std.fmt.allocPrint(allocator, "{s}/git-{s}", .{ pkg_cache.cache_dir, package_name });
    defer allocator.free(wheel_dir);

    // Use pip wheel to build with zig cc as the compiler
    const venv_pip = build.getPipPath();

    // Create environment with CC/CXX set to zig
    var env = try build.createBuildEnv(allocator);
    defer env.deinit();

    const build_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            venv_pip,
            "wheel",
            "--no-deps",
            "--wheel-dir",
            wheel_dir,
            clone_dir,
        },
        .env_map = &env,
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);

    if (build_result.term.Exited != 0) {
        std.debug.print("Error building wheel:\n{s}\n", .{build_result.stderr});
        return error.BuildFailed;
    }

    // Find and install the built wheel
    const wheel_path = try build.findBuiltWheel(allocator, wheel_dir);
    defer allocator.free(wheel_path);

    // Extract wheel
    try stdout.writeAll("  Extracting wheel...\n");
    try stdout.flush();

    const extract_dir = try std.fmt.allocPrint(allocator, "{s}/extracted", .{wheel_dir});
    defer allocator.free(extract_dir);

    std.fs.cwd().deleteTree(extract_dir) catch {};
    try wheel.extractWheel(allocator, wheel_path, extract_dir);

    // Install to site-packages
    try stdout.writeAll("  Installing to site-packages...\n");
    try stdout.flush();
    try wheel.installWheelToSitePackages(allocator, extract_dir, site_packages);

    try stdout.print("  Installed {s} from git\n", .{package_name});
    try stdout.flush();

    // Install dependencies from requirements.txt if present
    try installRepoDependencies(allocator, clone_dir, lock_file.python_version, site_packages, stdout);

    // Add to pyproject.toml with git URL
    const git_dep = try std.fmt.allocPrint(allocator, "{s} @ git+{s}", .{ package_name, spec.url });
    defer allocator.free(git_dep);

    pyproject.addDependency(allocator, "pyproject.toml", git_dep) catch |err| {
        std.debug.print("Warning: Could not update pyproject.toml: {}\n", .{err});
    };
}

/// Install dependencies from a cloned repo's requirements.txt or pyproject.toml
fn installRepoDependencies(
    allocator: std.mem.Allocator,
    repo_dir: []const u8,
    _: []const u8, // python_version - reserved for future use
    site_packages: []const u8,
    stdout: anytype,
) !void {
    // Collect dependencies from various sources
    var deps_to_install: std.ArrayList([]const u8) = .empty;
    defer {
        for (deps_to_install.items) |d| allocator.free(d);
        deps_to_install.deinit(allocator);
    }

    // Try requirements.txt first (common in many repos)
    const req_files = [_][]const u8{
        "requirements.txt",
        "requirements/base.txt",
        "requirements/main.txt",
        "requirements/prod.txt",
    };

    for (req_files) |req_file| {
        const req_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_dir, req_file });
        defer allocator.free(req_path);

        const deps = requirements.parseRequirementsFile(allocator, req_path) catch continue;
        defer {
            for (deps) |d| allocator.free(d);
            allocator.free(deps);
        }

        if (deps.len > 0) {
            try stdout.print("  Found {d} dependencies in {s}\n", .{ deps.len, req_file });
            try stdout.flush();

            for (deps) |dep| {
                // Skip self-references and dev dependencies
                if (std.mem.startsWith(u8, dep, "-e") or
                    std.mem.startsWith(u8, dep, ".") or
                    std.mem.indexOf(u8, dep, "pytest") != null or
                    std.mem.indexOf(u8, dep, "sphinx") != null or
                    std.mem.indexOf(u8, dep, "flake8") != null or
                    std.mem.indexOf(u8, dep, "black") != null or
                    std.mem.indexOf(u8, dep, "mypy") != null)
                {
                    continue;
                }
                try deps_to_install.append(allocator, try allocator.dupe(u8, dep));
            }
            break; // Only use first requirements file found
        }
    }

    // Install collected dependencies
    if (deps_to_install.items.len > 0) {
        try stdout.print("  Installing {d} dependencies...\n", .{deps_to_install.items.len});
        try stdout.flush();

        // Use installed packages tracker to avoid duplicates
        var installed = cache.InstalledPackages.init(allocator);
        defer installed.deinit();
        try installed.loadFromSitePackages(site_packages);

        var pkg_cache = try cache.Cache.init(allocator);
        defer pkg_cache.deinit();

        for (deps_to_install.items) |dep| {
            // Check if it's a git dependency
            if (std.mem.startsWith(u8, dep, "git+") or std.mem.indexOf(u8, dep, "@ git+") != null) {
                // Install git dependency natively
                try stdout.print("    Installing git dependency: {s}...\n", .{dep});
                try stdout.flush();

                // Convert to our git spec format
                var git_url = dep;
                if (std.mem.indexOf(u8, dep, "@ git+")) |idx| {
                    git_url = dep[idx + 2 ..]; // skip "@ "
                }
                if (std.mem.startsWith(u8, git_url, "git+")) {
                    git_url = git_url[4..]; // skip "git+"
                }

                // Install using our native git handler (non-recursive version)
                installGitDependency(allocator, git_url, site_packages, stdout) catch |err| {
                    std.debug.print("    Warning: Failed to install git dep {s}: {}\n", .{ dep, err });
                };
                continue;
            } else {
                // Regular PyPI package - extract just the package name for installation
                const pkg_name = try requirements.extractPackageName(allocator, dep);
                defer allocator.free(pkg_name);

                // Skip if already installed
                if (installed.isInstalled(pkg_name)) {
                    continue;
                }

                try stdout.print("    Installing {s}...\n", .{pkg_name});
                try stdout.flush();

                pkg.installPackage(allocator, pkg_name) catch |err| {
                    std.debug.print("    Warning: Failed to install {s}: {}\n", .{ pkg_name, err });
                };
            }
        }
    }
}

/// Install a git dependency without recursive dependency resolution
/// Used for nested git deps to avoid infinite recursion
fn installGitDependency(
    allocator: std.mem.Allocator,
    git_url: []const u8,
    site_packages: []const u8,
    stdout: anytype,
) !void {
    // Create temp directory for cloning
    var rand_buf: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);
    const rand_val = std.mem.readInt(u64, &rand_buf, .little);
    const clone_dir = try std.fmt.allocPrint(allocator, "/tmp/.zap_gitdep_{d}", .{rand_val});
    defer allocator.free(clone_dir);
    defer std.fs.cwd().deleteTree(clone_dir) catch {};

    // Parse URL for branch/tag if present (url@branch format)
    var url = git_url;
    var branch: ?[]const u8 = null;

    if (std.mem.lastIndexOf(u8, url, "@")) |at_idx| {
        // Make sure it's not part of git@ SSH URL
        if (at_idx > 0 and url[at_idx - 1] != ':' and at_idx < url.len - 1) {
            branch = url[at_idx + 1 ..];
            url = url[0..at_idx];
        }
    }

    // Clone repository
    var clone_result: std.process.Child.RunResult = undefined;
    if (branch) |b| {
        clone_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "clone", "--depth", "1", "--branch", b, url, clone_dir },
            .max_output_bytes = 1024 * 1024,
        });
    } else {
        clone_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "clone", "--depth", "1", url, clone_dir },
            .max_output_bytes = 1024 * 1024,
        });
    }
    defer allocator.free(clone_result.stdout);
    defer allocator.free(clone_result.stderr);

    if (clone_result.term.Exited != 0) {
        std.debug.print("      Failed to clone {s}\n", .{url});
        return error.GitCloneFailed;
    }

    // Get package name
    const package_name = try getPackageName(allocator, clone_dir);
    defer allocator.free(package_name);

    try stdout.print("      Building {s}...\n", .{package_name});
    try stdout.flush();

    // Ensure build deps
    try build.ensureBuildDeps(allocator);

    // Build wheel
    var pkg_cache = try cache.Cache.init(allocator);
    defer pkg_cache.deinit();

    const wheel_dir = try std.fmt.allocPrint(allocator, "{s}/gitdep-{s}", .{ pkg_cache.cache_dir, package_name });
    defer allocator.free(wheel_dir);

    const venv_pip = build.getPipPath();

    // Create environment with CC/CXX set to zig
    var env = try build.createBuildEnv(allocator);
    defer env.deinit();

    const build_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            venv_pip,
            "wheel",
            "--no-deps",
            "--wheel-dir",
            wheel_dir,
            clone_dir,
        },
        .env_map = &env,
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);

    if (build_result.term.Exited != 0) {
        std.debug.print("      Failed to build wheel for {s}\n", .{package_name});
        return error.BuildFailed;
    }

    // Find and install wheel
    const wheel_path = try build.findBuiltWheel(allocator, wheel_dir);
    defer allocator.free(wheel_path);

    const extract_dir = try std.fmt.allocPrint(allocator, "{s}/extracted", .{wheel_dir});
    defer allocator.free(extract_dir);

    std.fs.cwd().deleteTree(extract_dir) catch {};
    try wheel.extractWheel(allocator, wheel_path, extract_dir);
    try wheel.installWheelToSitePackages(allocator, extract_dir, site_packages);

    try stdout.print("      Installed {s}\n", .{package_name});
    try stdout.flush();
}

/// Extract package name from pyproject.toml, setup.cfg, or git URL
fn getPackageName(allocator: std.mem.Allocator, repo_dir: []const u8) ![]const u8 {
    // Try pyproject.toml first
    const pyproject_path = try std.fmt.allocPrint(allocator, "{s}/pyproject.toml", .{repo_dir});
    defer allocator.free(pyproject_path);

    if (std.fs.cwd().openFile(pyproject_path, .{})) |file| {
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        // Simple parsing for name = "..." or name = '...'
        var lines = std.mem.splitScalar(u8, content, '\n');
        var in_project = false;
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (std.mem.eql(u8, trimmed, "[project]")) {
                in_project = true;
                continue;
            }
            if (trimmed.len > 0 and trimmed[0] == '[') {
                in_project = false;
                continue;
            }
            if (in_project and std.mem.startsWith(u8, trimmed, "name = ")) {
                var value = trimmed["name = ".len..];
                value = std.mem.trim(u8, value, &std.ascii.whitespace);

                // Handle double quotes
                if (value.len > 0 and value[0] == '"') {
                    value = value[1..];
                    if (std.mem.indexOf(u8, value, "\"")) |end| {
                        return try allocator.dupe(u8, value[0..end]);
                    }
                }
                // Handle single quotes
                if (value.len > 0 and value[0] == '\'') {
                    value = value[1..];
                    if (std.mem.indexOf(u8, value, "'")) |end| {
                        return try allocator.dupe(u8, value[0..end]);
                    }
                }
                // No quotes
                if (value.len > 0) {
                    return try allocator.dupe(u8, value);
                }
            }
        }
    } else |_| {}

    // Try setup.cfg for package name
    const setup_cfg_path = try std.fmt.allocPrint(allocator, "{s}/setup.cfg", .{repo_dir});
    defer allocator.free(setup_cfg_path);

    if (std.fs.cwd().openFile(setup_cfg_path, .{})) |file| {
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        // Simple parsing for name = ...
        var lines = std.mem.splitScalar(u8, content, '\n');
        var in_metadata = false;
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (std.mem.eql(u8, trimmed, "[metadata]")) {
                in_metadata = true;
                continue;
            }
            if (trimmed.len > 0 and trimmed[0] == '[') {
                in_metadata = false;
                continue;
            }
            if (in_metadata) {
                if (std.mem.startsWith(u8, trimmed, "name = ") or std.mem.startsWith(u8, trimmed, "name=")) {
                    const eq_idx = std.mem.indexOf(u8, trimmed, "=").?;
                    const name = std.mem.trim(u8, trimmed[eq_idx + 1 ..], &std.ascii.whitespace);
                    if (name.len > 0) {
                        return try allocator.dupe(u8, name);
                    }
                }
            }
        }
    } else |_| {}

    // Fall back to extracting name from repo URL
    // e.g., https://github.com/user/repo-name -> repo-name
    // Look for last path component, strip .git if present
    var dir = std.fs.cwd().openDir(repo_dir, .{ .iterate = true }) catch {
        return try allocator.dupe(u8, "unknown");
    };
    defer dir.close();

    // Check if there's a .git folder to confirm this is a git repo
    // and try to extract name from git remote
    const git_config_path = try std.fmt.allocPrint(allocator, "{s}/.git/config", .{repo_dir});
    defer allocator.free(git_config_path);

    if (std.fs.cwd().openFile(git_config_path, .{})) |file| {
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 64 * 1024);
        defer allocator.free(content);

        // Look for url = in [remote "origin"]
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (std.mem.startsWith(u8, trimmed, "url = ")) {
                const url = trimmed["url = ".len..];
                // Extract repo name from URL
                if (extractRepoName(allocator, url)) |name| {
                    return name;
                } else |_| {}
            }
        }
    } else |_| {}

    return try allocator.dupe(u8, "unknown");
}

/// Extract repository name from git URL
fn extractRepoName(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    // Handle various URL formats:
    // https://github.com/user/repo.git -> repo
    // https://github.com/user/repo -> repo
    // git@github.com:user/repo.git -> repo

    var name = url;

    // Find last / or :
    if (std.mem.lastIndexOf(u8, name, "/")) |idx| {
        name = name[idx + 1 ..];
    } else if (std.mem.lastIndexOf(u8, name, ":")) |idx| {
        name = name[idx + 1 ..];
    }

    // Strip .git suffix
    if (std.mem.endsWith(u8, name, ".git")) {
        name = name[0 .. name.len - 4];
    }

    if (name.len == 0) {
        return error.InvalidUrl;
    }

    return try allocator.dupe(u8, name);
}

/// Check if a package spec is a git URL
pub fn isGitSpec(spec: []const u8) bool {
    return std.mem.startsWith(u8, spec, "git=") or
        std.mem.startsWith(u8, spec, "git+") or
        std.mem.startsWith(u8, spec, "git://") or
        (std.mem.indexOf(u8, spec, "github.com") != null and std.mem.indexOf(u8, spec, "/") != null) or
        (std.mem.indexOf(u8, spec, "gitlab.com") != null and std.mem.indexOf(u8, spec, "/") != null);
}

// ============================================================================
// Tests
// ============================================================================

test "GitSpec.parse - simple URL" {
    const allocator = std.testing.allocator;
    var spec = try GitSpec.parse(allocator, "git=https://github.com/user/repo");
    defer spec.deinit(allocator);

    try std.testing.expectEqualStrings("https://github.com/user/repo", spec.url);
    try std.testing.expect(spec.branch == null);
    try std.testing.expect(spec.tag == null);
    try std.testing.expect(spec.commit == null);
}

test "GitSpec.parse - with branch" {
    const allocator = std.testing.allocator;
    var spec = try GitSpec.parse(allocator, "git=https://github.com/user/repo@main");
    defer spec.deinit(allocator);

    try std.testing.expectEqualStrings("https://github.com/user/repo", spec.url);
    try std.testing.expectEqualStrings("main", spec.branch.?);
}

test "GitSpec.parse - with tag" {
    const allocator = std.testing.allocator;
    var spec = try GitSpec.parse(allocator, "git=https://github.com/user/repo@v1.0.0");
    defer spec.deinit(allocator);

    try std.testing.expectEqualStrings("https://github.com/user/repo", spec.url);
    try std.testing.expectEqualStrings("v1.0.0", spec.tag.?);
}

test "GitSpec.parse - with commit fragment" {
    const allocator = std.testing.allocator;
    var spec = try GitSpec.parse(allocator, "git=https://github.com/user/repo#commit=abc123");
    defer spec.deinit(allocator);

    try std.testing.expectEqualStrings("https://github.com/user/repo", spec.url);
    try std.testing.expectEqualStrings("abc123", spec.commit.?);
}

test "GitSpec.parse - git+ prefix" {
    const allocator = std.testing.allocator;
    var spec = try GitSpec.parse(allocator, "git+https://github.com/user/repo");
    defer spec.deinit(allocator);

    try std.testing.expectEqualStrings("https://github.com/user/repo", spec.url);
}

test "isGitSpec - various formats" {
    try std.testing.expect(isGitSpec("git=https://github.com/user/repo"));
    try std.testing.expect(isGitSpec("git+https://github.com/user/repo"));
    try std.testing.expect(isGitSpec("https://github.com/user/repo"));
    try std.testing.expect(isGitSpec("https://gitlab.com/user/repo"));
    try std.testing.expect(!isGitSpec("requests"));
    try std.testing.expect(!isGitSpec("requests>=2.0"));
}
