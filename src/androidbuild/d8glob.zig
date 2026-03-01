//! D8Glob is specific for D8 and is used to collect all *.class output files after a javac process generates them

const std = @import("std");
const androidbuild = @import("androidbuild.zig");
const builtin = @import("builtin");
const Build = std.Build;
const Step = Build.Step;
const Run = Build.Step.Run;
const LazyPath = Build.LazyPath;
const fs = std.fs;
const mem = std.mem;
const assert = std.debug.assert;

pub const base_id: Step.Id = .custom;

step: Step,

/// Runner to update
run: *Build.Step.Run,

/// The directory that will contain the files to glob
dir: LazyPath,

/// Track the files added to the Run step for --watch
argv_range: ?ArgRange,

const file_ext = ".class";

const ArgRange = struct {
    start: usize,
    end: usize,
};

/// Creates a D8Glob step which is used to collect all *.class output files after a javac process generates them
pub fn create(owner: *std.Build, run: *Run, dir: LazyPath, root_jar: LazyPath) void {
    const glob = owner.allocator.create(@This()) catch @panic("OOM");
    glob.* = .{
        .step = Step.init(.{
            .id = base_id,
            .name = androidbuild.runNameContext("d8glob"),
            .owner = owner,
            .makeFn = make,
        }),
        .run = run,
        .dir = dir,
        .argv_range = null,
    };
    // Run step relies on this finishing
    run.step.dependOn(&glob.step);
    // If dir is generated then this will wait for that dir to generate
    dir.addStepDependencies(&glob.step);
    // If root_jar changes, then this should trigger
    root_jar.addStepDependencies(&glob.step);
}

fn make(step: *Step, options: Build.Step.MakeOptions) !void {
    _ = options;
    const b = step.owner;
    const arena = b.allocator;
    const gpa = b.allocator;
    const glob: *@This() = @fieldParentPtr("step", step);

    const d8 = glob.run;

    // Triggers on --watch if a Java file is modified.
    // For example: ZigSDLActivity.java
    if (glob.argv_range) |argv_range| {
        try d8.argv.replaceRange(d8.step.owner.allocator, argv_range.start, argv_range.end - argv_range.start, &.{});
    }

    const search_dir = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
        glob.dir.getPath3(b, step)
    else
        try glob.dir.getPath4(b, step);

    // NOTE(jae): 2024-09-22
    // Change current working directory to where the Java classes are
    // This is to avoid the Java error "command line too long" that can occur with d8
    //
    // I was hitting this due to a path this long on Windows
    // J:\ZigProjects\openxr-game\third-party\zig-android-sdk\examples\sdl2\.zig-cache\o\9012552ac182acf9dfb49627cf81376e\android_dex
    //
    // A deeper fix to this problem could be:
    // - Zip up all the *.class files and just provide that as ONE argument or alternatively
    // - If "d8" has the ability to pass a file of command line parameters, that would work too but I haven't seen any in the docs
    d8.setCwd(glob.dir);

    // NOTE(jae): 2025-07-23
    // As of Zig 0.15.0-dev.1092+d772c0627, package_name_path.openDir("") is not possible as it assumes you're appending a sub-path
    var dir = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
        try search_dir.root_dir.handle.openDir(search_dir.sub_path, .{ .iterate = true })
    else
        try search_dir.root_dir.handle.openDir(b.graph.io, search_dir.sub_path, .{ .iterate = true });
    defer if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
        dir.close()
    else
        dir.close(b.graph.io);

    var optional_argv_start: ?usize = null;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
        try walker.next()
    else
        try walker.next(b.graph.io)) |entry|
    {
        if (entry.kind != .file) {
            continue;
        }
        // NOTE(jae): 2024-10-01
        // Initially ignored classes with alternate API postfixes / etc but
        // that did not work with SDL2 so no longer do that.
        // - !std.mem.containsAtLeast(u8, entry.basename, 1, "$") and
        // - !std.mem.containsAtLeast(u8, entry.basename, 1, "_API")
        if (std.mem.endsWith(u8, entry.path, file_ext)) {
            const absolute_file_path = try search_dir.root_dir.join(gpa, &.{ search_dir.sub_path, entry.path });
            const relative_to_dir_path = absolute_file_path[search_dir.sub_path.len + 1 ..];
            // NOTE(jae): 2024-09-22
            // We set the current working directory to "glob.Dir" and then make arguments be
            // relative to that directory.
            //
            // This is to avoid the Java error "command line too long" that can occur with d8
            if (optional_argv_start == null) {
                optional_argv_start = d8.argv.items.len;
            }
            d8.addFileInput(LazyPath{
                .cwd_relative = absolute_file_path,
            });
            d8.addArg(relative_to_dir_path);
        }
    }

    // Track arguments added to "d8" so that we can remove them if "make" is re-run in --watch mode
    if (optional_argv_start) |argv_start| {
        glob.argv_range = .{
            .start = argv_start,
            .end = d8.argv.items.len,
        };
    }
}

const D8Glob = @This();
