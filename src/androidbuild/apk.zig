const std = @import("std");
const androidbuild = @import("androidbuild.zig");
const D8Glob = @import("d8glob.zig").D8Glob;
const Tools = @import("tools.zig").Tools;

const KeyStore = androidbuild.KeyStore;
const getAndroidTriple = androidbuild.getAndroidTriple;
const runNameContext = androidbuild.runNameContext;
const printErrorsAndExit = androidbuild.printErrorsAndExit;

const Target = std.Target;
const Step = std.Build.Step;
const ResolvedTarget = std.Build.ResolvedTarget;
const LazyPath = std.Build.LazyPath;

pub const APK = struct {
    const AddJavaSourceFileOption = struct {
        file: LazyPath,
        // NOTE(jae): 2024-09-17
        // Consider adding flags to define/declare the target Java version for this file.
        // Not sure what we'll need in the future.
        // flags: []const []const u8 = &.{},
    };
    const AddJavaSourceFilesOptions = struct {
        root: LazyPath,
        files: []const []const u8,
    };

    b: *std.Build,
    tools: *const Tools,

    android_manifest: ?LazyPath,
    artifacts: std.ArrayListUnmanaged(*Step.Compile),
    java_files: std.ArrayListUnmanaged(LazyPath),
    key_store: ?KeyStore,
    resource_files: *Step.WriteFile,

    pub fn create(b: *std.Build, tools: *const Tools) *@This() {
        const ab: *@This() = b.allocator.create(@This()) catch @panic("OOM");
        ab.* = .{
            .b = b,
            .tools = tools,
            .android_manifest = null,
            .artifacts = .{},
            .java_files = .{},
            .resource_files = b.addWriteFiles(),
            .key_store = null,
        };
        return ab;
    }

    /// Set the AndroidManifest.xml file to use
    pub fn setAndroidManifest(apk: *@This(), path: LazyPath) void {
        apk.android_manifest = path;
    }

    /// Set the directory of your Android /res/ folder.
    /// ie.
    /// - values/strings.xml
    /// - mipmap-hdpi/ic_launcher.png
    /// - mipmap-mdpi/ic_launcher.png
    /// - etc
    pub fn addResourceDirectory(apk: *@This(), dir: LazyPath) void {
        _ = apk.resource_files.addCopyDirectory(dir, "", .{});
    }

    /// Add artifact to the Android build, this should be a shared library (*.so)
    /// that targets x86, x86_64, aarch64, etc
    pub fn addArtifact(apk: *@This(), compile: *std.Build.Step.Compile) void {
        const b = apk.b;
        apk.artifacts.append(b.allocator, compile) catch @panic("OOM");
    }

    /// Add Java file to be transformed into DEX bytecode and packaged into a classes.dex file in the root
    /// of your APK.
    pub fn addJavaSourceFile(apk: *@This(), options: AddJavaSourceFileOption) void {
        const b = apk.b;
        apk.java_files.append(b.allocator, options.file.dupe(b)) catch @panic("OOM");
    }

    pub fn addJavaSourceFiles(apk: *@This(), options: AddJavaSourceFilesOptions) void {
        const b = apk.b;
        for (options.files) |path| {
            apk.addJavaSourceFile(.{ .file = options.root.path(b, path) });
        }
    }

    /// Set the keystore file used to sign the APK file
    /// This is required run on an Android device.
    ///
    /// If you want to just use a temporary key for local development, do something like this:
    /// - ab.setKeyStore(android_tools.createKeyStore(android.CreateKey.example()));
    pub fn setKeyStore(apk: *@This(), key_store: KeyStore) void {
        apk.key_store = key_store;
    }

    fn addLibraryPaths(apk: *@This(), module: *std.Build.Module) void {
        const b = apk.b;
        const android_ndk_sysroot = apk.tools.ndk_sysroot_path;

        // get target
        const target: ResolvedTarget = module.resolved_target orelse {
            @panic(b.fmt("no 'target' set on Android module", .{}));
        };
        const system_target = getAndroidTriple(target) catch |err| @panic(@errorName(err));

        // NOTE(jae): 2024-09-11
        // These *must* be in order of API version, then architecture, then non-arch specific otherwise
        // when starting an *.so from Android or an emulator you can get an error message like this:
        // - "java.lang.UnsatisfiedLinkError: dlopen failed: TLS symbol "_ZZN8gwp_asan15getThreadLocalsEvE6Locals" in dlopened"
        const android_api_version: u32 = @intFromEnum(apk.tools.api_level);

        // ie. $ANDROID_HOME/ndk/{ndk_version}/toolchains/llvm/prebuilt/{host_os_and_arch}/sysroot ++ usr/lib/aarch64-linux-android/35
        module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib/{s}/{d}", .{ android_ndk_sysroot, system_target, android_api_version }) });
        // ie. $ANDROID_HOME/ndk/{ndk_version}/toolchains/llvm/prebuilt/{host_os_and_arch}/sysroot ++ /usr/lib/aarch64-linux-android
        module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib/{s}", .{ android_ndk_sysroot, system_target }) });
        // ie. $ANDROID_HOME/ndk/{ndk_version}/toolchains/llvm/prebuilt/{host_os_and_arch}/sysroot ++ /usr/lib
        module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{android_ndk_sysroot}) });
    }

    pub fn installApk(apk: *@This()) void {
        const b = apk.b;
        const install_apk = apk.addInstallApk();
        b.getInstallStep().dependOn(&install_apk.step);
    }

    pub fn addInstallApk(apk: *@This()) *Step.InstallFile {
        return apk.doInstallApk() catch |err| switch (err) {
            error.OutOfMemory => @panic("OOM"),
        };
    }

    fn doInstallApk(apk: *@This()) std.mem.Allocator.Error!*Step.InstallFile {
        const b = apk.b;

        const key_store: KeyStore = apk.key_store orelse .{
            .file = .{ .cwd_relative = "" },
            .password = "",
        };

        // validate
        {
            var errors = std.ArrayList([]const u8).init(b.allocator);
            if (key_store.password.len == 0) {
                try errors.append("Keystore not configured with password, must be setup with setKeyStore");
            }
            if (apk.android_manifest == null) {
                try errors.append("AndroidManifest.xml not configured, must be set with setAndroidManifest");
            }
            if (apk.artifacts.items.len == 0) {
                try errors.append("Must add at least one artifact targeting a valid Android CPU architecture: aarch64, x86_64, x86, etc");
            } else {
                for (apk.artifacts.items, 0..) |artifact, i| {
                    if (artifact.kind == .exe) {
                        try errors.append(b.fmt("artifact[{}]: must make Android artifacts be created with addSharedLibrary, not addExecutable", .{i}));
                    } else {
                        if (artifact.linkage) |linkage| {
                            if (linkage != .dynamic) {
                                try errors.append(b.fmt("artifact[{}]: invalid linkage, expected it to be created via addSharedLibrary", .{i}));
                            }
                        } else {
                            try errors.append(b.fmt("artifact[{}]: unable to get linkage from artifact, expected it to be created via addSharedLibrary", .{i}));
                        }
                    }
                    if (artifact.root_module.resolved_target) |target| {
                        if (!target.result.isAndroid()) {
                            try errors.append(b.fmt("artifact[{}]: must be targetting Android abi", .{i}));
                            continue;
                        }
                    } else {
                        try errors.append(b.fmt("artifact[{}]: unable to get resolved target from artifact", .{i}));
                    }
                }
            }
            if (apk.java_files.items.len == 0) {
                // NOTE(jae): 2024-09-19
                // We can probably avoid this with a stub or something but for now error so that an "adb install"
                // doesn't give users:
                // - Scanning Failed.: Package /data/app/base.apk code is missing]
                try errors.append(b.fmt("must add at least one Java file to build", .{}));
            }
            if (errors.items.len > 0) {
                printErrorsAndExit("misconfigured Android APK", errors.items);
            }
        }

        // Setup AndroidManifest.xml
        const android_manifest_file = apk.android_manifest orelse {
            @panic("call setAndroidManifestFile and point to your AndroidManifest.xml file");
        };

        // These are files that belong in root like:
        // - lib/x86_64/libmain.so
        // - lib/x86/libmain.so
        // - classes.dex
        const raw_top_level_apk_files = b.addWriteFiles();

        // Add build artifacts, usually a shared library targetting:
        // - aarch64-linux-android
        // - arm-linux-androideabi
        // - i686-linux-android
        // - x86_64-linux-android
        for (apk.artifacts.items, 0..) |root_artifact, artifact_index| {
            const target: ResolvedTarget = root_artifact.root_module.resolved_target orelse {
                @panic(b.fmt("artifact[{d}] has no 'target' set", .{artifact_index}));
            };

            // https://developer.android.com/ndk/guides/abis#native-code-in-app-packages
            const so_dir: []const u8 = switch (target.result.cpu.arch) {
                .aarch64 => "arm64-v8a",
                .arm => "armeabi-v7a",
                .x86_64 => "x86_64",
                .x86 => "x86",
                else => @panic(b.fmt("unsupported or unhandled arch: {s}", .{@tagName(target.result.cpu.arch)})),
            };
            _ = raw_top_level_apk_files.addCopyFile(root_artifact.getEmittedBin(), b.fmt("lib/{s}/libmain.so", .{so_dir}));

            // update artifact to:
            // - Be configured to work correctly on Android
            // - To know where C header /lib files are via setLibCFile and linkLibC
            // - Provide path to additional libraries to link to
            {
                const artifact = root_artifact;
                if (artifact.linkage) |linkage| {
                    if (linkage == .dynamic) {
                        updateSharedLibraryOptions(artifact);
                    }
                }
                apk.tools.setLibCFile(artifact);
                apk.addLibraryPaths(&artifact.root_module);
                artifact.linkLibC();
            }
            // NOTE(jae): 2024-08-09
            // Try to fix compilation issues for arm-linux-androideabi
            // if (target.result.cpu.arch == .arm) {
            //     // artifact.root_module.addCMacro("__ARM_ARCH_7A__", "");
            //     // artifact.root_module.addCMacro("_ARM_ARCH_7", "");
            //     // artifact.root_module.addCMacro("__ARM_ARCH", "7"); // '__ARM_ARCH' macro redefined
            //     // artifact.root_module.addCMacro("_M_ARM", ""); // Fix "openxr/src/common/platform_utils.hpp" No architecture string known!
            // }

            // update linked libraries that use C or C++ to:
            // - use Android LibC file
            // - add Android NDK library paths. (libandroid, liblog, etc)
            for (root_artifact.root_module.link_objects.items) |link_object| {
                switch (link_object) {
                    .other_step => |artifact| {
                        switch (artifact.kind) {
                            .lib => {
                                // If you have a library that is being built as an *.so then install it
                                // alongside your library.
                                //
                                // This was initially added to support building SDL2 with Zig.
                                if (artifact.linkage) |linkage| {
                                    if (linkage == .dynamic) {
                                        updateSharedLibraryOptions(artifact);

                                        _ = raw_top_level_apk_files.addCopyFile(artifact.getEmittedBin(), b.fmt("lib/{s}/lib{s}.so", .{ so_dir, artifact.name }));
                                    }
                                }

                                // If library is built using C or C++, add Android C File and Library Paths
                                const link_libc = artifact.root_module.link_libc orelse false;
                                const link_libcpp = artifact.root_module.link_libcpp orelse false;
                                if (link_libc or link_libcpp) {
                                    // NOTE(jae): 2024-08-09
                                    // Try to fix compilation issues for arm-linux-androideabi
                                    // if (target.result.cpu.arch == .arm) {
                                    // other_step.root_module.addCMacro("_ARM_ARCH_7", "");
                                    // other_step.root_module.addCMacro("__ARM_ARCH_7A__", ""); // Fixes nothing
                                    // other_step.root_module.addCMacro("__ARM_ARCH", "7"); // '__ARM_ARCH' macro redefined
                                    // other_step.root_module.addCMacro("_M_ARM", "");
                                    // }
                                    // other_step.root_module.addCMacro("__ANDROID__", "");
                                    apk.tools.setLibCFile(artifact);
                                    apk.addLibraryPaths(&artifact.root_module);
                                }
                            },
                            else => continue,
                        }
                    },
                    else => {},
                }
            }
        }

        // Add *.jar files
        // - Even if java_files.items.len == 0, we still always add the root_jar
        if (apk.java_files.items.len > 0) {
            // https://docs.oracle.com/en/java/javase/17/docs/specs/man/javac.html
            const javac_cmd = b.addSystemCommand(&[_][]const u8{
                apk.tools.java_tools.javac,
                // NOTE(jae): 2024-09-22
                // Force encoding to be utf8 for Windows, this fixes the following comment
                // causing SDL2to not compile under Windows:
                // Source: https://github.com/libsdl-org/SDL/blob/release-2.30.7/android-project/app/src/main/java/org/libsdl/app/SDLActivity.java#L2045
                "-encoding",
                "utf8",
                "-cp",
                apk.tools.root_jar,
                // NOTE(jae): 2024-09-19
                // Debug issues with the SDL.java classes
                // "-Xlint:deprecation",
            });
            javac_cmd.setName(runNameContext("javac"));
            javac_cmd.addArg("-d");
            const java_classes_output_dir = javac_cmd.addOutputDirectoryArg("android_classes");

            // Add Java files
            for (apk.java_files.items) |java_file| {
                javac_cmd.addFileArg(java_file);
                // If *.java file is in dependency/generated
                //java_file.addStepDependencies(&javac_cmd.step);
            }

            // From d8.bat
            // call "%java_exe%" %javaOpts% -cp "%jarpath%" com.android.tools.r8.D8 %params%
            const d8 = b.addSystemCommand(&[_][]const u8{
                apk.tools.build_tools.d8,
            });
            d8.setName(runNameContext("d8"));

            // ie. android_sdk/platforms/android-{api-level}/android.jar
            d8.addArg("--lib");
            d8.addArg(apk.tools.root_jar);

            d8.addArg("--output");
            const dex_output_dir = d8.addOutputDirectoryArg("android_dex");

            // NOTE(jae): 2024-09-22
            // As per documentation for d8, we may want to specific the minimum API level we want
            // to support. Not sure how to test or expose this yet. See: https://developer.android.com/tools/d8
            // d8.addArg("--min-api");
            // d8.addArg(number_as_string);

            // add each output *.class file
            D8Glob.addClassFilesRecursively(b, d8, java_classes_output_dir);
            const dex_file = dex_output_dir.path(b, "classes.dex");

            // Append classes.dex to apk
            _ = raw_top_level_apk_files.addCopyFile(dex_file, "classes.dex");
        }

        // Make unsigned apk
        const unaligned_apk_file: LazyPath = blk: {
            const aapt = b.addSystemCommand(&[_][]const u8{
                apk.tools.build_tools.aapt,
                "package",
                "-f", // force overwrite of existing output .apk file, otherwise build errors can occur on subsequent runs (Zig 0.13.0)
                "-I", // add an existing package to base include set
                apk.tools.root_jar,
            });
            aapt.setName(runNameContext("aapt"));

            // Specify output file
            aapt.addArg("-F");
            const unaligned_output_apk_file = aapt.addOutputFileArg("unaligned-apk.apk");

            // full path to AndroidManifest.xml to include in zip
            // ie. -M AndroidManifest.xml
            aapt.addArg("-M");
            aapt.addFileArg(android_manifest_file);
            // aapt.step.dependOn(&android_manifest_write_files.step);

            // Directory in which to find resources. Multiple directories will be scanned and the first match found (left to right) will take precedence
            // ie. "-S RESOURCES_DIR"
            aapt.addArg("-S");
            aapt.addDirectoryArg(apk.resource_files.getDirectory());

            aapt.addArgs(&[_][]const u8{
                "-v",
                "--target-sdk-version",
                b.fmt("{d}", .{@intFromEnum(apk.tools.api_level)}),
            });

            // TODO(jae): 2024-09-17
            // Add support for asset directories

            // Additional directory
            // aapt.step.dependOn(&resource_write_files.step);
            // for (app_config.asset_directories) |dir| {
            //     make_unsigned_apk.addArg("-A"); // additional directory in which to find raw asset files
            //     make_unsigned_apk.addArg(sdk.b.pathFromRoot(dir));
            // }

            // Raw files directory (As per docs here: https://manpages.org/aapt)
            aapt.addDirectoryArg(raw_top_level_apk_files.getDirectory());
            break :blk unaligned_output_apk_file;
        };

        var zipalign = b.addSystemCommand(&[_][]const u8{
            apk.tools.build_tools.zipalign,
        });
        const apk_unaligned_zip_file = unaligned_apk_file;

        // Align contents of .apk (zip)
        const aligned_apk_file: LazyPath = blk: {
            // If you use apksigner, zipalign must be used before the APK file has been signed.
            // If you sign your APK using apksigner and make further changes to the APK, its signature is invalidated.
            // Source: https://developer.android.com/tools/zipalign (10th Sept, 2024)
            //
            // Example: "zipalign -P 16 -f -v 4 infile.apk outfile.apk"
            zipalign.addArgs(&.{
                "-P", // aligns uncompressed .so files to the specified page size in KiB...
                "16", // ... align to 16kb
                "-f", // overwrite existing files
                "-v", // verbose
                // "-z", // recompresses using Zopfli. (very very slow)
                "4",
            });
            zipalign.addFileArg(apk_unaligned_zip_file);
            const apk_file = zipalign.addOutputFileArg("aligned-apk.apk");
            break :blk apk_file;
        };

        // Sign apk
        const signed_apk_file: LazyPath = blk: {
            const apksigner = b.addSystemCommand(&[_][]const u8{
                apk.tools.build_tools.apksigner,
                "sign",
            });
            apksigner.setName(runNameContext("apksigner"));
            apksigner.addArg("--ks"); // ks = keystore
            apksigner.addFileArg(key_store.file);
            apksigner.addArgs(&.{ "--ks-pass", b.fmt("pass:{s}", .{key_store.password}) });
            apksigner.addArg("--out");
            const signed_output_apk_file = apksigner.addOutputFileArg("signed-and-aligned-apk.apk");
            apksigner.addFileArg(aligned_apk_file);
            break :blk signed_output_apk_file;
        };

        const apk_name = apk.artifacts.items[0].name;
        const apk_filename = b.fmt("{s}.apk", .{apk_name});
        const install_apk = b.addInstallBinFile(signed_apk_file, apk_filename);
        return install_apk;
    }
};

fn updateSharedLibraryOptions(artifact: *std.Build.Step.Compile) void {
    if (artifact.linkage) |linkage| {
        if (linkage != .dynamic) {
            @panic("can only call updateSharedLibraryOptions if linkage is dynamic");
        }
    } else {
        @panic("can only call updateSharedLibraryOptions if linkage is dynamic");
    }

    // Detect if just compiling C files, if that's the case, avoid bundling the Zig compiler runtime
    var is_compiling_c = false;
    for (artifact.root_module.link_objects.items) |link_object| {
        switch (link_object) {
            .c_source_file => {
                is_compiling_c = true;
            },
            .c_source_files => {
                is_compiling_c = true;
            },
            else => {},
        }
    }

    // NOTE(jae): 2024-09-01
    // Copy-pasted from https://github.com/ikskuh/ZigAndroidTemplate/blob/master/Sdk.zig
    // Do we need all these?
    artifact.link_emit_relocs = true;
    artifact.link_eh_frame_hdr = true;
    artifact.root_module.pic = true;
    artifact.link_function_sections = true;
    // NOTE(jae): 2024-09-22
    // Only bundle the Zig compiler RT for libraries that use a *.zig file
    // The point of this logic is to avoid this being true for C code
    artifact.bundle_compiler_rt = !is_compiling_c;
    if (artifact.root_module.optimize) |optimize| {
        // NOTE(jae): ZigAndroidTemplate used: (optimize == .ReleaseSmall);
        artifact.root_module.strip = optimize == .ReleaseSmall;
    }
    artifact.export_table = true;

    // TODO(jae): 2024-09-19 - Copy-pasted from https://github.com/ikskuh/ZigAndroidTemplate/blob/master/Sdk.zig
    // Remove when https://github.com/ziglang/zig/issues/7935 is resolved.
    if (artifact.root_module.resolved_target) |target| {
        if (target.result.cpu.arch == .x86) {
            const use_link_z_notext_workaround: bool = if (artifact.bundle_compiler_rt) |bcr| bcr else false;
            if (use_link_z_notext_workaround) {
                // NOTE(jae): 2024-09-22
                // This workaround can prevent your libmain.so from loading. At least in my testing with running Android 10 (Q, API Level 29)
                //
                // This is due to:
                // "Text Relocations Enforced for API Level 23"
                // See: https://android.googlesource.com/platform/bionic/+/refs/tags/ndk-r14/android-changes-for-ndk-developers.md
                artifact.link_z_notext = true;
            }
        }
    }
}
