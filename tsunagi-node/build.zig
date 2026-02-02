const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "tsunagi-node",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    // ---- TSUNAGI: tests ----
    const test_step = b.step("test", "Run TSUNAGI Node tests");

    const protocol_tests = b.addTest(.{
        .root_source_file = b.path("src/protocol_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_protocol = b.addRunArtifact(protocol_tests);
    test_step.dependOn(&run_protocol.step);

    const byte_tests = b.addTest(.{
        .root_source_file = b.path("src/byte_transport_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_bytes = b.addRunArtifact(byte_tests);
    test_step.dependOn(&run_bytes.step);
}
