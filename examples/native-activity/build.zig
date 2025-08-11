const std = @import("std");
const builtin = @import("builtin");
const android = @import("android");

pub fn build(b: *std.Build) void {

    // const target = b.standardTargetOptions(.{});
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
    });
    const optimize = b.standardOptimizeOption(.{});

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

    const exe = b.addSharedLibrary(.{
        .name = "native-activity",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
        .link_libc = true,
    });
    b.installArtifact(exe);

    exe.addIncludePath(.{ .cwd_relative = b.fmt("{s}/sources/android/native_app_glue", .{apk.ndk.path}) });
    exe.addCSourceFile(.{
        .file = .{ .cwd_relative = b.fmt("{s}/sources/android/native_app_glue/android_native_app_glue.c", .{apk.ndk.path}) },
    });
    exe.addCSourceFile(.{
        .file = b.path("src/helper.cpp"),
    });
    // exe.target_link_options(${TARGET_NAME} PUBLIC -u ANativeActivity_onCreate)
    const libs = [_][]const u8{
        "android",
        "EGL",
        "GLESv1_CM",
        "log",
    };
    for (libs) |lib| {
        exe.linkSystemLibrary(lib);
    }

    const android_dep = b.dependency("android", .{
        .optimize = optimize,
        .target = target,
    });
    exe.root_module.addImport("android", android_dep.module("android"));

    apk.addArtifact(exe);

    const installed_apk = apk.addInstallApk();
    b.getInstallStep().dependOn(&installed_apk.step);

    const run_step = b.step("run", "Install and run the application on an Android device");
    const adb_install = android_sdk.addAdbInstall(installed_apk.source);
    const adb_start = android_sdk.addAdbStart("com.zig.native_activity/android.app.NativeActivity");
    adb_start.step.dependOn(&adb_install.step);
    run_step.dependOn(&adb_start.step);
}
