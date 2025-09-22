const std = @import("std");
const builtin = @import("builtin");
const android = @import("android");

pub fn build(b: *std.Build) void {
    const exe_name: []const u8 = "minimal";
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
        apk.addAssetsDirectory(b.path("android/assets"));

        // Add Java files
        // - If you have 'android:hasCode="false"' in your AndroidManifest.xml then no Java files are required
        //   see: https://developer.android.com/ndk/samples/sample_na
        //
        //   WARNING: If you do not provide Java files AND android:hasCode="false" isn't explicitly set, then you may get the following error on "adb install"
        //      Scanning Failed.: Package /data/app/base.apk code is missing]
        //
        // apk.addJavaSourceFile(.{ .file = b.path("android/src/X.java") });
        break :blk apk;
    };

    for (targets) |target| {
        const app_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/minimal.zig"),
        });

        var exe: *std.Build.Step.Compile = if (target.result.abi.isAndroid()) b.addLibrary(.{
            .name = exe_name,
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
        const installed_apk = apk.addInstallApk();
        b.getInstallStep().dependOn(&installed_apk.step);

        const android_sdk = apk.sdk;
        const run_step = b.step("run", "Install and run the application on an Android device");
        const adb_install = android_sdk.addAdbInstall(installed_apk.source);
        const adb_start = android_sdk.addAdbStart("com.zig.minimal/android.app.NativeActivity");
        adb_start.step.dependOn(&adb_install.step);
        run_step.dependOn(&adb_start.step);
    }
}
