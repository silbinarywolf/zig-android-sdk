const std = @import("std");
const androidbuild = @import("src/androidbuild/androidbuild.zig");
const apk = @import("src/androidbuild/apk.zig");
const tools = @import("src/androidbuild/tools.zig");

// Expose Android build functionality for use in your build.zig

pub const ToolsOptions = tools.ToolsOptions;
pub const Tools = tools.Tools;
pub const APK = apk.APK;
pub const APILevel = androidbuild.APILevel;
pub const CreateKey = tools.CreateKey;
pub const standardTargets = androidbuild.standardTargets;

/// NOTE: As well as providing the "android" module this declaration is required so this can be imported by other build.zig files
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("android", .{
        .root_source_file = b.path("src/android/android.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create stub of builtin options.
    // This is discovered and then replace in src/androidbuild/apk.zig
    const android_builtin_options = std.Build.addOptions(b);
    android_builtin_options.addOption([:0]const u8, "package_name", "");
    module.addImport("android_builtin", android_builtin_options.createModule());

    module.linkSystemLibrary("log", .{});
}
