const std = @import("std");

const pkg_name = "smallarray";
const pkg_path = "../src/lib.zig";

const examples = .{
    "smallarray",
    // "arraylist",
    "arraylist-arena",
    "arraylist-arena-with-cap",
    "arraylist-fixed-buffer",
    "boundedarray",
};

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    // const optimize = b.standardOptimizeOption(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    inline for (examples) |e| {
        const example_path = e ++ "/main.zig";
        const exe_name = "bench-" ++ e;
        const run_name = "bench-" ++ e;
        const run_desc = "Run the " ++ e ++ " bench";

        const exe = b.addExecutable(.{
            .name = exe_name,
            .root_source_file = .{ .path = example_path },
            .target = target,
            .optimize = optimize,
        });
        const mod = b.addModule("smallarray", .{
            .source_file = .{ .path = "../src/lib.zig" },
        });
        exe.addModule("smallarray", mod);

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);

        run_cmd.step.dependOn(b.getInstallStep());
        const run_step = b.step(run_name, run_desc);
        run_step.dependOn(&run_cmd.step);
    }
}
