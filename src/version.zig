const std = @import("std");

/// PEP 440 Version representation
/// Supports: major.minor.patch, pre-releases (a, b, rc), post releases, dev releases
pub const Version = struct {
    major: u32 = 0,
    minor: u32 = 0,
    patch: u32 = 0,
    pre_type: ?PreReleaseType = null,
    pre_num: u32 = 0,
    post: ?u32 = null,
    dev: ?u32 = null,

    pub const PreReleaseType = enum {
        alpha, // a, alpha
        beta, // b, beta
        rc, // rc, c, pre, preview
    };

    /// Compare two versions
    /// Returns: .lt if self < other, .eq if equal, .gt if self > other
    pub fn compare(self: Version, other: Version) std.math.Order {
        // Compare major.minor.patch
        if (self.major != other.major) return std.math.order(self.major, other.major);
        if (self.minor != other.minor) return std.math.order(self.minor, other.minor);
        if (self.patch != other.patch) return std.math.order(self.patch, other.patch);

        // Pre-release versions are less than release versions
        // e.g., 1.0.0a1 < 1.0.0
        const self_pre_ord = preReleaseOrder(self.pre_type);
        const other_pre_ord = preReleaseOrder(other.pre_type);
        if (self_pre_ord != other_pre_ord) return std.math.order(self_pre_ord, other_pre_ord);

        // Compare pre-release numbers if both have same type
        if (self.pre_type != null and other.pre_type != null) {
            if (self.pre_num != other.pre_num) return std.math.order(self.pre_num, other.pre_num);
        }

        // Post releases are greater than release versions
        // e.g., 1.0.0 < 1.0.0.post1
        const self_post = self.post orelse 0;
        const other_post = other.post orelse 0;
        const self_has_post = self.post != null;
        const other_has_post = other.post != null;

        if (self_has_post != other_has_post) {
            return if (self_has_post) .gt else .lt;
        }
        if (self_post != other_post) return std.math.order(self_post, other_post);

        // Dev releases are less than release versions
        // e.g., 1.0.0.dev1 < 1.0.0
        const self_has_dev = self.dev != null;
        const other_has_dev = other.dev != null;

        if (self_has_dev != other_has_dev) {
            return if (self_has_dev) .lt else .gt;
        }
        if (self.dev != null and other.dev != null) {
            return std.math.order(self.dev.?, other.dev.?);
        }

        return .eq;
    }

    fn preReleaseOrder(pre_type: ?PreReleaseType) u8 {
        return if (pre_type) |pt| switch (pt) {
            .alpha => 1,
            .beta => 2,
            .rc => 3,
        } else 4; // Release version (no pre-release) is highest
    }

    /// Check if version satisfies a constraint
    pub fn satisfies(self: Version, constraint: VersionConstraint) bool {
        return switch (constraint.op) {
            .eq => self.compare(constraint.version) == .eq,
            .ne => self.compare(constraint.version) != .eq,
            .lt => self.compare(constraint.version) == .lt,
            .le => self.compare(constraint.version) != .gt,
            .gt => self.compare(constraint.version) == .gt,
            .ge => self.compare(constraint.version) != .lt,
            .compatible => blk: {
                // ~= means compatible release: >=V.N, <V.(N+1)
                // e.g., ~=1.4.2 means >=1.4.2, <1.5.0
                if (self.compare(constraint.version) == .lt) break :blk false;
                const upper = Version{
                    .major = constraint.version.major,
                    .minor = constraint.version.minor + 1,
                    .patch = 0,
                };
                break :blk self.compare(upper) == .lt;
            },
            .any => true,
        };
    }
};

/// Version constraint operator
pub const Operator = enum {
    eq, // ==
    ne, // !=
    lt, // <
    le, // <=
    gt, // >
    ge, // >=
    compatible, // ~=
    any, // no constraint
};

/// A version constraint (e.g., ">=1.0.0")
pub const VersionConstraint = struct {
    op: Operator,
    version: Version,
};

/// Parse a PEP 440 version string
pub fn parseVersion(version_str: []const u8) !Version {
    var version = Version{};
    var remaining = version_str;

    // Skip leading 'v' if present
    if (remaining.len > 0 and (remaining[0] == 'v' or remaining[0] == 'V')) {
        remaining = remaining[1..];
    }

    // Parse major version
    const major_end = findNonDigit(remaining);
    if (major_end == 0) return error.InvalidVersion;
    version.major = try std.fmt.parseInt(u32, remaining[0..major_end], 10);
    remaining = remaining[major_end..];

    // Parse minor version (optional)
    if (remaining.len > 0 and remaining[0] == '.') {
        remaining = remaining[1..];
        const minor_end = findNonDigit(remaining);
        if (minor_end > 0) {
            version.minor = try std.fmt.parseInt(u32, remaining[0..minor_end], 10);
            remaining = remaining[minor_end..];
        }
    }

    // Parse patch version (optional)
    if (remaining.len > 0 and remaining[0] == '.') {
        remaining = remaining[1..];
        const patch_end = findNonDigit(remaining);
        if (patch_end > 0) {
            version.patch = try std.fmt.parseInt(u32, remaining[0..patch_end], 10);
            remaining = remaining[patch_end..];
        }
    }

    // Parse pre-release (a, b, rc, alpha, beta, etc.)
    if (remaining.len > 0) {
        if (std.mem.startsWith(u8, remaining, "alpha") or std.mem.startsWith(u8, remaining, "a")) {
            version.pre_type = .alpha;
            remaining = if (std.mem.startsWith(u8, remaining, "alpha")) remaining[5..] else remaining[1..];
            version.pre_num = parseOptionalNumber(&remaining);
        } else if (std.mem.startsWith(u8, remaining, "beta") or std.mem.startsWith(u8, remaining, "b")) {
            version.pre_type = .beta;
            remaining = if (std.mem.startsWith(u8, remaining, "beta")) remaining[4..] else remaining[1..];
            version.pre_num = parseOptionalNumber(&remaining);
        } else if (std.mem.startsWith(u8, remaining, "rc") or std.mem.startsWith(u8, remaining, "c") or
            std.mem.startsWith(u8, remaining, "pre") or std.mem.startsWith(u8, remaining, "preview"))
        {
            version.pre_type = .rc;
            if (std.mem.startsWith(u8, remaining, "preview")) {
                remaining = remaining[7..];
            } else if (std.mem.startsWith(u8, remaining, "pre")) {
                remaining = remaining[3..];
            } else if (std.mem.startsWith(u8, remaining, "rc")) {
                remaining = remaining[2..];
            } else {
                remaining = remaining[1..];
            }
            version.pre_num = parseOptionalNumber(&remaining);
        }
    }

    // Parse post release (.post1, .post, -1, etc.)
    if (remaining.len > 0) {
        if (std.mem.startsWith(u8, remaining, ".post") or std.mem.startsWith(u8, remaining, "-post") or
            std.mem.startsWith(u8, remaining, "post"))
        {
            if (remaining[0] == '.' or remaining[0] == '-') remaining = remaining[1..];
            remaining = remaining[4..]; // skip "post"
            version.post = parseOptionalNumber(&remaining);
            if (version.post == null) version.post = 0;
        } else if (remaining.len > 0 and remaining[0] == '-') {
            // Implicit post release: 1.0-1 means 1.0.post1
            remaining = remaining[1..];
            const num_end = findNonDigit(remaining);
            if (num_end > 0) {
                version.post = try std.fmt.parseInt(u32, remaining[0..num_end], 10);
                remaining = remaining[num_end..];
            }
        }
    }

    // Parse dev release (.dev1, dev1, etc.)
    if (remaining.len > 0) {
        if (std.mem.startsWith(u8, remaining, ".dev") or std.mem.startsWith(u8, remaining, "dev")) {
            if (remaining[0] == '.') remaining = remaining[1..];
            remaining = remaining[3..]; // skip "dev"
            version.dev = parseOptionalNumber(&remaining);
            if (version.dev == null) version.dev = 0;
        }
    }

    return version;
}

fn findNonDigit(s: []const u8) usize {
    for (s, 0..) |c, i| {
        if (!std.ascii.isDigit(c)) return i;
    }
    return s.len;
}

fn parseOptionalNumber(remaining: *[]const u8) ?u32 {
    const num_end = findNonDigit(remaining.*);
    if (num_end == 0) return null;
    const num = std.fmt.parseInt(u32, remaining.*[0..num_end], 10) catch return null;
    remaining.* = remaining.*[num_end..];
    return num;
}

/// Parse a version constraint string (e.g., ">=1.0.0", "~=2.0", "==1.2.3")
pub fn parseConstraint(constraint_str: []const u8) !VersionConstraint {
    var remaining = std.mem.trim(u8, constraint_str, &std.ascii.whitespace);

    if (remaining.len == 0) {
        return VersionConstraint{ .op = .any, .version = Version{} };
    }

    var op: Operator = .eq;

    // Parse operator
    if (std.mem.startsWith(u8, remaining, "~=")) {
        op = .compatible;
        remaining = remaining[2..];
    } else if (std.mem.startsWith(u8, remaining, ">=")) {
        op = .ge;
        remaining = remaining[2..];
    } else if (std.mem.startsWith(u8, remaining, "<=")) {
        op = .le;
        remaining = remaining[2..];
    } else if (std.mem.startsWith(u8, remaining, "!=")) {
        op = .ne;
        remaining = remaining[2..];
    } else if (std.mem.startsWith(u8, remaining, "==")) {
        op = .eq;
        remaining = remaining[2..];
    } else if (std.mem.startsWith(u8, remaining, ">")) {
        op = .gt;
        remaining = remaining[1..];
    } else if (std.mem.startsWith(u8, remaining, "<")) {
        op = .lt;
        remaining = remaining[1..];
    }

    remaining = std.mem.trim(u8, remaining, &std.ascii.whitespace);
    const version = try parseVersion(remaining);

    return VersionConstraint{ .op = op, .version = version };
}

/// Parse a dependency specifier and extract package name and constraints
/// e.g., "requests>=2.28.0,<3.0" -> ("requests", [>=2.28.0, <3.0])
pub fn parseDependency(allocator: std.mem.Allocator, dep_str: []const u8) !struct {
    name: []const u8,
    constraints: []VersionConstraint,
} {
    var dep = dep_str;

    // Handle environment markers (skip everything after ;)
    if (std.mem.indexOf(u8, dep, ";")) |semi_idx| {
        dep = dep[0..semi_idx];
    }

    // Handle extras (skip [extra] part for now)
    if (std.mem.indexOf(u8, dep, "[")) |bracket_idx| {
        if (std.mem.indexOf(u8, dep[bracket_idx..], "]")) |close_idx| {
            const before = dep[0..bracket_idx];
            const after = dep[bracket_idx + close_idx + 1 ..];
            // Concatenate before and after
            var name_buf: [256]u8 = undefined;
            const total_len = before.len + after.len;
            if (total_len <= 256) {
                @memcpy(name_buf[0..before.len], before);
                @memcpy(name_buf[before.len..total_len], after);
                dep = name_buf[0..total_len];
            }
        }
    }

    // Find where version constraints start
    const operators = [_][]const u8{ ">=", "<=", "~=", "!=", "==", ">", "<" };
    var constraint_start: ?usize = null;

    for (operators) |op| {
        if (std.mem.indexOf(u8, dep, op)) |idx| {
            if (constraint_start == null or idx < constraint_start.?) {
                constraint_start = idx;
            }
        }
    }

    const name = if (constraint_start) |start|
        std.mem.trim(u8, dep[0..start], &std.ascii.whitespace)
    else
        std.mem.trim(u8, dep, &std.ascii.whitespace);

    // Parse constraints (comma-separated)
    var constraints = std.ArrayList(VersionConstraint).init(allocator);
    errdefer constraints.deinit();

    if (constraint_start) |start| {
        var constraint_iter = std.mem.splitScalar(u8, dep[start..], ',');
        while (constraint_iter.next()) |constraint| {
            const trimmed = std.mem.trim(u8, constraint, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                try constraints.append(try parseConstraint(trimmed));
            }
        }
    }

    return .{
        .name = name,
        .constraints = try constraints.toOwnedSlice(),
    };
}

// ============================================================================
// Tests
// ============================================================================

test "parseVersion - simple versions" {
    const v1 = try parseVersion("1.0.0");
    try std.testing.expectEqual(@as(u32, 1), v1.major);
    try std.testing.expectEqual(@as(u32, 0), v1.minor);
    try std.testing.expectEqual(@as(u32, 0), v1.patch);

    const v2 = try parseVersion("2.31.0");
    try std.testing.expectEqual(@as(u32, 2), v2.major);
    try std.testing.expectEqual(@as(u32, 31), v2.minor);
    try std.testing.expectEqual(@as(u32, 0), v2.patch);
}

test "parseVersion - two part versions" {
    const v = try parseVersion("3.12");
    try std.testing.expectEqual(@as(u32, 3), v.major);
    try std.testing.expectEqual(@as(u32, 12), v.minor);
    try std.testing.expectEqual(@as(u32, 0), v.patch);
}

test "parseVersion - pre-release alpha" {
    const v = try parseVersion("1.0.0a1");
    try std.testing.expectEqual(@as(u32, 1), v.major);
    try std.testing.expectEqual(Version.PreReleaseType.alpha, v.pre_type.?);
    try std.testing.expectEqual(@as(u32, 1), v.pre_num);
}

test "parseVersion - pre-release beta" {
    const v = try parseVersion("2.0.0b3");
    try std.testing.expectEqual(Version.PreReleaseType.beta, v.pre_type.?);
    try std.testing.expectEqual(@as(u32, 3), v.pre_num);
}

test "parseVersion - pre-release rc" {
    const v = try parseVersion("1.0.0rc1");
    try std.testing.expectEqual(Version.PreReleaseType.rc, v.pre_type.?);
    try std.testing.expectEqual(@as(u32, 1), v.pre_num);
}

test "parseVersion - post release" {
    const v = try parseVersion("1.0.0.post1");
    try std.testing.expectEqual(@as(u32, 1), v.post.?);
}

test "parseVersion - dev release" {
    const v = try parseVersion("1.0.0.dev5");
    try std.testing.expectEqual(@as(u32, 5), v.dev.?);
}

test "Version.compare - basic ordering" {
    const v1 = try parseVersion("1.0.0");
    const v2 = try parseVersion("2.0.0");
    const v3 = try parseVersion("1.1.0");
    const v4 = try parseVersion("1.0.1");

    try std.testing.expectEqual(std.math.Order.lt, v1.compare(v2));
    try std.testing.expectEqual(std.math.Order.lt, v1.compare(v3));
    try std.testing.expectEqual(std.math.Order.lt, v1.compare(v4));
    try std.testing.expectEqual(std.math.Order.gt, v2.compare(v1));
    try std.testing.expectEqual(std.math.Order.eq, v1.compare(v1));
}

test "Version.compare - pre-release ordering" {
    const alpha = try parseVersion("1.0.0a1");
    const beta = try parseVersion("1.0.0b1");
    const rc = try parseVersion("1.0.0rc1");
    const release = try parseVersion("1.0.0");

    try std.testing.expectEqual(std.math.Order.lt, alpha.compare(beta));
    try std.testing.expectEqual(std.math.Order.lt, beta.compare(rc));
    try std.testing.expectEqual(std.math.Order.lt, rc.compare(release));
    try std.testing.expectEqual(std.math.Order.lt, alpha.compare(release));
}

test "Version.compare - post release ordering" {
    const release = try parseVersion("1.0.0");
    const post1 = try parseVersion("1.0.0.post1");
    const post2 = try parseVersion("1.0.0.post2");

    try std.testing.expectEqual(std.math.Order.lt, release.compare(post1));
    try std.testing.expectEqual(std.math.Order.lt, post1.compare(post2));
}

test "Version.compare - dev release ordering" {
    const dev = try parseVersion("1.0.0.dev1");
    const release = try parseVersion("1.0.0");

    try std.testing.expectEqual(std.math.Order.lt, dev.compare(release));
}

test "parseConstraint - operators" {
    const ge = try parseConstraint(">=1.0.0");
    try std.testing.expectEqual(Operator.ge, ge.op);

    const le = try parseConstraint("<=2.0.0");
    try std.testing.expectEqual(Operator.le, le.op);

    const eq = try parseConstraint("==1.5.0");
    try std.testing.expectEqual(Operator.eq, eq.op);

    const ne = try parseConstraint("!=1.0.0");
    try std.testing.expectEqual(Operator.ne, ne.op);

    const compat = try parseConstraint("~=1.4.2");
    try std.testing.expectEqual(Operator.compatible, compat.op);
}

test "Version.satisfies - basic constraints" {
    const v = try parseVersion("1.5.0");

    try std.testing.expect(v.satisfies(try parseConstraint(">=1.0.0")));
    try std.testing.expect(v.satisfies(try parseConstraint("<=2.0.0")));
    try std.testing.expect(v.satisfies(try parseConstraint("==1.5.0")));
    try std.testing.expect(!v.satisfies(try parseConstraint("==1.4.0")));
    try std.testing.expect(v.satisfies(try parseConstraint("!=1.4.0")));
    try std.testing.expect(!v.satisfies(try parseConstraint("!=1.5.0")));
    try std.testing.expect(v.satisfies(try parseConstraint(">1.4.0")));
    try std.testing.expect(v.satisfies(try parseConstraint("<2.0.0")));
}

test "Version.satisfies - compatible release" {
    const v142 = try parseVersion("1.4.2");
    const v143 = try parseVersion("1.4.3");
    const v150 = try parseVersion("1.5.0");
    const v140 = try parseVersion("1.4.0");

    const constraint = try parseConstraint("~=1.4.2");

    try std.testing.expect(v142.satisfies(constraint));
    try std.testing.expect(v143.satisfies(constraint));
    try std.testing.expect(!v150.satisfies(constraint));
    try std.testing.expect(!v140.satisfies(constraint));
}

test "parseDependency - simple package" {
    const allocator = std.testing.allocator;
    const result = try parseDependency(allocator, "requests");
    defer allocator.free(result.constraints);

    try std.testing.expectEqualStrings("requests", result.name);
    try std.testing.expectEqual(@as(usize, 0), result.constraints.len);
}

test "parseDependency - with version constraint" {
    const allocator = std.testing.allocator;
    const result = try parseDependency(allocator, "requests>=2.28.0");
    defer allocator.free(result.constraints);

    try std.testing.expectEqualStrings("requests", result.name);
    try std.testing.expectEqual(@as(usize, 1), result.constraints.len);
    try std.testing.expectEqual(Operator.ge, result.constraints[0].op);
}

test "parseDependency - multiple constraints" {
    const allocator = std.testing.allocator;
    const result = try parseDependency(allocator, "requests>=2.0,<3.0");
    defer allocator.free(result.constraints);

    try std.testing.expectEqualStrings("requests", result.name);
    try std.testing.expectEqual(@as(usize, 2), result.constraints.len);
}
