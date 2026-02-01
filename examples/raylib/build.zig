const android = @import("android");
const std = @import("std");

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

    const android_apk: ?*android.Apk = blk: {
        if (android_targets.len == 0) break :blk null;

        const android_sdk = android.Sdk.create(b, .{});
        const apk = android_sdk.createApk(.{
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
        const lib_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const lib = b.addLibrary(.{
            .linkage = .dynamic,
            .name = exe_name,
            .root_module = lib_mod,
        });
        b.installArtifact(lib);

        const raylib_dep = if (android_apk) |apk|
            b.dependency("raylib_zig", .{
                .target = target,
                .optimize = optimize,
                .android_api_version = @as([]const u8, b.fmt("{}", .{@intFromEnum(apk.api_level)})),
                .android_ndk = @as([]const u8, apk.ndk.path),
            })
        else
            b.dependency("raylib_zig", .{
                .target = target,
                .optimize = optimize,
                .linkage = std.builtin.LinkMode.dynamic,
            });

        const raylib_artifact = raylib_dep.artifact("raylib");
        lib.root_module.linkLibrary(raylib_artifact);
        const raylib_mod = raylib_dep.module("raylib");
        lib.root_module.addImport("raylib", raylib_mod);

        if (android_apk) |apk| {
            const android_dep = b.dependency("android", .{
                .target = target,
                .optimize = optimize,
            });
            lib.root_module.addImport("android", android_dep.module("android"));
            lib.root_module.linkSystemLibrary("android", .{});

            const native_app_glue_dir: std.Build.LazyPath = .{ .cwd_relative = b.fmt("{s}/sources/android/native_app_glue", .{apk.ndk.path}) };
            lib.root_module.addCSourceFile(.{ .file = native_app_glue_dir.path(b, "android_native_app_glue.c") });
            lib.root_module.addIncludePath(native_app_glue_dir);
            apk.addArtifact(lib);
        } else {
            const exe = b.addExecutable(.{ .name = exe_name, .root_module = lib_mod });
            b.installArtifact(exe);

            const run_exe = b.addRunArtifact(exe);
            const run_step = b.step("run", "Run the application");
            run_step.dependOn(&run_exe.step);
        }
    }
    if (android_apk) |apk| {
        const installed_apk = apk.addInstallApk();
        b.getInstallStep().dependOn(&installed_apk.step);

        const android_sdk = apk.sdk;
        const run_step = b.step("run", "Install and run the application on an Android device");
        const adb_install = android_sdk.addAdbInstall(installed_apk.source);
        const adb_start = android_sdk.addAdbStart("com.zig.raylib/android.app.NativeActivity");
        adb_start.step.dependOn(&adb_install.step);
        run_step.dependOn(&adb_start.step);
    }
}
