//! Test that using translate-c as a dependency works with the Zig Android SDK

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.build);

const android = @import("android");

/// Make sure this is a stable version of Zig
const is_latest_stable_zig = builtin.zig_version.pre == null and
    builtin.zig_version.major == 0 and builtin.zig_version.minor >= 16;

pub fn build(b: *std.Build) void {
    const exe_name: []const u8 = "translate_c_test";
    const root_target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const android_targets = android.standardTargets(b, root_target);

    if (!is_latest_stable_zig) {
        log.warn("skipping translate-c as dependency test for Zig {}", .{builtin.zig_version_string});
        return;
    }

    var root_target_single = [_]std.Build.ResolvedTarget{root_target};
    const targets: []std.Build.ResolvedTarget = if (android_targets.len == 0)
        root_target_single[0..]
    else
        android_targets;

    const android_apk: ?*android.Apk = blk: {
        if (android_targets.len == 0) break :blk null;

        const android_sdk = android.Sdk.create(b, .{});
        const apk = android_sdk.createApk(.{
            .name = exe_name,
            .api_level = .android15,
            .build_tools_version = "35.0.1",
            .ndk_version = "29.0.13113456",
        });
        const key_store_file = android_sdk.createKeyStore(.example);
        apk.setKeyStore(key_store_file);
        apk.setAndroidManifest(b.path("android/AndroidManifest.xml"));
        apk.addResourceDirectory(b.path("android/res"));

        break :blk apk;
    };

    for (targets) |target| {
        if (!target.result.abi.isAndroid()) {
            std.debug.panic("For testing Android builds only. Target(s) should be Android not: {t}", .{target.result.abi});
        }

        const app_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/translate_c_dep_main.zig"),
        });

        // Must be stable release of Zig *and* 0.16.X or higher
        {
            const translate_c_external_mod = testTranslateCExternal(b, target, optimize) orelse return;
            app_module.addImport("translate_c_external", translate_c_external_mod);
            log.info("testTranslateCExternal: add import 'translate_c_external' to {t}", .{target.result.cpu.arch});
        }

        const libmain = b.addLibrary(.{
            .name = "main",
            .root_module = app_module,
            .linkage = .dynamic,
        });

        const apk: *android.Apk = android_apk orelse @panic("Android APK should be initialized");
        apk.addArtifact(libmain);
    }
    if (android_apk) |apk| {
        const installed_apk = apk.addInstallApk();
        b.getInstallStep().dependOn(&installed_apk.step);
    }
}

/// Test the Translate-C external dependency version
fn testTranslateCExternal(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?*std.Build.Module {
    const translate_c_dep_name = "translate_c";
    const translate_c_import = b.lazyImport(@This(), translate_c_dep_name) orelse return null;
    const translate_c = b.lazyDependency(translate_c_dep_name, .{}) orelse return null;
    const Translator = translate_c_import.Translator;

    const trans_libandroid: Translator = .init(translate_c, .{
        .c_source_file = b.addWriteFiles().add("android_c.h",
            \\#include <android/log.h>
        ),
        .target = target,
        .optimize = optimize,
    });
    return trans_libandroid.mod;
}
