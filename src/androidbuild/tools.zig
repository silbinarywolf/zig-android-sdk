const std = @import("std");
const builtin = @import("builtin");
const androidbuild = @import("androidbuild.zig");

/// Used for reading install locations from the registry
const RegistryWtf8 = @import("WindowsSdk.zig").RegistryWtf8;
const windows = std.os.windows;

const APILevel = androidbuild.APILevel;
const KeyStore = androidbuild.KeyStore;
const getAndroidTriple = androidbuild.getAndroidTriple;
const runNameContext = androidbuild.runNameContext;
const printErrorsAndExit = androidbuild.printErrorsAndExit;

const Build = std.Build;
const AccessError = std.fs.Dir.AccessError;
const Step = Build.Step;
const ResolvedTarget = Build.ResolvedTarget;
const LazyPath = std.Build.LazyPath;

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
    pub fn example() @This() {
        return .{
            .alias = "default",
            .password = "example_password",
            .algorithm = .rsa,
            .key_size_in_bits = 4096,
            .validity_in_days = 10_000,
            .distinguished_name = "CN=example.com, OU=ID, O=Example, L=Doe, S=Jane, C=GB",
        };
    }
};

pub const ToolsOptions = struct {
    /// ie. "35.0.0"
    build_tools_version: []const u8,
    /// ie. "27.0.12077973"
    ndk_version: []const u8,
    /// ie. .android15 = 35 (android 15 uses API version 35)
    api_level: APILevel,
};

pub const Tools = struct {
    b: *Build,

    /// On most platforms this will map to the $ANDROID_HOME environment variable
    android_sdk_path: []const u8,
    /// ie. .android15 = 35 (android 15 uses API version 35)
    api_level: APILevel,
    /// ie. "27.0.12077973"
    ndk_version: []const u8,
    /// ie. "$ANDROID_HOME/ndk/{ndk_version}/toolchains/llvm/prebuilt/{host_os_and_arch}/sysroot"
    ndk_sysroot_path: []const u8,
    /// ie. "$ANDROID_HOME/Sdk/platforms/android-{api_level}/android.jar"
    root_jar: []const u8,
    // $JDK_HOME, $JAVA_HOME or auto-discovered from java binaries found in $PATH
    jdk_path: []const u8,
    /// ie. $ANDROID_HOME/build-tools/35.0.0
    build_tools: struct {
        aapt2: []const u8,
        zipalign: []const u8,
        d8: []const u8,
        apksigner: []const u8,
    },
    /// ie. $ANDROID_HOME/cmdline_tools/bin or $ANDROID_HOME/tools/bin
    ///
    /// Available to download at: https://developer.android.com/studio#command-line-tools-only
    /// The commandline tools ZIP expected looks like: commandlinetools-{OS}-11076708_latest.zip
    cmdline_tools: struct {
        /// lint [flags] <project directory>
        /// See documentation: https://developer.android.com/studio/write/lint#commandline
        lint: []const u8,
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

    pub fn createKeyStore(tools: *const Tools, options: CreateKey) KeyStore {
        const b = tools.b;
        const keytool = b.addSystemCommand(&.{
            // https://docs.oracle.com/en/java/javase/17/docs/specs/man/keytool.html
            tools.java_tools.keytool,
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
        _ = keytool.captureStdErr();
        return .{
            .file = keystore_file,
            .password = options.password,
        };
    }

    // TODO: Consider making this be setup on "create" and then we just pass in the "android_libc_writefile"
    // anytime setLibCFile is called
    pub fn setLibCFile(tools: *const Tools, compile: *Step.Compile) void {
        const b = tools.b;

        const target: ResolvedTarget = compile.root_module.resolved_target orelse {
            @panic(b.fmt("no 'target' set on Android module", .{}));
        };
        const system_target = getAndroidTriple(target) catch |err| @panic(@errorName(err));

        const android_libc_path = createLibC(
            b,
            system_target,
            tools.api_level,
            tools.ndk_sysroot_path,
            tools.ndk_version,
        );
        android_libc_path.addStepDependencies(&compile.step);
        compile.setLibCFile(android_libc_path);
    }

    pub fn create(b: *std.Build, options: ToolsOptions) *Tools {
        const host_os_tag = b.graph.host.result.os.tag;
        const host_os_and_arch: [:0]const u8 = switch (host_os_tag) {
            .windows => "windows-x86_64",
            .linux => "linux-x86_64",
            .macos => "darwin-x86_64",
            else => @panic(b.fmt("unhandled operating system: {}", .{host_os_tag})),
        };

        // Discover tool paths
        var path_search = PathSearch.init(b.allocator, host_os_tag) catch |err| switch (err) {
            error.OutOfMemory => @panic("OOM"),
            error.EnvironmentVariableNotFound => @panic("unable to find PATH as an environment variable"),
        };
        const configured_jdk_path = getJDKPath(b.allocator) catch @panic("OOM");
        if (configured_jdk_path.len > 0) {
            // Set JDK path here so it will not try searching for jarsigner.exe if searching for Android SDK
            path_search.jdk_path = configured_jdk_path;
        }
        const configured_android_sdk_path = getAndroidSDKPath(b.allocator) catch @panic("OOM");
        if (configured_android_sdk_path.len > 0) {
            // Set android SDK path here so it will not try searching for adb.exe if searching for JDK
            path_search.android_sdk_path = configured_android_sdk_path;
        }
        const android_sdk_path = path_search.findAndroidSDK(b.allocator) catch @panic("OOM");
        const jdk_path = path_search.findJDK(b.allocator) catch @panic("OOM");

        // Get build tools path
        // ie. $ANDROID_HOME/build-tools/35.0.0
        const build_tools_path = b.pathResolve(&[_][]const u8{ android_sdk_path, "build-tools", options.build_tools_version });

        // Get NDK path
        // ie. $ANDROID_HOME/ndk/27.0.12077973
        const android_ndk_path = b.fmt("{s}/ndk/{s}", .{ android_sdk_path, options.ndk_version });

        // Get NDK sysroot path
        // ie. $ANDROID_HOME/ndk/{ndk_version}/toolchains/llvm/prebuilt/{host_os_and_arch}/sysroot
        const android_ndk_sysroot = b.fmt("{s}/ndk/{s}/toolchains/llvm/prebuilt/{s}/sysroot", .{
            android_sdk_path,
            options.ndk_version,
            host_os_and_arch,
        });

        // Get root jar path
        const root_jar = b.pathResolve(&[_][]const u8{
            android_sdk_path,
            "platforms",
            b.fmt("android-{d}", .{@intFromEnum(options.api_level)}),
            "android.jar",
        });

        // Validate
        var errors = std.ArrayList([]const u8).init(b.allocator);
        defer errors.deinit();

        // Get commandline tools path
        // - 1st: $ANDROID_HOME/cmdline-tools/bin
        // - 2nd: $ANDROID_HOME/tools/bin
        const cmdline_tools_path = cmdlineblk: {
            const cmdline_tools = b.pathResolve(&[_][]const u8{ android_sdk_path, "cmdline-tools", "bin" });
            std.fs.accessAbsolute(cmdline_tools, .{}) catch |cmderr| switch (cmderr) {
                error.FileNotFound => {
                    const tools = b.pathResolve(&[_][]const u8{ android_sdk_path, "tools", "bin" });
                    // Check if Commandline tools path is accessible
                    std.fs.accessAbsolute(tools, .{}) catch |toolerr| switch (toolerr) {
                        error.FileNotFound => {
                            const message = b.fmt("Android Command Line Tools not found. Expected at: {s} or {s}", .{
                                cmdline_tools,
                                tools,
                            });
                            errors.append(message) catch @panic("OOM");
                        },
                        else => {
                            const message = b.fmt("Android Command Line Tools path had unexpected error: {s} ({s})", .{
                                @errorName(toolerr),
                                tools,
                            });
                            errors.append(message) catch @panic("OOM");
                        },
                    };
                },
                else => {
                    const message = b.fmt("Android Command Line Tools path had unexpected error: {s} ({s})", .{
                        @errorName(cmderr),
                        cmdline_tools,
                    });
                    errors.append(message) catch @panic("OOM");
                },
            };
            break :cmdlineblk cmdline_tools;
        };

        if (jdk_path.len == 0) {
            errors.append(
                \\JDK not found.
                \\- Download it from https://www.oracle.com/th/java/technologies/downloads/
                \\- Then configure your JDK_HOME environment variable to where you've installed it.
            ) catch @panic("OOM");
        }
        if (android_sdk_path.len == 0) {
            errors.append(
                \\Android SDK not found.
                \\- Download it from https://developer.android.com/studio
                \\- Then configure your ANDROID_HOME environment variable to where you've installed it."
            ) catch @panic("OOM");
        } else {
            // Check if build tools path is accessible
            // ie. $ANDROID_HOME/build-tools/35.0.0
            std.fs.accessAbsolute(build_tools_path, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    const message = b.fmt("Android Build Tool version '{s}' not found. Install it via 'sdkmanager' or Android Studio.", .{
                        options.build_tools_version,
                    });
                    errors.append(message) catch @panic("OOM");
                },
                else => {
                    const message = b.fmt("Android Build Tool version '{s}' had unexpected error: {s}", .{
                        options.build_tools_version,
                        @errorName(err),
                    });
                    errors.append(message) catch @panic("OOM");
                },
            };

            // Check if NDK path is accessible
            // ie. $ANDROID_HOME/ndk/27.0.12077973
            const has_ndk: bool = blk: {
                std.fs.accessAbsolute(android_ndk_path, .{}) catch |err| switch (err) {
                    error.FileNotFound => {
                        const message = b.fmt("Android NDK version '{s}' not found. Install it via 'sdkmanager' or Android Studio.", .{
                            options.ndk_version,
                        });
                        errors.append(message) catch @panic("OOM");
                        break :blk false;
                    },
                    else => {
                        const message = b.fmt("Android NDK version '{s}' had unexpected error: {s} ({s})", .{
                            options.ndk_version,
                            @errorName(err),
                            android_ndk_path,
                        });
                        errors.append(message) catch @panic("OOM");
                        break :blk false;
                    },
                };
                break :blk true;
            };

            // Check if NDK API level is accessible
            if (has_ndk) {
                // Check if NDK sysroot path is accessible
                const has_ndk_sysroot = blk: {
                    std.fs.accessAbsolute(android_ndk_sysroot, .{}) catch |err| switch (err) {
                        error.FileNotFound => {
                            const message = b.fmt("Android NDK sysroot '{s}' had unexpected error. Missing at '{s}'", .{
                                options.ndk_version,
                                android_ndk_sysroot,
                            });
                            errors.append(message) catch @panic("OOM");
                            break :blk false;
                        },
                        else => {
                            const message = b.fmt("Android NDK sysroot '{s}' had unexpected error: {s}, at: '{s}'", .{
                                options.ndk_version,
                                @errorName(err),
                                android_ndk_sysroot,
                            });
                            errors.append(message) catch @panic("OOM");
                            break :blk false;
                        },
                    };
                    break :blk true;
                };

                // Check if NDK sysroot/usr/lib/{target}/{api_level} path is accessible
                if (has_ndk_sysroot) {
                    _ = blk: {
                        // "x86" has existed since Android 4.1 (API version 16)
                        const x86_system_target = "i686-linux-android";
                        const ndk_sysroot_target_api_version = b.fmt("{s}/usr/lib/{s}/{d}", .{ android_ndk_sysroot, x86_system_target, options.api_level });
                        std.fs.accessAbsolute(android_ndk_sysroot, .{}) catch |err| switch (err) {
                            error.FileNotFound => {
                                const message = b.fmt("Android NDK version '{s}' does not support API Level {d}. No folder at '{s}'", .{
                                    options.ndk_version,
                                    @intFromEnum(options.api_level),
                                    ndk_sysroot_target_api_version,
                                });
                                errors.append(message) catch @panic("OOM");
                                break :blk false;
                            },
                            else => {
                                const message = b.fmt("Android NDK version '{s}' API Level {d} had unexpected error: {s}, at: '{s}'", .{
                                    options.ndk_version,
                                    @intFromEnum(options.api_level),
                                    @errorName(err),
                                    ndk_sysroot_target_api_version,
                                });
                                errors.append(message) catch @panic("OOM");
                                break :blk false;
                            },
                        };
                        break :blk true;
                    };
                }

                // Check if platforms/android-{api-level}/android.jar exists
                _ = blk: {
                    std.fs.accessAbsolute(root_jar, .{}) catch |err| switch (err) {
                        error.FileNotFound => {
                            const message = b.fmt("Android API level {d} not installed. Unable to find '{s}'", .{
                                @intFromEnum(options.api_level),
                                root_jar,
                            });
                            errors.append(message) catch @panic("OOM");
                            break :blk false;
                        },
                        else => {
                            const message = b.fmt("Android API level {d} had unexpected error: {s}, at: '{s}'", .{
                                @intFromEnum(options.api_level),
                                @errorName(err),
                                root_jar,
                            });
                            errors.append(message) catch @panic("OOM");
                            break :blk false;
                        },
                    };
                    break :blk true;
                };
            }
        }
        if (errors.items.len > 0) {
            printErrorsAndExit("unable to find required Android installation", errors.items);
        }

        const exe_suffix = if (host_os_tag == .windows) ".exe" else "";
        const bat_suffix = if (host_os_tag == .windows) ".bat" else "";

        const tools: *Tools = b.allocator.create(Tools) catch @panic("OOM");
        tools.* = .{
            .b = b,
            .android_sdk_path = android_sdk_path,
            .api_level = options.api_level,
            .ndk_version = options.ndk_version,
            .ndk_sysroot_path = android_ndk_sysroot,
            .root_jar = root_jar,
            .jdk_path = jdk_path,
            .build_tools = .{
                .aapt2 = b.pathResolve(&[_][]const u8{
                    build_tools_path, b.fmt("aapt2{s}", .{exe_suffix}),
                }),
                .zipalign = b.pathResolve(&[_][]const u8{
                    build_tools_path, b.fmt("zipalign{s}", .{exe_suffix}),
                }),
                // d8/apksigner are *.bat or shell scripts that require "java"/"java.exe" to exist in
                // your PATH
                .d8 = b.pathResolve(&[_][]const u8{
                    build_tools_path, b.fmt("d8{s}", .{bat_suffix}),
                }),
                .apksigner = b.pathResolve(&[_][]const u8{
                    build_tools_path, b.fmt("apksigner{s}", .{bat_suffix}),
                }),
            },
            .cmdline_tools = .{
                .lint = b.pathResolve(&[_][]const u8{
                    cmdline_tools_path, b.fmt("lint{s}", .{bat_suffix}),
                }),
                // NOTE(jae): 2024-09-28
                // Consider adding sdkmanager.bat so you can do something like "zig build sdkmanager -- {args}"
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
        return tools;
    }
};

fn createLibC(b: *std.Build, system_target: []const u8, android_version: APILevel, ndk_sysroot_path: []const u8, ndk_version: []const u8) LazyPath {
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
    const crt_dir = b.fmt("{s}/usr/lib/{s}/{d}", .{ ndk_sysroot_path, system_target, @intFromEnum(android_version) });

    const libc_file_contents = b.fmt(libc_file_format, .{
        .include_dir = include_dir,
        .sys_include_dir = sys_include_dir,
        .crt_dir = crt_dir,
    });

    const filename = b.fmt("android-libc_target-{s}_version-{}_ndk-{s}.conf", .{ system_target, @intFromEnum(android_version), ndk_version });

    const write_file = b.addWriteFiles();
    const android_libc_path = write_file.add(filename, libc_file_contents);
    return android_libc_path;
}

/// Search JDK_HOME, and then JAVA_HOME
fn getJDKPath(allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    const jdkHome = std.process.getEnvVarOwned(allocator, "JDK_HOME") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EnvironmentVariableNotFound => &[0]u8{},
        // Windows-only
        error.InvalidWtf8 => @panic("JDK_HOME environment variable is invalid UTF-8"),
    };
    if (jdkHome.len > 0) {
        return jdkHome;
    }

    const javaHome = std.process.getEnvVarOwned(allocator, "JAVA_HOME") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EnvironmentVariableNotFound => &[0]u8{},
        // Windows-only
        error.InvalidWtf8 => @panic("JAVA_HOME environment variable is invalid UTF-8"),
    };
    if (javaHome.len > 0) {
        return javaHome;
    }

    return &[0]u8{};
}

/// Caller must free returned memory
fn getAndroidSDKPath(allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    const androidHome = std.process.getEnvVarOwned(allocator, "ANDROID_HOME") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EnvironmentVariableNotFound => &[0]u8{},
        // Windows-only
        error.InvalidWtf8 => @panic("ANDROID_HOME environment variable is invalid UTF-8"),
    };
    if (androidHome.len > 0) {
        return androidHome;
    }

    // Check for Android Studio
    switch (builtin.os.tag) {
        .windows => {
            // First, see if SdkPath in the registry is set
            // - Computer\HKEY_LOCAL_MACHINE\SOFTWARE\Android Studio - "SdkPath"
            // - Computer\KHEY_CURRENT_USER\SOFTWARE\Android Studio - "SdkPath"
            const android_studio_sdk_path: []const u8 = blk: {
                for ([_]windows.HKEY{ windows.HKEY_CURRENT_USER, windows.HKEY_LOCAL_MACHINE }) |hkey| {
                    const key = RegistryWtf8.openKey(hkey, "SOFTWARE", .{}) catch |err| switch (err) {
                        error.KeyNotFound => continue,
                    };
                    const sdk_path = key.getString(allocator, "Android Studio", "SdkPath") catch |err| switch (err) {
                        error.StringNotFound, error.ValueNameNotFound, error.NotAString => continue,
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    break :blk sdk_path;
                }
                break :blk &[0]u8{};
            };
            if (android_studio_sdk_path.len > 0) {
                return android_studio_sdk_path;
            }
        },
        // NOTE(jae): 2024-09-15
        // Look into auto-discovery of Android SDK for Mac
        // Mac: /Users/<username>/Library/Android/sdk
        // .macos => {},
        else => {},
    }
    return &[0]u8{};
}

/// Searches your PATH environment variable directories for adb, jarsigner, etc
const PathSearch = struct {
    allocator: std.mem.Allocator,
    path_env: []const u8,
    path_it: std.mem.SplitIterator(u8, .scalar),

    /// "adb" or "adb.exe"
    adb: []const u8,
    /// "jarsigner" or "jarsigner.exe"
    jarsigner: []const u8,

    android_sdk_path: ?[]const u8 = null,
    jdk_path: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, host_os_tag: std.Target.Os.Tag) error{ EnvironmentVariableNotFound, OutOfMemory }!PathSearch {
        const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.EnvironmentVariableNotFound => return error.EnvironmentVariableNotFound,
            // Windows-only
            error.InvalidWtf8 => @panic("PATH environment variable is invalid UTF-8"),
        };
        if (path_env.len == 0) {
            return error.EnvironmentVariableNotFound;
        }

        // setup binaries to search for
        const exe_suffix = if (host_os_tag == .windows) ".exe" else "";
        const adb = std.mem.concat(allocator, u8, &.{ "adb", exe_suffix }) catch |err| return err;
        const jarsigner = std.mem.concat(allocator, u8, &.{ "jarsigner", exe_suffix }) catch |err| return err;

        const path_it = std.mem.splitScalar(u8, path_env, ';');
        return .{
            .allocator = allocator,
            .path_env = path_env,
            .path_it = path_it,
            .adb = adb,
            .jarsigner = jarsigner,
        };
    }

    pub fn deinit(self: *PathSearch) void {
        const allocator = self.allocator;
        allocator.free(self.path_env);
    }

    /// Get the Android SDK Path, the caller owns the memory
    pub fn findAndroidSDK(self: *PathSearch, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
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
    pub fn findJDK(self: *PathSearch, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
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

    fn getNext(self: *PathSearch, path: PathType) error{OutOfMemory}!void {
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
                        std.fs.accessAbsolute(adb_binary_path, .{}) catch {
                            break :blk;
                        };
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

                        std.fs.accessAbsolute(jarsigner_binary_path, .{}) catch {
                            break :blk;
                        };
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
