const std = @import("std");
const builtin = @import("builtin");
const androidbuild = @import("androidbuild.zig");
const Allocator = std.mem.Allocator;

const ApiLevel = androidbuild.ApiLevel;
const getAndroidTriple = androidbuild.getAndroidTriple;
const runNameContext = androidbuild.runNameContext;
const printErrorsAndExit = androidbuild.printErrorsAndExit;

const Build = std.Build;
const AccessError = std.fs.Dir.AccessError;
const Step = Build.Step;
const ResolvedTarget = Build.ResolvedTarget;
const LazyPath = std.Build.LazyPath;
const Apk = @import("apk.zig");
const Ndk = @import("Ndk.zig");
const BuildTools = @import("BuildTools.zig");

b: *Build,

/// On most platforms this will map to the $ANDROID_HOME environment variable
android_sdk_path: []const u8,
/// $JDK_HOME, $JAVA_HOME or auto-discovered from java binaries found in $PATH
jdk_path: []const u8,
/// ie. $ANDROID_HOME/platform-tools
platform_tools: struct {
    adb: []const u8,
},
/// ie. $ANDROID_HOME/cmdline_tools/bin or $ANDROID_HOME/tools/bin
///
/// Available to download at: https://developer.android.com/studio#command-line-tools-only
/// The commandline tools ZIP expected looks like: commandlinetools-{OS}-11076708_latest.zip
cmdline_tools: struct {
    /// lint [flags] <project directory>
    /// See documentation: https://developer.android.com/studio/write/lint#commandline
    lint: []const u8,
    sdkmanager: []const u8,
},
/// Binaries provided by the JDK that usually exist in:
/// - Non-Windows: $JAVA_HOME/bin
///
/// Windows (either of these):
/// - C:\Program Files\Eclipse Adoptium\jdk-11.0.17.8-hotspot\
/// - C:\Program Files\Java\jdk-17.0.4.1\
java_tools: struct {
    /// jar is used to zip up files in a cross-platform way that does not rely on
    /// having "zip" in your command-line (Windows does not have this)
    ///
    /// ie. https://stackoverflow.com/a/18180154/5013410
    jar: []const u8,
    javac: []const u8,
    keytool: []const u8,
},

/// Reserved for future use
const Options = struct {};

pub fn create(b: *std.Build, options: Options) *Sdk {
    _ = options;

    const host_os_tag = b.graph.host.result.os.tag;

    // Discover tool paths
    var path_search = PathSearch.init(b, host_os_tag) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
        error.EnvironmentVariableNotFound => @panic("unable to find PATH as an environment variable"),
    };
    const configured_android_sdk_path = getAndroidSDKPath(b) catch @panic("OOM");
    if (configured_android_sdk_path.len > 0) {
        // Set android SDK path here so it will not try searching for adb.exe if searching for JDK
        path_search.android_sdk_path = configured_android_sdk_path;
    }
    const android_sdk_path = path_search.findAndroidSDK(b.allocator) catch @panic("OOM");
    const jdk_path = path_search.findJDK(b.allocator) catch @panic("OOM");

    // Validate
    var errors = std.ArrayListUnmanaged([]const u8).empty;
    defer errors.deinit(b.allocator);

    if (jdk_path.len == 0) {
        errors.append(b.allocator,
            \\JDK not found.
            \\- Download it from https://www.oracle.com/th/java/technologies/downloads/
            \\- Then configure your JDK_HOME environment variable to where you've installed it.
        ) catch @panic("OOM");
    }
    if (android_sdk_path.len == 0) {
        errors.append(b.allocator,
            \\Android SDK not found.
            \\- Download it from https://developer.android.com/studio
            \\- Then configure your ANDROID_HOME environment variable to where you've installed it.
        ) catch @panic("OOM");
    }
    if (errors.items.len > 0) {
        printErrorsAndExit(b, "unable to find required Android installation", errors.items);
    }

    // Get commandline tools path
    // - 1st: $ANDROID_HOME/cmdline-tools/bin
    // - 2nd: $ANDROID_HOME/tools/bin
    const cmdline_tool_path_list = [_][]const u8{
        b.pathResolve(&[_][]const u8{ android_sdk_path, "cmdline-tools", "latest", "bin" }),
        b.pathResolve(&[_][]const u8{ android_sdk_path, "tools", "bin" }),
    };
    const cmdline_tools_path: []const u8 = cmdlineblk: {
        for (cmdline_tool_path_list) |cmdline_tools_path| {
            const access_wrapped_error = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
                std.fs.accessAbsolute(cmdline_tools_path, .{})
            else
                std.Io.Dir.accessAbsolute(b.graph.io, cmdline_tools_path, .{});
            access_wrapped_error catch |err| switch (err) {
                error.FileNotFound => continue,
                else => {
                    const message = b.fmt("Android Command Line Tools path had an unexpected error: {s} ({s})", .{
                        @errorName(err),
                        cmdline_tools_path,
                    });
                    errors.append(b.allocator, message) catch @panic("OOM");
                },
            };
            break :cmdlineblk cmdline_tools_path;
        }
        // If unable to find command line tools, return empty
        break :cmdlineblk &[0]u8{};
    };
    if (cmdline_tools_path.len == 0) {
        const message = b.fmt("Android SDK Command-line tools not found in SDK folder. (expected {s} or {s} to exist)\n- This can either be installed via Android Studio\n- or downloaded directly here: {s}", .{
            cmdline_tool_path_list[0],
            cmdline_tool_path_list[1],
            "https://developer.android.com/studio#command-line-tools-only",
        });
        errors.append(b.allocator, message) catch @panic("OOM");
    }
    if (errors.items.len > 0) {
        printErrorsAndExit(b, "unable to find required Android installation", errors.items);
    }

    const platform_tools_path = b.pathResolve(&[_][]const u8{ android_sdk_path, "platform-tools" });

    const exe_suffix = if (host_os_tag == .windows) ".exe" else "";
    const bat_suffix = if (host_os_tag == .windows) ".bat" else "";

    const sdk: *Sdk = b.allocator.create(Sdk) catch @panic("OOM");
    sdk.* = .{
        .b = b,
        .android_sdk_path = android_sdk_path,
        .jdk_path = jdk_path,
        .platform_tools = .{
            .adb = b.pathResolve(&[_][]const u8{
                platform_tools_path, b.fmt("adb{s}", .{exe_suffix}),
            }),
        },
        .cmdline_tools = .{
            .lint = b.pathResolve(&[_][]const u8{
                cmdline_tools_path, b.fmt("lint{s}", .{bat_suffix}),
            }),
            .sdkmanager = b.pathResolve(&[_][]const u8{
                cmdline_tools_path, b.fmt("sdkmanager{s}", .{bat_suffix}),
            }),
        },
        .java_tools = .{
            .jar = b.pathResolve(&[_][]const u8{
                jdk_path, "bin", b.fmt("jar{s}", .{exe_suffix}),
            }),
            .javac = b.pathResolve(&[_][]const u8{
                jdk_path, "bin", b.fmt("javac{s}", .{exe_suffix}),
            }),
            .keytool = b.pathResolve(&[_][]const u8{
                jdk_path, "bin", b.fmt("keytool{s}", .{exe_suffix}),
            }),
        },
    };
    return sdk;
}

pub fn createApk(sdk: *Sdk, options: Apk.Options) *Apk {
    return Apk.create(sdk, options);
}

// TODO: Consider adding step to run: sdkmanager --install "ndk;21.3.6528147"
// pub fn installNdkVersion(ndk_version: []const u8) *Step {
// }

/// Start an installed application on your Android device or emulator.
/// To install an APK first see "addAdbInstall"
///
/// ie.
/// - "adb shell am start -S -W -n com.zig.minimal/android.app.NativeActivity"
/// - "adb shell am start -S -W -n com.zig.sdl2/com.zig.sdl2.ZigSDLActivity"
pub fn addAdbStart(sdk: *Sdk, package_name_and_java_entry: []const u8) *Step.Run {
    const b = sdk.b;
    if (sdk.platform_tools.adb.len == 0) {
        @panic("Cannot call addAdbStart as 'adb' is not installed");
    }
    // TODO: Improve this to be its own special Step that can auto-detect the "com.zig.sdl2/com.zig.sdl2.ZigSDLActivity" data
    const adb_shell_start = b.addSystemCommand(&.{ sdk.platform_tools.adb, "shell", "am", "start", "-S", "-W", "-n", package_name_and_java_entry });
    return adb_shell_start;
}

/// Install an APK onto your Android device or emulator
/// ie. "adb install ./zig-out/bin/minimal.apk"
pub fn adbInstall(sdk: *Sdk, apk: LazyPath) void {
    const b = sdk.b;
    const adb_install = sdk.addAdbInstall(apk);
    b.getInstallStep().dependOn(&adb_install.step);
}

/// Install an APK onto your Android device or emulator
/// ie. "adb install ./zig-out/bin/minimal.apk"
pub fn addAdbInstall(sdk: *Sdk, apk: LazyPath) *Step.Run {
    const b = sdk.b;
    if (sdk.platform_tools.adb.len == 0) {
        @panic("Cannot call addInstallApk as 'adb' is not installed");
    }
    const adb_install = b.addSystemCommand(&.{
        sdk.platform_tools.adb,
        "install",
    });
    adb_install.addFileArg(apk);
    return adb_install;
}

/// EXPERIMENTAL: Allows invoking the Android SDK manager
/// ie. zig build -Dandroid sdkmanager -- --help
pub fn addSdkManagerStep(sdk: *Sdk) void {
    const b = sdk.b;
    const sdkmanager_step = b.step("sdkmanager", "Run the Android SDK Manager");
    const args = b.args orelse &.{};
    const sdkmanager = b.addSystemCommand(&.{sdk.cmdline_tools.sdkmanager});
    sdkmanager.setEnvironmentVariable("SKIP_JDK_VERSION_CHECK", "1");
    if (b.verbose) {
        sdkmanager.addArg("--verbose");
    }
    sdkmanager_step.dependOn(&sdkmanager.step);
    for (args) |arg| {
        sdkmanager.addArg(arg);
    }
}

pub const CreateKey = struct {
    pub const Algorithm = enum {
        rsa,

        /// arg returns the keytool argument
        fn arg(self: Algorithm) []const u8 {
            return switch (self) {
                .rsa => "RSA",
            };
        }
    };

    alias: []const u8,
    password: []const u8,
    algorithm: Algorithm,
    /// in bits, the maximum size of an RSA key supported by the Android keystore is 4096 bits (as of 2024)
    key_size_in_bits: u32,
    validity_in_days: u32,
    /// https://stackoverflow.com/questions/3284055/what-should-i-use-for-distinguished-name-in-our-keystore-for-the-android-marke/3284135#3284135
    distinguished_name: []const u8,

    /// Generates an example key that you can use for debugging your application locally
    pub const example: CreateKey = .{
        .alias = "default",
        .password = "example_password",
        .algorithm = .rsa,
        .key_size_in_bits = 4096,
        .validity_in_days = 10_000,
        .distinguished_name = "CN=example.com, OU=ID, O=Example, L=Doe, S=Jane, C=GB",
    };
};

pub fn createKeyStore(sdk: *const Sdk, options: CreateKey) KeyStore {
    const b = sdk.b;
    const keytool = b.addSystemCommand(&.{
        // https://docs.oracle.com/en/java/javase/17/docs/specs/man/keytool.html
        sdk.java_tools.keytool,
        "-genkey",
        "-v",
    });
    keytool.setName(runNameContext("keytool"));
    keytool.addArg("-keystore");
    const keystore_file = keytool.addOutputFileArg("zig-generated.keystore");
    keytool.addArgs(&.{
        // -alias "ca"
        "-alias",
        options.alias,
        // -keyalg "rsa"
        "-keyalg",
        options.algorithm.arg(),
        "-keysize",
        b.fmt("{d}", .{options.key_size_in_bits}),
        "-validity",
        b.fmt("{d}", .{options.validity_in_days}),
        "-storepass",
        options.password,
        "-keypass",
        options.password,
        // -dname "CN=example.com, OU=ID, O=Example, L=Doe, S=Jane, C=GB"
        "-dname",
        options.distinguished_name,
    });
    // ignore stderr, it just gives you an output like:
    // "Generating 4,096 bit RSA key pair and self-signed certificate (SHA384withRSA) with a validity of 10,000 days
    // for: CN=example.com, OU=ID, O=Example, L=Doe, ST=Jane, C=GB"
    _ = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
        keytool.captureStdErr()
    else
        keytool.captureStdErr(.{});
    return .{
        .file = keystore_file,
        .password = options.password,
    };
}

pub fn createOrGetLibCFile(sdk: *Sdk, compile: *Step.Compile, android_api_level: ApiLevel, ndk_sysroot_path: []const u8, ndk_version: []const u8) LazyPath {
    const b = sdk.b;

    const target: ResolvedTarget = compile.root_module.resolved_target orelse @panic("no 'target' set on Android module");
    const system_target = getAndroidTriple(target) catch |err| @panic(@errorName(err));

    // NOTE(jae): 2025-05-25
    // Tried just utilizing the target version here but it was very low (14) and there was no NDK libraries that went
    // back that far for NDK version "29.0.13113456"
    // const android_api_level: ApiLevel = @enumFromInt(target.result.os.version_range.linux.android);
    // if (android_api_level == .none) @panic("no 'android' api level set on target");

    const libc_file_format =
        \\# Generated by zig-android-sdk. DO NOT EDIT.
        \\
        \\# The directory that contains `stdlib.h`.
        \\# On POSIX-like systems, include directories be found with: `cc -E -Wp,-v -xc /dev/null`
        \\include_dir={[include_dir]s}
        \\
        \\# The system-specific include directory. May be the same as `include_dir`.
        \\# On Windows it's the directory that includes `vcruntime.h`.
        \\# On POSIX it's the directory that includes `sys/errno.h`.
        \\sys_include_dir={[sys_include_dir]s}
        \\
        \\# The directory that contains `crt1.o`.
        \\# On POSIX, can be found with `cc -print-file-name=crt1.o`.
        \\# Not needed when targeting MacOS.
        \\crt_dir={[crt_dir]s}
        \\
        \\# The directory that contains `vcruntime.lib`.
        \\# Only needed when targeting MSVC on Windows.
        \\msvc_lib_dir=
        \\
        \\# The directory that contains `kernel32.lib`.
        \\# Only needed when targeting MSVC on Windows.
        \\kernel32_lib_dir=
        \\
        \\gcc_dir=
    ;

    const include_dir = b.fmt("{s}/usr/include", .{ndk_sysroot_path});
    const sys_include_dir = b.fmt("{s}/usr/include/{s}", .{ ndk_sysroot_path, system_target });
    const crt_dir = b.fmt("{s}/usr/lib/{s}/{d}", .{ ndk_sysroot_path, system_target, @intFromEnum(android_api_level) });

    const libc_file_contents = b.fmt(libc_file_format, .{
        .include_dir = include_dir,
        .sys_include_dir = sys_include_dir,
        .crt_dir = crt_dir,
    });

    const filename = b.fmt("android-libc_target-{s}_version-{}_ndk-{s}.conf", .{ system_target, @intFromEnum(android_api_level), ndk_version });

    const write_file = b.addWriteFiles();
    const android_libc_path = write_file.add(filename, libc_file_contents);
    return android_libc_path;
}

/// Caller must free returned memory
fn getAndroidSDKPath(b: *std.Build) error{OutOfMemory}![]const u8 {
    const allocator = b.allocator;
    const environ_map = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
        &b.graph.env_map
    else
        &b.graph.environ_map;

    if (environ_map.get("ANDROID_HOME")) |android_home| if (android_home.len > 0)
        return android_home;

    // Check for Android Studio
    switch (builtin.os.tag) {
        .windows => {
            // NOTE(jae): 2026-01-10
            // At least as of Android Studio Meerkat (2024.3.1), built on March 13th 2025.
            // This logic will not do anything on Windows. SdkPath is empty.
            //
            // So let's just remove this.
            //
            // First, see if SdkPath in the registry is set
            // - Computer\HKEY_LOCAL_MACHINE\SOFTWARE\Android Studio - "SdkPath"
            // - Computer\KHEY_CURRENT_USER\SOFTWARE\Android Studio  - "SdkPath"
            //
            // const windows = std.os.windows;
            // const RegistryWtf8 = @import("WindowsSdk.zig").RegistryWtf8;
            // const android_studio_sdk_path: []const u8 = blk: {
            //     for ([_]windows.HKEY{ windows.HKEY_CURRENT_USER, windows.HKEY_LOCAL_MACHINE }) |hkey| {
            //         const key = RegistryWtf8.openKey(hkey, "SOFTWARE", .{}) catch |err| switch (err) {
            //             error.KeyNotFound => continue,
            //         };
            //         // NOTE(jae): 2025-05-25 - build.txt file says "AI-243.24978.46.2431.13208083"
            //         // For my install, "SdkPath" is an empty string, so this may not be used anymore.
            //         const sdk_path = key.getString(allocator, "Android Studio", "SdkPath") catch |err| switch (err) {
            //             error.StringNotFound, error.ValueNameNotFound, error.NotAString => continue,
            //             error.OutOfMemory => return error.OutOfMemory,
            //         };
            //         break :blk sdk_path;
            //     }
            //     break :blk &[0]u8{};
            // };
            // if (android_studio_sdk_path.len > 0) {
            //     return android_studio_sdk_path;
            // }
        },
        // NOTE(jae): 2024-09-15
        // Look into auto-discovery of Android SDK for Mac
        // Mac: /Users/<username>/Library/Android/sdk
        .macos => {
            const user = environ_map.get("USER") orelse &[0]u8{};
            defer allocator.free(user);
            return try std.fmt.allocPrint(allocator, "/Users/{s}/Library/Android/sdk", .{user});
        },
        // NOTE(jae: 2025-05-11
        // Auto-discovery of Android SDK for Linux
        // - /home/AccountName/Android/Sdk
        // - /usr/lib/android-sdk
        // - /Library/Android/sdk
        // - /Users/[USER]/Library/Android/sdk
        // Source: https://stackoverflow.com/a/34627928
        .linux => {
            for ([_][]const u8{
                "/usr/lib/android-sdk",
                "/Library/Android/sdk",
            }) |android_sdk_path| {
                const has_path: bool = pathblk: {
                    const access_wrapped_error = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
                        std.fs.accessAbsolute(android_sdk_path, .{})
                    else
                        std.Io.Dir.accessAbsolute(b.graph.io, android_sdk_path, .{});
                    access_wrapped_error catch |err| switch (err) {
                        error.FileNotFound => break :pathblk false, // fallthrough and try next
                        else => std.debug.panic("{s} has error: {}", .{ android_sdk_path, err }),
                    };
                    break :pathblk true;
                };
                if (!has_path) {
                    continue;
                }
                return android_sdk_path;
            }

            // Check user paths
            // - /home/AccountName/Android/Sdk
            // - /Users/[USER]/Library/Android/sdk
            const user = environ_map.get("USER") orelse &[0]u8{};
            if (user.len > 0) {
                inline for ([_][]const u8{
                    "/Users/{s}/Library/Android/sdk",
                    // NOTE(jae): 2025-05-11
                    // No idea if /AccountName/ maps to $USER but going to assume it does for now.
                    "/home/{s}/Android/Sdk",
                }) |android_sdk_user_path_template| {
                    const android_sdk_path = try std.fmt.allocPrint(allocator, android_sdk_user_path_template, .{user});
                    errdefer allocator.free(android_sdk_path);
                    const has_path: bool = pathblk: {
                        const access_wrapped_error = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
                            std.fs.accessAbsolute(android_sdk_path, .{})
                        else
                            std.Io.Dir.accessAbsolute(b.graph.io, android_sdk_path, .{});
                        access_wrapped_error catch |err| switch (err) {
                            error.FileNotFound => break :pathblk false, // fallthrough and try next
                            else => std.debug.panic("{s} has error: {}", .{ android_sdk_path, err }),
                        };
                        break :pathblk true;
                    };
                    if (has_path) {
                        return android_sdk_path;
                    }
                    allocator.free(android_sdk_path);
                }
            }
        },
        else => {},
    }
    return &[0]u8{};
}

pub const KeyStore = struct {
    file: LazyPath,
    password: []const u8,

    pub const empty: KeyStore = .{
        .file = .{ .cwd_relative = "" },
        .password = "",
    };
};

/// Searches your PATH environment variable directories for adb, jarsigner, etc
const PathSearch = struct {
    b: *std.Build,
    allocator: std.mem.Allocator,
    path_env: []const u8,
    path_it: std.mem.SplitIterator(u8, .scalar),

    /// "adb" or "adb.exe"
    adb: []const u8,
    /// "jarsigner" or "jarsigner.exe"
    jarsigner: []const u8,

    android_sdk_path: ?[]const u8 = null,
    jdk_path: ?[]const u8,

    pub fn init(b: *std.Build, host_os_tag: std.Target.Os.Tag) error{ EnvironmentVariableNotFound, OutOfMemory }!PathSearch {
        const allocator = b.allocator;
        const environ_map = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
            &b.graph.env_map
        else
            &b.graph.environ_map;

        const path_env = environ_map.get("PATH") orelse return error.EnvironmentVariableNotFound;
        if (path_env.len == 0) {
            return error.EnvironmentVariableNotFound;
        }

        // setup binaries to search for
        const exe_suffix = if (host_os_tag == .windows) ".exe" else "";
        const adb = try std.mem.concat(allocator, u8, &.{ "adb", exe_suffix });
        const jarsigner = try std.mem.concat(allocator, u8, &.{ "jarsigner", exe_suffix });

        // setup paths
        const configured_jdk_path: ?[]const u8 = jdkpath: {
            const jdk_home = environ_map.get("JDK_HOME") orelse &[0]u8{};
            if (jdk_home.len > 0) {
                break :jdkpath jdk_home;
            }
            const java_home = environ_map.get("JAVA_HOME") orelse &[0]u8{};
            if (java_home.len > 0) {
                break :jdkpath java_home;
            }
            if (host_os_tag == .linux) {
                // const environ_map = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
                //     &b.graph.env_map
                // else
                //     &b.graph.environ_map;
                const maybe_user: ?[]const u8 = environ_map.get("USER") orelse null;
                if (maybe_user) |user| {
                    const jarsigner_path = b.findProgram(&.{"jarsigner"}, &.{
                        // NOTE(jae): 2026-01-10
                        // I manually put my install here, not standard per-se but I see no reason to not support this.
                        b.fmt("/home/{s}/android-studio/jbr/bin", .{user}),
                        // NOTE(jae): 2026-01-10
                        // Suggested install locations for Android Studio from: https://developer.android.com/studio/install
                        "/usr/local/android-studio/jbr/bin", // for your user profile
                        "/opt/android-studio/jbr/bin", // for shared users
                    }) catch break :jdkpath null;
                    const jbr_bin_dir = std.fs.path.dirname(jarsigner_path) orelse break :jdkpath null;
                    const jbr_dir = std.fs.path.dirname(jbr_bin_dir) orelse break :jdkpath null;
                    break :jdkpath jbr_dir;
                }
            }
            break :jdkpath null;
        };

        const path_it = std.mem.splitScalar(u8, path_env, ';');
        return .{
            .b = b,
            .allocator = allocator,
            .path_env = path_env,
            .path_it = path_it,
            .adb = adb,
            .jarsigner = jarsigner,
            .jdk_path = configured_jdk_path,
        };
    }

    pub fn deinit(_: *PathSearch) void {
        // NOTE(jae): 2026-01-09: Using copy from "b.graph.environ_map" now
        // const allocator = self.allocator;
        // allocator.free(self.path_env);
    }

    /// Get the Android SDK Path, the caller owns the memory
    pub fn findAndroidSDK(self: *PathSearch, allocator: std.mem.Allocator) Allocator.Error![]const u8 {
        if (self.android_sdk_path == null) {
            // Iterate over PATH environment folders until we either hit the end or the Android SDK folder
            try self.getNext(.androidsdk);
        }
        // Get the Android SDK path
        const android_sdk_path = self.android_sdk_path orelse unreachable;
        if (android_sdk_path.len == 0) return &[0]u8{};
        return allocator.dupe(u8, android_sdk_path);
    }

    /// Get the JDK Path, the caller owns the memory
    pub fn findJDK(self: *PathSearch, allocator: std.mem.Allocator) Allocator.Error![]const u8 {
        if (self.jdk_path == null) {
            // Iterate over PATH environment folders until we either hit the end or the Android SDK folder
            try self.getNext(.jdk);
        }
        // Get the Java Home path
        const jdk_path = self.jdk_path orelse unreachable;
        if (jdk_path.len == 0) return &[0]u8{};
        return allocator.dupe(u8, jdk_path);
    }

    const PathType = enum {
        androidsdk,
        jdk,
    };

    fn getNext(self: *PathSearch, path: PathType) Allocator.Error!void {
        const allocator = self.allocator;
        while (self.path_it.next()) |path_item| {
            if (path_item.len == 0) continue;

            // If we haven't found Android SDK Path yet, check
            blk: {
                if (self.android_sdk_path == null) {
                    // Check $PATH/adb.exe
                    {
                        const adb_binary_path = std.fs.path.join(allocator, &.{ path_item, self.adb }) catch |err| return err;
                        defer allocator.free(adb_binary_path);
                        if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
                            std.fs.accessAbsolute(adb_binary_path, .{}) catch break :blk
                        else
                            std.Io.Dir.accessAbsolute(self.b.graph.io, adb_binary_path, .{}) catch break :blk;
                    }
                    // Transform: "Sdk\platform-tools" into "Sdk"
                    const sdk_path = std.fs.path.dirname(path_item) orelse {
                        // If found adb.exe in a root directory, it can't be the Android SDK, skip
                        break :blk;
                    };
                    self.android_sdk_path = sdk_path;
                    if (path == .androidsdk) {
                        // If specifically just wanting the Android SDK path right now, stop here
                        return;
                    }
                    continue;
                }
            }
            // If we haven't found JDK Path yet, check
            blk: {
                if (self.jdk_path == null) {
                    // Check $PATH/jarsigner.exe
                    {
                        const jarsigner_binary_path = std.fs.path.join(allocator, &.{ path_item, self.jarsigner }) catch |err| return err;
                        defer allocator.free(jarsigner_binary_path);

                        if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
                            std.fs.accessAbsolute(jarsigner_binary_path, .{}) catch break :blk
                        else
                            std.Io.Dir.accessAbsolute(self.b.graph.io, jarsigner_binary_path, .{}) catch break :blk;
                    }
                    // Transform: "jdk-21.0.3.9-hotspot/bin" into "jdk-21.0.3.9-hotspot"
                    const jdk_path = std.fs.path.dirname(path_item) orelse {
                        // If found adb.exe in a root directory, it can't be the Android SDK, skip
                        break :blk;
                    };
                    self.jdk_path = jdk_path;
                    if (path == .jdk) {
                        // If specifically just wanting the JDK path right now, stop here
                        return;
                    }
                    continue;
                }
            }
        }
        // If we didn't discover the paths, set to empty slice
        if (self.android_sdk_path == null) {
            self.android_sdk_path = &[0]u8{};
        }
        if (self.jdk_path == null) {
            self.jdk_path = &[0]u8{};
        }
    }
};

const Sdk = @This();
