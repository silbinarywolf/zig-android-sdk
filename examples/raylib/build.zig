const android = @import("android");
const std = @import("std");

//this is targeting android API level 29. 
//You may have to change the values here and in android/AndroidManifest.xml to target your desired API level
const android_api = "29";
const android_version = .android10;

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
            .build_tools_version = "35.0.0",
            .ndk_version = "27.2.12479018",
        });
        const apk = android.APK.create(b, android_tools);

        const key_store_file = android_tools.createKeyStore(android.CreateKey.example());
        apk.setKeyStore(key_store_file);
        apk.setAndroidManifest(b.path("android/AndroidManifest.xml"));
        apk.addResourceDirectory(b.path("android/res"));

        break :blk apk;
    };

    for(targets) |target| {
        if (target.result.abi.isAndroid()) {
            const lib_mod = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            });

            const lib = b.addLibrary(.{
                .linkage = .dynamic,
                .name = "minimal_android_raylib",
                .root_module = lib_mod,
            });

            b.installArtifact(lib);
            lib.linkLibC();
            const raylib_dep = b.dependency("raylib_zig", .{
                    .target = target,
                    .optimize = optimize,
                    .android_api_version = @as([]const u8, android_api)
            });
            const raylib_artifact = raylib_dep.artifact("raylib");
            lib.linkLibrary(raylib_artifact);

            const raylib_mod = raylib_dep.module("raylib");
            lib.root_module.addImport("raylib", raylib_mod);
            const apk: *android.APK = android_apk orelse @panic("Android APK should be initialized");

            const android_dep = b.dependency("android", .{
                .optimize = optimize,
                .target = target,
            });
            lib.root_module.addImport("android", android_dep.module("android"));
            lib.root_module.linkSystemLibrary("android", .{.preferred_link_mode = .dynamic});
            lib.root_module.linkSystemLibrary("EGL", .{.preferred_link_mode = .dynamic});
            lib.root_module.linkSystemLibrary("GLESv2", .{.preferred_link_mode = .dynamic});
            lib.root_module.linkSystemLibrary("log", .{ .preferred_link_mode = .dynamic });
            lib.root_module.addCSourceFile(.{ .file = b.path("src/android_native_app_glue.c")});

            apk.addArtifact(lib);
        } else {
            //non-android build logic...
        }
    }
    if (android_apk) |apk| {
        apk.installApk();
    }
}
