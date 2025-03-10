const std = @import("std");
const builtin = @import("builtin");
const android = @import("android");

pub fn build(b: *std.Build) void {
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
            .build_tools_version = "35.0.0",
            .ndk_version = "29.0.13113456",
            // NOTE(jae): 2025-03-09
            // Previously this example used 'ndk' "27.0.12077973".
            //
            // However that has issues with the latest SDL2 version when including 'hardware_buffer.h'
            // for 32-bit builds.
            //
            // - AHARDWAREBUFFER_USAGE_FRONT_BUFFER = 1UL << 32
            //  - ndk/27.0.12077973/toolchains/llvm/prebuilt/{OS}-x86_64/sysroot/usr/include/android/hardware_buffer.h:322:42:
            //  - error: expression is not an integral constant expression
        });
        const apk = android.APK.create(b, android_tools);

        const key_store_file = android_tools.createKeyStore(android.CreateKey.example());
        apk.setKeyStore(key_store_file);
        apk.setAndroidManifest(b.path("android/AndroidManifest.xml"));
        apk.addResourceDirectory(b.path("android/res"));

        // Add Java files
        apk.addJavaSourceFile(.{ .file = b.path("android/src/ZigSDLActivity.java") });

        // Add SDL2's Java files like SDL.java, SDLActivity.java, HIDDevice.java, etc
        const sdl_dep = b.dependency("sdl2", .{
            .optimize = optimize,
            .target = android_targets[0],
        });
        const sdl_java_files = sdl_dep.namedWriteFiles("sdljava");
        for (sdl_java_files.files.items) |file| {
            apk.addJavaSourceFile(.{ .file = file.contents.copy });
        }
        break :blk apk;
    };

    for (targets) |target| {
        const exe_name: []const u8 = "sdl-zig-demo";
        var exe: *std.Build.Step.Compile = if (target.result.abi.isAndroid()) b.addSharedLibrary(.{
            .name = exe_name,
            .root_source_file = b.path("src/sdl-zig-demo.zig"),
            .target = target,
            .optimize = optimize,
        }) else b.addExecutable(.{
            .name = exe_name,
            .root_source_file = b.path("src/sdl-zig-demo.zig"),
            .target = target,
            .optimize = optimize,
        });

        const library_optimize = if (!target.result.abi.isAndroid())
            optimize
        else
            // In Zig 0.14.0, for Android builds, make sure we build libraries with ReleaseSafe
            // otherwise we get errors relating to libubsan_rt.a getting RELOCATION errors
            // https://github.com/silbinarywolf/zig-android-sdk/issues/18
            if (optimize == .Debug) .ReleaseSafe else optimize;

        // add SDL2
        {
            const sdl_dep = b.dependency("sdl2", .{
                .optimize = library_optimize,
                .target = target,
            });
            if (target.result.os.tag == .linux and !target.result.abi.isAndroid()) {
                // The SDL package doesn't work for Linux yet, so we rely on system
                // packages for now.
                exe.linkSystemLibrary("SDL2");
                exe.linkLibC();
            } else {
                const sdl_lib = sdl_dep.artifact("SDL2");
                exe.linkLibrary(sdl_lib);
            }

            const sdl_module = sdl_dep.module("sdl");
            exe.root_module.addImport("sdl", sdl_module);
        }

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
