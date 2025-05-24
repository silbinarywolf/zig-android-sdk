const std = @import("std");
const androidbuild = @import("src/androidbuild/androidbuild.zig");

// Expose Android build functionality for use in your build.zig

// TODO: rename tools.zig to Sdk.zig
pub const Sdk = @import("src/androidbuild/tools.zig");
pub const Apk = @import("src/androidbuild/apk.zig");
pub const APILevel = androidbuild.APILevel; // TODO(jae): 2025-03-13: Consider deprecating and using 'ApiLevel' to be conventional to Zig
pub const standardTargets = androidbuild.standardTargets;

// Deprecated exposes fields

/// Deprecated: Use Sdk instead
pub const Tools = @compileError("Use android.Sdk instead of android.Tools");
/// Deprecated: Use Apk.Options instead.
pub const ToolsOptions = @compileError("Use android.Sdk.Options instead of android.Apk.Options with the Sdk.createApk method");
/// Deprecated: Use Sdk.CreateKey instead.
pub const CreateKey = @compileError("Use android.Sdk.CreateKey instead of android.CreateKey");
/// Deprecated: Use Apk not APK
pub const APK = @compileError("Use android.Apk instead of android.APK");

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
    // This is discovered and then replaced by "Apk" in the build process
    const android_builtin_options = std.Build.addOptions(b);
    android_builtin_options.addOption([:0]const u8, "package_name", "");
    module.addImport("android_builtin", android_builtin_options.createModule());

    module.linkSystemLibrary("log", .{});
}
