const std = @import("std");
const builtin = @import("builtin");
const android = @import("zig-android-sdk");

pub fn build(b: *std.Build) !void {
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
        } else {
            const android_tools = android.Tools.create(b, .{
                .api_level = .android15,
                .build_tools_version = "35.0.0",
                .ndk_version = "27.0.12077973",
            });
            const apk = android.APK.create(b, android_tools);

            const key_store_file = android_tools.createKeyStore(android.CreateKey.example());
            apk.setKeyStore(key_store_file);
            apk.setAndroidManifest(b.path("android/AndroidManifest.xml"));
            apk.addResourceDirectory(b.path("android/res"));

            // Add Java files
            apk.addJavaSourceFile(.{ .file = b.path("android/src/NativeInvocationHandler.java") });

            // Example of adding Java files from an external package
            // const sdl_dep = b.dependency("sdl", .{
            //     .optimize = .ReleaseFast,
            //     .target = android_targets[0],
            // });
            // const sdl_java_files = sdl_dep.namedWriteFiles("sdljava");
            // for (sdl_java_files.files.items) |file| {
            //     apk.addJavaSourceFile(.{ .file = file.getPath() });
            // }

            break :blk apk;
        }
    };

    for (targets) |target| {
        var exe: *std.Build.Step.Compile = if (target.result.isAndroid()) b.addSharedLibrary(.{
            .name = exe_name,
            .root_source_file = b.path("src/minimal.zig"),
            .target = target,
            .optimize = optimize,
        }) else b.addExecutable(.{
            .name = exe_name,
            .root_source_file = b.path("src/minimal.zig"),
            .target = target,
            .optimize = optimize,
        });

        // if building as library for Android, add this target
        // NOTE: Android has different CPU targets so you need to build a version of your
        //       code for x86, x86_64, arm, arm64 and more
        if (target.result.isAndroid()) {
            const apk: *android.APK = android_apk orelse @panic("Android APK should be initialized");
            const android_dep = b.dependency("zig-android-sdk", .{
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
    if (android_apk) |ab| {
        ab.installApk();
    }
}
