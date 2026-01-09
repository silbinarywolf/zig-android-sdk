//! Setup the path to various command-line tools available in:
//! - $ANDROID_HOME/ndk/29.0.13113456

const std = @import("std");
const builtin = @import("builtin");
const androidbuild = @import("androidbuild.zig");

const Allocator = std.mem.Allocator;
const ApiLevel = androidbuild.ApiLevel;

/// ie. $ANDROID_HOME
android_sdk_path: []const u8,
/// ie. "27.0.12077973"
version: []const u8,
/// ie. "$ANDROID_HOME/ndk/{ndk_version}"
path: []const u8,
/// ie. "$ANDROID_HOME/ndk/{ndk_version}/toolchains/llvm/prebuilt/{host_os_and_arch}/sysroot"
sysroot_path: []const u8,
/// ie. "$ANDROID_HOME/ndk/{ndk_version}/toolchains/llvm/prebuilt/{host_os_and_arch}/sysroot/usr/include"
include_path: []const u8,

pub const empty: Ndk = .{
    .android_sdk_path = &[0]u8{},
    .version = &[0]u8{},
    .path = &[0]u8{},
    .sysroot_path = &[0]u8{},
    .include_path = &[0]u8{},
};

const NdkError = Allocator.Error || error{NdkFailed};

pub fn init(b: *std.Build, android_sdk_path: []const u8, ndk_version: []const u8, errors: *std.ArrayListUnmanaged([]const u8)) NdkError!Ndk {
    // Get NDK path
    // ie. $ANDROID_HOME/ndk/27.0.12077973
    const android_ndk_path = b.fmt("{s}/ndk/{s}", .{ android_sdk_path, ndk_version });

    const has_ndk: bool = blk: {
        const access_wrapped_error = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
            std.fs.accessAbsolute(android_ndk_path, .{})
        else
            std.Io.Dir.accessAbsolute(b.graph.io, android_ndk_path, .{});
        access_wrapped_error catch |err| switch (err) {
            error.FileNotFound => {
                const message = b.fmt("Android NDK version '{s}' not found. Install it via 'sdkmanager' or Android Studio.", .{
                    ndk_version,
                });
                try errors.append(b.allocator, message);
                break :blk false;
            },
            else => {
                const message = b.fmt("Android NDK version '{s}' had unexpected error: {s} ({s})", .{
                    ndk_version,
                    @errorName(err),
                    android_ndk_path,
                });
                try errors.append(b.allocator, message);
                break :blk false;
            },
        };
        break :blk true;
    };
    if (!has_ndk) {
        return error.NdkFailed;
    }

    const host_os_tag = b.graph.host.result.os.tag;
    const host_os_and_arch: [:0]const u8 = switch (host_os_tag) {
        .windows => "windows-x86_64",
        .linux => "linux-x86_64",
        .macos => "darwin-x86_64",
        else => @panic(b.fmt("unhandled operating system: {}", .{host_os_tag})),
    };

    // Get NDK sysroot path
    // ie. $ANDROID_HOME/ndk/{ndk_version}/toolchains/llvm/prebuilt/{host_os_and_arch}/sysroot
    const ndk_sysroot = b.fmt("{s}/ndk/{s}/toolchains/llvm/prebuilt/{s}/sysroot", .{
        android_sdk_path,
        ndk_version,
        host_os_and_arch,
    });

    // Check if NDK sysroot path is accessible
    const has_ndk_sysroot = blk: {
        const access_wrapped_error = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
            std.fs.accessAbsolute(ndk_sysroot, .{})
        else
            std.Io.Dir.accessAbsolute(b.graph.io, ndk_sysroot, .{});
        access_wrapped_error catch |err| switch (err) {
            error.FileNotFound => {
                const message = b.fmt("Android NDK sysroot '{s}' had unexpected error. Missing at '{s}'", .{
                    ndk_version,
                    ndk_sysroot,
                });
                try errors.append(b.allocator, message);
                break :blk false;
            },
            else => {
                const message = b.fmt("Android NDK sysroot '{s}' had unexpected error: {s}, at: '{s}'", .{
                    ndk_version,
                    @errorName(err),
                    ndk_sysroot,
                });
                try errors.append(b.allocator, message);
                break :blk false;
            },
        };
        break :blk true;
    };
    if (!has_ndk_sysroot) {
        return error.NdkFailed;
    }

    const ndk: Ndk = .{
        .android_sdk_path = android_sdk_path,
        .path = android_ndk_path,
        .version = ndk_version,
        .sysroot_path = ndk_sysroot,
        .include_path = b.fmt("{s}/usr/include", .{ndk_sysroot}),
    };
    return ndk;
}

pub fn validateApiLevel(ndk: *const Ndk, b: *std.Build, api_level: ApiLevel, errors: *std.ArrayListUnmanaged([]const u8)) void {
    if (ndk.android_sdk_path.len == 0 or ndk.sysroot_path.len == 0) {
        @panic("Should not call validateApiLevel if NDK path is not set");
    }

    // Check if NDK sysroot/usr/lib/{target}/{api_level} path is accessible
    _ = blk: {
        // "x86" has existed since Android 4.1 (API version 16)
        const x86_system_target = "i686-linux-android";
        const ndk_sysroot_target_api_version = b.fmt("{s}/usr/lib/{s}/{d}", .{ ndk.sysroot_path, x86_system_target, @intFromEnum(api_level) });

        const access_wrapped_error = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
            std.fs.accessAbsolute(ndk_sysroot_target_api_version, .{})
        else
            std.Io.Dir.accessAbsolute(b.graph.io, ndk_sysroot_target_api_version, .{});
        access_wrapped_error catch |err| switch (err) {
            error.FileNotFound => {
                const message = b.fmt("Android NDK version '{s}' does not support API Level {d}. No folder at '{s}'", .{
                    ndk.version,
                    @intFromEnum(api_level),
                    ndk_sysroot_target_api_version,
                });
                errors.append(b.allocator, message) catch @panic("OOM");
                break :blk false;
            },
            else => {
                const message = b.fmt("Android NDK version '{s}' API Level {d} had unexpected error: {s}, at: '{s}'", .{
                    ndk.version,
                    @intFromEnum(api_level),
                    @errorName(err),
                    ndk_sysroot_target_api_version,
                });
                errors.append(b.allocator, message) catch @panic("OOM");
                break :blk false;
            },
        };
        break :blk true;
    };

    // Check if platforms/android-{api-level}/android.jar exists
    _ = blk: {
        // Get root jar path
        const root_jar = b.pathResolve(&[_][]const u8{
            ndk.android_sdk_path,
            "platforms",
            b.fmt("android-{d}", .{@intFromEnum(api_level)}),
            "android.jar",
        });
        const access_wrapped_error = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
            std.fs.accessAbsolute(root_jar, .{})
        else
            std.Io.Dir.accessAbsolute(b.graph.io, root_jar, .{});
        access_wrapped_error catch |err| switch (err) {
            error.FileNotFound => {
                const message = b.fmt("Android API level {d} not installed. Unable to find '{s}'", .{
                    @intFromEnum(api_level),
                    root_jar,
                });
                errors.append(b.allocator, message) catch @panic("OOM");
                break :blk false;
            },
            else => {
                const message = b.fmt("Android API level {d} had unexpected error: {s}, at: '{s}'", .{
                    @intFromEnum(api_level),
                    @errorName(err),
                    root_jar,
                });
                errors.append(b.allocator, message) catch @panic("OOM");
                break :blk false;
            },
        };
        break :blk true;
    };
}

pub const Ndk = @This();
