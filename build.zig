const std = @import("std");
const builtin = @import("builtin");
const androidbuild = @import("src/androidbuild/androidbuild.zig");

// Expose Android build functionality for use in your build.zig

// TODO: rename tools.zig to Sdk.zig
pub const Sdk = @import("src/androidbuild/tools.zig");
pub const Apk = @import("src/androidbuild/apk.zig");
pub const ApiLevel = androidbuild.ApiLevel;
pub const standardTargets = androidbuild.standardTargets;

// Deprecated exposed fields

/// Deprecated: Use ApiLevel
pub const APILevel = @compileError("use android.ApiLevel instead of android.APILevel");
/// Deprecated: Use Sdk instead
pub const Tools = @compileError("Use android.Sdk instead of android.Tools");
/// Deprecated: Use Apk.Options instead.
pub const ToolsOptions = @compileError("Use android.Sdk.Options instead of android.Apk.Options with the Sdk.createApk method");
/// Deprecated: Use Sdk.CreateKey instead.
pub const CreateKey = @compileError("Use android.Sdk.CreateKey instead of android.CreateKey. Change 'android_tools.createKeyStore(android.CreateKey.example())' to 'android_sdk.createKeyStore(.example)'");
/// Deprecated: Use Apk not APK
pub const APK = @compileError("Use android.Apk instead of android.APK");

/// NOTE: As well as providing the "android" module this declaration is required so this can be imported by other build.zig files
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create stub of builtin options.
    // This is discovered and then replaced by "Apk" in the build process
    const android_builtin_options = std.Build.addOptions(b);
    android_builtin_options.addOption([:0]const u8, "package_name", "");
    const android_builtin_module = android_builtin_options.createModule();

    // Create android module
    const android_module = b.addModule("android", .{
        .root_source_file = b.path("src/android/android.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ndk_module = b.createModule(.{
        .root_source_file = b.path("src/android/ndk/ndk.zig"),
        .target = target,
        .optimize = optimize,
    });
    android_module.addImport("ndk", ndk_module);
    android_module.addImport("android_builtin", android_builtin_module);

    // Add backwards compatibility modules
    if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 14) {
        // Deprecated: Allow older Zig builds to work
        var zig014 = b.createModule(.{
            .root_source_file = b.path("src/android/zig014/zig014.zig"),
            .target = target,
            .optimize = optimize,
        });
        zig014.addImport("ndk", ndk_module);
        zig014.addImport("android_builtin", android_builtin_module);
        android_module.addImport("zig014", zig014);
    }
    if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15) {
        // Add as a module to deal with @Type(.enum_literal) being deprecated
        const zig015 = b.createModule(.{
            .root_source_file = b.path("src/android/zig015/zig015.zig"),
            .target = target,
            .optimize = optimize,
        });
        android_module.addImport("zig015", zig015);
    }
    if (builtin.zig_version.major == 0 and builtin.zig_version.minor >= 16) {
        // Add as a module to deal with @Type(.enum_literal) being deprecated
        const zig016 = b.createModule(.{
            .root_source_file = b.path("src/android/zig016/zig016.zig"),
            .target = target,
            .optimize = optimize,
        });
        android_module.addImport("zig016", zig016);
    }

    android_module.linkSystemLibrary("log", .{});
}
