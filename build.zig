const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- Foundation libraries (vendored — no third-party deps) ----
    const sysclock_mod = b.addModule("sysclock", .{
        .root_source_file = b.path("lib/sysclock/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    sysclock_mod.link_libc = true;

    const sse_mod = b.addModule("sse", .{
        .root_source_file = b.path("lib/sse/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Date/time library (rockorager/zeit). RFC 3339, ISO 8601, full TZ support.
    const zeit_dep = b.dependency("zeit", .{ .target = target, .optimize = optimize });
    const zeit_mod = zeit_dep.module("zeit");

    // Protobuf codec + codegen (Arwalk/zig-protobuf).
    const protobuf_dep = b.dependency("protobuf", .{ .target = target, .optimize = optimize });
    const protobuf_mod = protobuf_dep.module("protobuf");

    // HTTP/1.1 server (karlseguin/http.zig).
    const httpz_dep = b.dependency("httpz", .{ .target = target, .optimize = optimize });
    const httpz_mod = httpz_dep.module("httpz");

    // TLS 1.3 server (ianic/tls.zig).
    const tls_dep = b.dependency("tls", .{ .target = target, .optimize = optimize });
    const tls_mod = tls_dep.module("tls");

    // `zig build gen-proto` regenerates src/pb/gen/ from proto/a2a.proto.
    // Generated files are checked in and treated as source; this step is only
    // run when the .proto schema changes.
    const gen_proto_step = b.step("gen-proto", "Regenerate protobuf bindings from proto/");
    const protoc_step = @import("protobuf").RunProtocStep.create(protobuf_dep.builder, target, .{
        .destination_directory = b.path("src/pb/gen"),
        .source_files = &.{b.path("proto/a2a.proto")},
        .include_directories = &.{b.path("proto")},
    });
    gen_proto_step.dependOn(&protoc_step.step);

    // Upstream UUID library (alexrios/uuid). Used directly — no wrapper.
    const uuid_dep = b.dependency("uuid", .{ .target = target, .optimize = optimize });
    const uuid_mod = uuid_dep.module("uuid");

    // Linter (rockorager/ziglint). Run via `zig build lint`.
    // Upstream pins Zig 0.15.2 in its own build.zig and won't compile under
    // 0.16, so we shell out to a `ziglint` on PATH instead of consuming it as
    // a build-graph dependency. Install with:
    //   zig build install -- (in a clone of rockorager/ziglint, on a 0.15.2)
    // or `nix run github:rockorager/ziglint -- <args>`.
    const lint_run = b.addSystemCommand(&.{"ziglint"});
    if (b.args) |args| lint_run.addArgs(args);
    const lint_step = b.step("lint", "Run ziglint over the project (requires `ziglint` on PATH)");
    lint_step.dependOn(&lint_run.step);

    // ---- Modules ----
    const a2a_mod = b.addModule("a2a", .{
        .root_source_file = b.path("src/a2a/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    a2a_mod.addImport("uuid", uuid_mod);
    a2a_mod.addImport("sysclock", sysclock_mod);
    a2a_mod.addImport("zeit", zeit_mod);

    const pb_mod = b.addModule("pb", .{
        .root_source_file = b.path("src/pb/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    pb_mod.addImport("protobuf", protobuf_mod);
    pb_mod.addImport("a2a", a2a_mod);

    const client_mod = b.addModule("a2a_client", .{
        .root_source_file = b.path("src/client/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_mod.addImport("a2a", a2a_mod);

    const server_mod = b.addModule("a2a_server", .{
        .root_source_file = b.path("src/server/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_mod.addImport("a2a", a2a_mod);
    server_mod.addImport("pb", pb_mod);
    server_mod.addImport("sse", sse_mod);
    server_mod.addImport("httpz", httpz_mod);
    server_mod.addImport("tls", tls_mod);

    client_mod.addImport("pb", pb_mod);
    client_mod.addImport("sse", sse_mod);

    // ---- CLI executable ----
    const cli_exe = b.addExecutable(.{
        .name = "a2a",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "a2a", .module = a2a_mod },
                .{ .name = "a2a_client", .module = client_mod },
                .{ .name = "a2a_server", .module = server_mod },
            },
        }),
    });
    b.installArtifact(cli_exe);

    const run_cli = b.addRunArtifact(cli_exe);
    if (b.args) |args| run_cli.addArgs(args);
    const run_step = b.step("run", "Run the CLI");
    run_step.dependOn(&run_cli.step);

    // ---- Hello-world example ----
    const hello_exe = b.addExecutable(.{
        .name = "helloworld",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/helloworld/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "a2a", .module = a2a_mod },
                .{ .name = "a2a_client", .module = client_mod },
                .{ .name = "a2a_server", .module = server_mod },
            },
        }),
    });
    b.installArtifact(hello_exe);

    // ---- Tests ----
    const test_step = b.step("test", "Run all unit tests");

    const sysclock_tests = b.addTest(.{ .root_module = sysclock_mod });
    test_step.dependOn(&b.addRunArtifact(sysclock_tests).step);

    const sse_tests = b.addTest(.{ .root_module = sse_mod });
    test_step.dependOn(&b.addRunArtifact(sse_tests).step);

    const pb_tests = b.addTest(.{ .root_module = pb_mod });
    test_step.dependOn(&b.addRunArtifact(pb_tests).step);


    const a2a_tests = b.addTest(.{ .root_module = a2a_mod });
    test_step.dependOn(&b.addRunArtifact(a2a_tests).step);

    const client_tests = b.addTest(.{ .root_module = client_mod });
    test_step.dependOn(&b.addRunArtifact(client_tests).step);

    const server_tests = b.addTest(.{ .root_module = server_mod });
    test_step.dependOn(&b.addRunArtifact(server_tests).step);
}
