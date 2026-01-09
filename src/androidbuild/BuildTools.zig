//! Setup the path to various command-line tools available in:
//! - $ANDROID_HOME/build-tools/35.0.0

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

aapt2: []const u8,
zipalign: []const u8,
/// d8 is *.bat or shell script that requires "java"/"java.exe" to exist in your PATH
d8: []const u8,
/// apksigner is *.bat or shell script that requires "java"/"java.exe" to exist in your PATH
apksigner: []const u8,

pub const empty: BuildTools = .{
    .aapt2 = &[0]u8{},
    .zipalign = &[0]u8{},
    .d8 = &[0]u8{},
    .apksigner = &[0]u8{},
};

const BuildToolError = Allocator.Error || error{BuildToolFailed};

pub fn init(b: *std.Build, android_sdk_path: []const u8, build_tools_version: []const u8, errors: *std.ArrayListUnmanaged([]const u8)) BuildToolError!BuildTools {
    const prev_errors_len = errors.items.len;

    // Get build tools path
    // ie. $ANDROID_HOME/build-tools/35.0.0
    const build_tools_path = b.pathResolve(&[_][]const u8{ android_sdk_path, "build-tools", build_tools_version });

    // TODO(jae): 2025-05-24
    // We could validate build_tool_version to ensure its 3 numbers with dots seperating
    // ie. "35.0.0"

    // Check if build tools path is accessible
    // ie. $ANDROID_HOME/build-tools/35.0.0
    const access_wrapped_error = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
        std.fs.accessAbsolute(build_tools_path, .{})
    else
        std.Io.Dir.accessAbsolute(b.graph.io, build_tools_path, .{});
    access_wrapped_error catch |err| switch (err) {
        error.FileNotFound => {
            const message = b.fmt("Android Build Tool version '{s}' not found. Install it via 'sdkmanager' or Android Studio.", .{
                build_tools_version,
            });
            errors.append(b.allocator, message) catch @panic("OOM");
        },
        else => {
            const message = b.fmt("Android Build Tool version '{s}' had unexpected error: {s}", .{
                build_tools_version,
                @errorName(err),
            });
            errors.append(b.allocator, message) catch @panic("OOM");
        },
    };
    if (errors.items.len != prev_errors_len) {
        return error.BuildToolFailed;
    }

    const host_os_tag = b.graph.host.result.os.tag;
    const exe_suffix = if (host_os_tag == .windows) ".exe" else "";
    const bat_suffix = if (host_os_tag == .windows) ".bat" else "";
    return .{
        .aapt2 = b.pathResolve(&[_][]const u8{
            build_tools_path, b.fmt("aapt2{s}", .{exe_suffix}),
        }),
        .zipalign = b.pathResolve(&[_][]const u8{
            build_tools_path, b.fmt("zipalign{s}", .{exe_suffix}),
        }),
        // d8/apksigner are *.bat or shell scripts that require "java"/"java.exe" to exist in
        // your PATH
        .d8 = b.pathResolve(&[_][]const u8{
            build_tools_path, b.fmt("d8{s}", .{bat_suffix}),
        }),
        .apksigner = b.pathResolve(&[_][]const u8{
            build_tools_path, b.fmt("apksigner{s}", .{bat_suffix}),
        }),
    };
}

pub const BuildTools = @This();
