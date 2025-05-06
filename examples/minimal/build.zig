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

    // If building with Android, initialize the tools / build
    const android_apk: ?*android.APK = blk: {
        if (android_targets.len == 0) {
            break :blk null;
        }
        const android_tools = android.Tools.create(b, .{
            .api_level = .android15,
            .build_tools_version = "35.0.1",
            .ndk_version = "29.0.13113456",
        });
        const apk = android.APK.create(b, android_tools);

        const key_store_file = android_tools.createKeyStore(android.CreateKey.example());
        apk.setKeyStore(key_store_file);
        apk.setAndroidManifest(b.path("android/AndroidManifest.xml"));
        apk.addResourceDirectory(b.path("android/res"));

        // Add Java files
        // - If you have 'android:hasCode="false"' in your AndroidManifest.xml then no Java files are required
        //   see: https://developer.android.com/ndk/samples/sample_na
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
            const apk: *android.APK = android_apk orelse @panic("Android APK should be initialized");
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
        apk.installApk();
    }
}
