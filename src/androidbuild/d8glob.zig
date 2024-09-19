const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const Step = Build.Step;
const Run = Build.Step.Run;
const LazyPath = Build.LazyPath;
const fs = std.fs;
const mem = std.mem;
const assert = std.debug.assert;

/// D8Glob is specific for D8 and is used to collect all *.class output files after a javac process generates them
pub const D8Glob = struct {
    pub const base_id: Step.Id = .custom;

    step: Step,

    /// Runner to update
    run: *Build.Step.Run,

    /// The directory that will contain the files to glob
    dir: LazyPath,

    const file_ext = ".class";

    pub fn addClassFilesRecursively(owner: *std.Build, run: *Run, dir: LazyPath) void {
        const glob = owner.allocator.create(@This()) catch @panic("OOM");
        glob.* = .{
            .step = Step.init(.{
                .id = base_id,
                .name = "zig-android-sdk d8glob",
                .owner = owner,
                .makeFn = comptime if (std.mem.eql(u8, builtin.zig_version_string, "0.13.0"))
                    make013
                else
                    makeLatest,
            }),
            .run = run,
            .dir = dir,
        };
        // Run step relies on this finishing
        run.step.dependOn(&glob.step);
        // If dir is generated then this will wait for that dir to generate
        dir.addStepDependencies(&glob.step);
    }

    /// make for zig 0.13.0
    fn make013(step: *Step, prog_node: std.Progress.Node) !void {
        _ = prog_node; // autofix
        try make(step);
    }

    /// make for zig 0.14.0+
    fn makeLatest(step: *Step, options: Build.Step.MakeOptions) !void {
        _ = options; // autofix
        try make(step);
    }

    // TODO(jae): 2024-09-03
    // Look into seeing if we can cache this to avoid directory walking after first time.
    //
    // This step does not cache very well and requires recursively walking the directory each time
    // I could probably use the hash of given generated dir and read an existing file that lists
    // each file for quick lookup? Dunno.
    fn make(step: *Step) !void {
        const b = step.owner;
        const arena = b.allocator;
        const glob: *@This() = @fieldParentPtr("step", step);
        const d8 = glob.run;

        const search_dir = glob.dir.getPath2(b, step);

        // Add --classpath
        d8.addArg("--classpath");
        d8.addDirectoryArg(glob.dir);

        var dir = try fs.openDirAbsolute(search_dir, .{ .iterate = true });
        defer dir.close();
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) {
                continue;
            }
            // Exclude special classes?
            // - !std.mem.containsAtLeast(u8, entry.basename, 1, "$") and
            // - !std.mem.containsAtLeast(u8, entry.basename, 1, "_API")
            if (std.mem.endsWith(u8, entry.path, file_ext)) {
                d8.addFileArg(LazyPath{
                    .cwd_relative = try fs.path.resolve(arena, &.{ search_dir, entry.path }),
                });
            }
        }
    }
};
