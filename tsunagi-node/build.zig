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

    // `zig build run -- [args...]`
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run TSUNAGI Node");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` runs all test roots.
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

    const mux_framing_tests = b.addTest(.{
        .root_source_file = b.path("src/mux_framing_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(mux_framing_tests).step);

    const handshake_codec_tests = b.addTest(.{
        .root_source_file = b.path("src/handshake_codec_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(handshake_codec_tests).step);

    const muxwire_tests = b.addTest(.{
        .root_source_file = b.path("src/muxwire_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(muxwire_tests).step);
}
