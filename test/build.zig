const Build = @import("std").Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const all_step = b.step("all", "Run all tests");
    b.default_step = all_step;

    for (b.available_deps) |available_dep| {
        const test_name, _ = available_dep;
        const run_example = b.dependency(test_name, .{
            .target = target,
            .optimize = optimize,
            .android = true,
        }).builder.default_step;
        const example_step = b.step(test_name, b.fmt("Run the '{s}' test", .{test_name}));
        example_step.dependOn(run_example);
        all_step.dependOn(example_step);
    }
}
