//! DirectoryFileInput adds files within a directory to the dependencies of the given Step.Run command
//! This is required so that generated directories will work.

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

step: Step,

/// Runner to update
run: *Build.Step.Run,

/// The directory that will contain the files to glob
dir: LazyPath,

pub fn create(owner: *std.Build, run: *Run, dir: LazyPath) void {
    const self = owner.allocator.create(DirectoryFileInput) catch @panic("OOM");
    self.* = .{
        .step = Step.init(.{
            .id = .custom,
            .name = androidbuild.runNameContext("directory-file-input"),
            .owner = owner,
            .makeFn = make,
        }),
        .run = run,
        .dir = dir,
    };
    // Run step relies on DirectoryFileInput finishing
    run.step.dependOn(&self.step);
    // If dir is generated then this will wait for that dir to generate
    dir.addStepDependencies(&self.step);
}

fn make(step: *Step, _: Build.Step.MakeOptions) !void {
    const b = step.owner;
    const arena = b.allocator;
    const self: *DirectoryFileInput = @fieldParentPtr("step", step);

    const run = self.run;
    const dir_path = self.dir.getPath3(b, step);

    // NOTE(jae): 2025-07-23
    // As of Zig 0.15.0-dev.1092+d772c0627, package_name_path.openDir("") is not possible as it assumes you're appending a sub-path
    var dir = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
        try dir_path.root_dir.handle.openDir(dir_path.sub_path, .{ .iterate = true })
    else
        try dir_path.root_dir.handle.openDir(b.graph.io, dir_path.sub_path, .{ .iterate = true });
    defer if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
        dir.close()
    else
        dir.close(b.graph.io);

    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
        try walker.next()
    else
        try walker.next(b.graph.io)) |entry|
    {
        if (entry.kind != .file) continue;

        // Add file as dependency to run command
        run.addFileInput(LazyPath{
            .cwd_relative = try dir_path.root_dir.join(b.allocator, &.{ dir_path.sub_path, entry.path }),
        });
    }
}

const DirectoryFileInput = @This();
