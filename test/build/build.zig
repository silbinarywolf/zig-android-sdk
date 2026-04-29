//! This module is for testing that we implemented certain build features and to at least make sure
//! there is code coverage for new APIs added.
//!
//! TODO(Jae): 2026-04-12
//! Ideally adding functions to also validate the output APK file would be nice too.

const std = @import("std");
const builtin = @import("builtin");

const android = @import("android");

pub fn build(b: *std.Build) void {
    const exe_name: []const u8 = "build_test";
    const root_target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const android_targets = android.standardTargets(b, root_target);

    // NOTE(jae): 2026-04-12
    // Run it *after* the "standardTargets" call
    testLazyImportAndResolveTargets(b, root_target);

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

        testAddLibraryFile(b, apk);

        break :blk apk;
    };

    for (targets) |target| {
        const translate_c_vendored_mod = testTranslateCVendor(b, target, optimize) orelse return;
        const translate_c_external_mod = testTranslateCExternal(b, target, optimize) orelse return;

        const app_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/build_test_main.zig"),
            .imports = &.{
                .{
                    .name = "translate_c_internal",
                    .module = translate_c_vendored_mod,
                },
                .{
                    .name = "translate_c_external",
                    .module = translate_c_external_mod,
                },
            },
        });

        var exe: *std.Build.Step.Compile = if (target.result.abi.isAndroid()) b.addLibrary(.{
            .name = "main",
            .root_module = app_module,
            .linkage = .dynamic,
        }) else b.addExecutable(.{
            .name = exe_name,
            .root_module = app_module,
        });

        // if building as library for Android, add this target
        // NOTE: Android has different CPU targets so you need to build a version of your
        //       code for x86, x86_64, arm, arm64 and more
        if (target.result.abi.isAndroid()) {
            const apk: *android.Apk = android_apk orelse @panic("Android APK should be initialized");
            const android_dep = b.dependency("android", .{
                .optimize = optimize,
                .target = target,
            });
            exe.root_module.addImport("android", android_dep.module("android"));

            apk.addArtifact(exe);
        } else {
            b.installArtifact(exe);

            // If only 1 target, add "run" step
            if (targets.len == 1) {
                const run_step = b.step("run", "Run the application");
                const run_cmd = b.addRunArtifact(exe);
                run_step.dependOn(&run_cmd.step);
            }
        }
    }
    if (android_apk) |apk| {
        testInstallAndAddRunStep(b, apk);
    }
}

/// Test the Translate-C vendored copy, this will eventually be deprecated and removed from Zig but for now exists in 0.16.X
fn testTranslateCVendor(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?*std.Build.Module {
    const trans_c = b.addTranslateC(.{
        .root_source_file = b.addWriteFiles().add("android_c.h",
            \\#include <android/log.h>
        ),
        .target = target,
        .optimize = optimize,
    });
    return trans_c.createModule();
}

/// Test the Translate-C external dependency version
fn testTranslateCExternal(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?*std.Build.Module {
    const translate_c_import = b.lazyImport(@This(), "translate_c") orelse return null;
    const translate_c = b.lazyDependency("translate_c", .{}) orelse return null;
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

/// Test calling lazyImport and then calling "resolveTargets"
///
/// PR: https://github.com/silbinarywolf/zig-android-sdk/pull/83
fn testLazyImportAndResolveTargets(b: *std.Build, root_target: std.Build.ResolvedTarget) void {
    const all_android_targets = true;
    const android_targets: []std.Build.ResolvedTarget = blk: {
        if (all_android_targets or root_target.result.abi.isAndroid()) {
            if (b.lazyImport(@This(), "lazy_android")) |lazy_android| {
                break :blk lazy_android.resolveTargets(b, .{
                    .default_target = root_target,
                    .all_targets = true,
                });
            }
        }
        break :blk &[0]std.Build.ResolvedTarget{};
    };
    if (android_targets.len != 4) @panic("expected 'resolveTargets' it to return 4 Android targets");
}

/// Test the addLibraryFile functionality
///
/// Requested feature here: https://github.com/silbinarywolf/zig-android-sdk/issues/77
fn testAddLibraryFile(b: *std.Build, apk: *android.Apk) void {
    const vulkan_validation_dep = b.lazyDependency("vulkan_validation", .{}) orelse return;
    apk.addLibraryFile(.arm64_v8a, vulkan_validation_dep.path("arm64-v8a/libVkLayer_khronos_validation.so"));
    apk.addLibraryFile(.armeabi_v7a, vulkan_validation_dep.path("armeabi-v7a/libVkLayer_khronos_validation.so"));
    apk.addLibraryFile(.x86, vulkan_validation_dep.path("x86/libVkLayer_khronos_validation.so"));
    apk.addLibraryFile(.x86_64, vulkan_validation_dep.path("x86_64/libVkLayer_khronos_validation.so"));
}

fn testInstallAndAddRunStep(b: *std.Build, apk: *android.Apk) void {
    const installed_apk = apk.addInstallApk();
    b.getInstallStep().dependOn(&installed_apk.step);

    const android_sdk = apk.sdk;
    const run_step = b.step("run", "Install and run the application on an Android device");
    const adb_install = android_sdk.addAdbInstall(installed_apk.source);
    const adb_start = android_sdk.addAdbStart("com.zig.build_test/android.app.NativeActivity");
    adb_start.step.dependOn(&adb_install.step);
    run_step.dependOn(&adb_start.step);
}
