const Build = @import("std").Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const all_step = b.step("all", "Run all tests");
    b.default_step = all_step;

    for (b.available_deps) |available_dep| {
        const test_name, _ = available_dep;
        const test_case_dep_step = b.dependency(test_name, .{
            .target = target,
            .optimize = optimize,
            .android = true,
        }).builder.default_step;
        const test_step = b.step(test_name, b.fmt("Run the '{s}' test", .{test_name}));
        test_step.dependOn(test_case_dep_step);
        all_step.dependOn(test_step);
    }
}
