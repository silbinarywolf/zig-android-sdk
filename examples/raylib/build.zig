const android = @import("android");
const std = @import("std");

//This is targeting android version 10 / API level 29.
//Change the value here and in android/AndroidManifest.xml to target your desired API level
const android_version: android.APILevel = .android10;
const android_api = std.fmt.comptimePrint("{}", .{@intFromEnum(android_version)});
const exe_name = "raylib";

pub fn build(b: *std.Build) void {
    const root_target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const android_targets = android.standardTargets(b, root_target);

    var root_target_single = [_]std.Build.ResolvedTarget{root_target};
    const targets: []std.Build.ResolvedTarget = if (android_targets.len == 0)
        root_target_single[0..]
    else
        android_targets;

    const android_apk: ?*android.APK = blk: {
        if (android_targets.len == 0) {
            break :blk null;
        }
        const android_tools = android.Tools.create(b, .{
            .api_level = android_version,
            .build_tools_version = "35.0.1",
            .ndk_version = "29.0.13113456",
        });
        const apk = android.APK.create(b, android_tools);

        const key_store_file = android_tools.createKeyStore(android.CreateKey.example());
        apk.setKeyStore(key_store_file);
        apk.setAndroidManifest(b.path("android/AndroidManifest.xml"));
        apk.addResourceDirectory(b.path("android/res"));

        break :blk apk;
    };

    for (targets) |target| {
        const lib_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        const lib = b.addLibrary(.{
            .linkage = .dynamic,
            .name = exe_name,
            .root_module = lib_mod,
        });
        lib.linkLibC();
        b.installArtifact(lib);

        const android_ndk_path = if(android_apk) |apk| (b.fmt("{s}/ndk/{s}", .{ apk.tools.android_sdk_path, apk.tools.ndk_version })) else "";
        const raylib_dep = if (target.result.abi.isAndroid()) (
             b.dependency("raylib_zig", .{ 
                .target = target, 
                .optimize = optimize, 
                .android_api_version = @as([]const u8, android_api), 
                .android_ndk = @as([]const u8, android_ndk_path),
        })) else (
            b.dependency("raylib_zig", .{
                .target = target,
                .optimize = optimize,
                .shared = true
        }));
        const raylib_artifact = raylib_dep.artifact("raylib");
        lib.linkLibrary(raylib_artifact);
        const raylib_mod = raylib_dep.module("raylib");
        lib.root_module.addImport("raylib", raylib_mod);

        if (target.result.abi.isAndroid()) {
            const apk: *android.APK = android_apk orelse @panic("Android APK should be initialized");
            const android_dep = b.dependency("android", .{
                .optimize = optimize,
                .target = target,
            });
            lib.root_module.linkSystemLibrary("android", .{ .preferred_link_mode = .dynamic });
            lib.root_module.addImport("android", android_dep.module("android"));

            const native_app_glue_dir: std.Build.LazyPath = .{ .cwd_relative = b.fmt("{s}/sources/android/native_app_glue", .{android_ndk_path}) };
            lib.root_module.addCSourceFile(.{ .file = native_app_glue_dir.path(b, "android_native_app_glue.c") });
            lib.root_module.addIncludePath(native_app_glue_dir);

            lib.root_module.linkSystemLibrary("log", .{ .preferred_link_mode = .dynamic });
            apk.addArtifact(lib);
        } else {
            const exe = b.addExecutable(.{ .name = exe_name, .optimize = optimize, .root_module = lib_mod });
            b.installArtifact(exe);

            const run_exe = b.addRunArtifact(exe);
            const run_step = b.step("run", "Run the application");
            run_step.dependOn(&run_exe.step);
        }
    }
    if (android_apk) |apk| {
        apk.installApk();
    }
}
