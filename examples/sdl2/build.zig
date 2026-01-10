const std = @import("std");
const builtin = @import("builtin");
const android = @import("android");

pub fn build(b: *std.Build) void {
    const root_target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const android_targets = android.standardTargets(b, root_target);

    const crash_on_exception = b.option(bool, "crash-on-exception", "if true then we'll use the activity from androidCrashTest folder") orelse false;

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
            .build_tools_version = "36.1.0",
            .ndk_version = "29.0.14206865",
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

        const key_store_file = android_sdk.createKeyStore(.example);
        apk.setKeyStore(key_store_file);
        apk.setAndroidManifest(b.path("android/AndroidManifest.xml"));
        apk.addResourceDirectory(b.path("android/res"));

        // Add Java files
        if (!crash_on_exception) {
            apk.addJavaSourceFile(.{ .file = b.path("android/src/ZigSDLActivity.java") });
        } else {
            // This is used for testing in Github Actions, so that we can call "adb shell monkey" and trigger
            // an error.
            // - adb shell monkey --kill-process-after-error --monitor-native-crashes --pct-touch 100 -p com.zig.sdl2 -v 50
            //
            // This alternate SDLActivity skips the nice dialog box you get when doing manual human testing.
            apk.addJavaSourceFile(.{ .file = b.path("android/androidCrashTest/ZigSDLActivity.java") });
        }

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
        const app_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/sdl-zig-demo.zig"),
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
                app_module.linkSystemLibrary("SDL2", .{});
                app_module.link_libc = true;
            } else {
                const sdl_lib = sdl_dep.artifact("SDL2");
                app_module.linkLibrary(sdl_lib);
            }

            const sdl_module = sdl_dep.module("sdl");
            app_module.addImport("sdl", sdl_module);
        }

        // if building as library for Android, add this target
        // NOTE: Android has different CPU targets so you need to build a version of your
        //       code for x86, x86_64, arm, arm64 and more
        if (target.result.abi.isAndroid()) {
            const apk: *android.Apk = android_apk orelse @panic("Android APK should be initialized");
            const android_dep = b.dependency("android", .{
                .optimize = optimize,
                .target = target,
            });
            app_module.addImport("android", android_dep.module("android"));

            const exe_lib = b.addLibrary(.{
                .name = exe_name,
                .root_module = app_module,
                .linkage = .dynamic,
            });
            apk.addArtifact(exe_lib);
        } else {
            const exe = b.addExecutable(.{
                .name = exe_name,
                .root_module = app_module,
            });
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
        const adb_start = android_sdk.addAdbStart("com.zig.sdl2/com.zig.sdl2.ZigSDLActivity");
        adb_start.step.dependOn(&adb_install.step);
        run_step.dependOn(&adb_start.step);
    }
}
