//! DirectoryFileInput adds files within a directory to the dependencies of the given Step.Run command
//! This is required so that generated directories will work.

const androidbuild = @import("androidbuild.zig");
const builtin = @import("builtin");
const Build = @import("std").Build;
const Step = Build.Step;
const Run = Build.Step.Run;
const LazyPath = Build.LazyPath;
const fs = @import("std").fs;
const mem = @import("std").mem;
const debug = @import("std").debug;

step: Step,

/// Runner to update
run: *Build.Step.Run,

/// The directory that will contain the files to glob
dir: LazyPath,

/// Track the files added to the Run step for --watch
file_input_range: ?FileInputRange,

const FileInputRange = struct {
    start_value: []const u8,
    len: u32,
};

pub fn create(owner: *Build, run: *Run, dir: LazyPath) void {
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
        .file_input_range = null,
    };
    // Run step relies on DirectoryFileInput finishing
    run.step.dependOn(&self.step);
    // If dir is generated then this will wait for that dir to generate
    dir.addStepDependencies(&self.step);
}

fn make(step: *Step, options: Build.Step.MakeOptions) !void {
    const b = step.owner;
    const gpa = options.gpa;
    const arena = b.allocator;
    const self: *DirectoryFileInput = @fieldParentPtr("step", step);
    const run = self.run;

    // Add the directory to --watch input so that if any files are updated or changed
    // this step will re-trigger
    const need_derived_inputs = try step.addDirectoryWatchInput(self.dir);

    // triggers on --watch if a file is modified.
    if (self.file_input_range) |file_input_range| {
        const start_index: usize = blk: {
            for (run.file_inputs.items, 0..) |lp, file_input_index| {
                switch (lp) {
                    .cwd_relative => |cwd_relative| {
                        if (mem.eql(u8, file_input_range.start_value, cwd_relative)) {
                            break :blk file_input_index;
                        }
                    },
                    else => continue,
                }
            }
            return error.MissingFileInputWatchArgument;
        };
        try run.file_inputs.replaceRange(run.step.owner.allocator, start_index, file_input_range.len, &.{});
    }

    const dir_path = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
        self.dir.getPath3(b, step)
    else
        try self.dir.getPath4(b, step);

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

    var optional_file_input_value: ?[]const u8 = null;
    var optional_file_input_start_index: ?usize = null;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
        try walker.next()
    else
        try walker.next(b.graph.io)) |entry|
    {
        switch (entry.kind) {
            .directory => {
                if (need_derived_inputs) {
                    const entry_path = try dir_path.join(arena, entry.path);
                    try step.addDirectoryWatchInputFromPath(entry_path);
                }
            },
            .file => {
                // Add file as dependency to run command
                const file_path = try dir_path.root_dir.join(gpa, &.{ dir_path.sub_path, entry.path });
                if (optional_file_input_value == null) {
                    // Set index and value of first file
                    optional_file_input_start_index = run.file_inputs.items.len;
                    optional_file_input_value = file_path;
                }
                run.addFileInput(LazyPath{
                    .cwd_relative = file_path,
                });
            },
            else => continue,
        }
    }
    if (optional_file_input_value) |file_input_value| {
        const file_input_start_index = optional_file_input_start_index orelse unreachable;
        self.file_input_range = .{
            .start_value = file_input_value,
            .len = @intCast(run.file_inputs.items.len - file_input_start_index),
        };
    }
}

const DirectoryFileInput = @This();
