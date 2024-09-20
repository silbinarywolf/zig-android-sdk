const std = @import("std");
const builtin = @import("builtin");

const Target = std.Target;
const ResolvedTarget = std.Build.ResolvedTarget;
const LazyPath = std.Build.LazyPath;

/// API Level is an enum the maps the Android OS version to the API level
///
/// https://en.wikipedia.org/wiki/Android_version_history
/// https://apilevels.com/
pub const APILevel = enum(u32) {
    /// KitKat (2013)
    /// Android 4.4 = 19
    android4_4 = 19,
    /// Lollipop (2014)
    android5 = 21,
    /// Marshmallow (2015)
    android6 = 23,
    /// Nougat (2016)
    android7 = 24,
    /// Oreo (2017)
    android8 = 26,
    /// Quince Tart (2018)
    android9 = 28,
    /// Quince Tart (2019)
    android10 = 29,
    /// Red Velvet Cake (2020)
    android11 = 30,
    /// Snow Cone (2021)
    android12 = 31,
    /// Tiramisu (2022)
    android13 = 33,
    /// Upside Down Cake (2023)
    android14 = 34,
    /// Vanilla Ice Cream
    android15 = 35,
    // allow custom overrides (incase this library is not up to date with the latest android version)
    _,
};

pub const KeyStore = struct {
    file: LazyPath,
    password: []const u8,
};

pub fn getAndroidTriple(target: ResolvedTarget) error{InvalidAndroidTarget}![]const u8 {
    if (target.result.abi != .android) return error.InvalidAndroidTarget;
    return switch (target.result.cpu.arch) {
        .x86 => "i686-linux-android",
        .x86_64 => "x86_64-linux-android",
        .arm => "arm-linux-androideabi",
        .aarch64 => "aarch64-linux-android",
        .riscv64 => "riscv64-linux-android",
        else => error.InvalidAndroidTarget,
    };
}

/// Will return a slice of Android targets
/// - If -Dandroid=true, return all Android targets (x86, x86_64, aarch64, etc)
/// - If -Dtarget=aarch64-linux-android, return a slice with the one specified Android target
///
/// If none of the above, then return a zero length slice.
pub fn standardTargets(b: *std.Build, target: ResolvedTarget) []ResolvedTarget {
    const all_targets = b.option(bool, "android", "if true, build for all Android targets (x86, x86_64, aarch64, etc)") orelse false;
    if (all_targets) {
        return getAllAndroidTargets(b);
    }
    if (target.result.abi != .android) {
        return &[0]ResolvedTarget{};
    }
    if (target.result.os.tag != .linux) {
        const linuxTriple = target.result.linuxTriple(b.allocator) catch @panic("OOM");
        @panic(b.fmt("unsupported Android target given: {s}, expected linux to be target OS", .{linuxTriple}));
    }
    for (supported_android_targets) |android_target| {
        if (target.result.cpu.arch == android_target.cpu_arch) {
            const resolved_targets = b.allocator.alloc(ResolvedTarget, 1) catch @panic("OOM");
            resolved_targets[0] = b.resolveTargetQuery(android_target.queryTarget());
            return resolved_targets;
        }
    }
    const linuxTriple = target.result.linuxTriple(b.allocator) catch @panic("OOM");
    @panic(b.fmt("unsupported Android target given: {s}", .{linuxTriple}));
}

fn getAllAndroidTargets(b: *std.Build) []ResolvedTarget {
    const resolved_targets = b.allocator.alloc(ResolvedTarget, supported_android_targets.len) catch @panic("OOM");
    for (supported_android_targets, 0..) |android_target, i| {
        const resolved_target = b.resolveTargetQuery(android_target.queryTarget());
        resolved_targets[i] = resolved_target;
    }
    return resolved_targets;
}

pub fn runNameContext(comptime name: []const u8) []const u8 {
    return "zig-android-sdk " ++ name;
}

const log = std.log.scoped(.@"zig-android-sdk");

pub fn printErrorsAndExit(message: []const u8, errors: []const []const u8) noreturn {
    nosuspend {
        log.err("{s}", .{message});
        const stderr = std.io.getStdErr().writer();
        std.debug.lockStdErr();
        defer std.debug.unlockStdErr();
        for (errors) |err| {
            var it = std.mem.splitScalar(u8, err, '\n');
            const headline = it.next() orelse continue;
            stderr.writeAll("- ") catch {};
            stderr.writeAll(headline) catch {};
            stderr.writeByte('\n') catch {};
            while (it.next()) |line| {
                stderr.writeAll("  ") catch {};
                stderr.writeAll(line) catch {};
                stderr.writeByte('\n') catch {};
            }
        }
        stderr.writeByte('\n') catch {};
    }
    std.process.exit(1);
}

const AndroidTargetQuery = struct {
    cpu_arch: Target.Cpu.Arch,
    cpu_features_add: Target.Cpu.Feature.Set = Target.Cpu.Feature.Set.empty,

    fn queryTarget(android_target: AndroidTargetQuery) Target.Query {
        return .{
            .os_tag = .linux,
            .cpu_model = .baseline,
            .abi = .android,
            .cpu_arch = android_target.cpu_arch,
            .cpu_features_add = android_target.cpu_features_add,
        };
    }
};

const supported_android_targets = [_]AndroidTargetQuery{
    .{
        // i686-linux-android
        .cpu_arch = .x86,
    },
    .{
        // x86_64-linux-android
        .cpu_arch = .x86_64,
    },
    .{
        // aarch64-linux-android
        .cpu_arch = .aarch64,
        .cpu_features_add = Target.aarch64.featureSet(&.{.v8a}),
    },
    // TODO(jae): 2024-09-08
    // This doesn't work for compiling C code like SDL2 or OpenXR due to "__ARM_ARCH" not being "7"
    // or similar. I might be messing something up here but not sure.
    // .{
    //     // arm-linux-androideabi
    //     .cpu_arch = .arm,
    //     .cpu_features_add = Target.arm.featureSet(&.{.v7a}),
    // },
};
