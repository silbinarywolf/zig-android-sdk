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

    // Load translate_c module
    const translate_c_dep_name = "translate_c";
    const translate_c_import = b.lazyImport(@This(), translate_c_dep_name) orelse return;
    const translate_c = b.lazyDependency(translate_c_dep_name, .{}) orelse return;
    const Translator = translate_c_import.Translator;

    for (targets) |target| {
        if (!target.result.abi.isAndroid()) {
            std.debug.panic("For testing Android builds only. Target(s) should be Android not: {t}", .{target.result.abi});
        }

        const app_module = b.createModule(.{
            .root_source_file = b.path("src/translate_c_dep_main.zig"),
            .target = target,
            .optimize = optimize,
        });

        // testTranslateCExternal
        {
            const translator: Translator = .init(translate_c, .{
                .c_source_file = b.addWriteFiles().add("android_c.h",
                    \\#include <android/log.h> /* For main module */
                ),
                .target = target,
                .optimize = optimize,
            });
            app_module.addImport("translate_c_external", translator.mod);
            log.info("testTranslateCExternal({t}): add import 'translate_c_external'", .{target.result.cpu.arch});
        }

        // testTranslateCExternal for sub-sub-module, this test should ideally catch recursion with imported modules
        {
            const single_depth_mod = b.createModule(.{
                .root_source_file = b.path("src/translate_c_dep_single_depth_module.zig"),
                .target = target,
                .optimize = optimize,
            });
            const double_depth_mod = b.createModule(.{
                .root_source_file = b.path("src/translate_c_dep_double_depth_module.zig"),
                .target = target,
                .optimize = optimize,
            });
            single_depth_mod.addImport("double_depth", double_depth_mod);

            const translator: Translator = .init(translate_c, .{
                .c_source_file = b.addWriteFiles().add("android_sub_c.h",
                    \\#include <android/log.h> /* For sub-module (two-depth from main) */
                ),
                .target = target,
                .optimize = optimize,
            });
            double_depth_mod.addImport("translate_c_external_recursive", translator.mod);
            app_module.addImport("single_depth", single_depth_mod);
            log.info("testTranslateCExternalSubModule({t}): add import 'translate_c_external_recursive' a sub-sub-module of main", .{target.result.cpu.arch});
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
