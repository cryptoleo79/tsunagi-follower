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

    const test_step = b.step("test", "Run TSUNAGI Node tests");

    const protocol_tests = b.addTest(.{
        .root_source_file = b.path("src/protocol_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(protocol_tests).step);

    const byte_tests = b.addTest(.{
        .root_source_file = b.path("src/byte_transport_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(byte_tests).step);

    const framing_tests = b.addTest(.{
        .root_source_file = b.path("src/framing_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(framing_tests).step);
}
