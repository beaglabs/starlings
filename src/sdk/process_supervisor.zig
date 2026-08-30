const std = @import("std");
const builtin = @import("builtin");
const external = @import("external.zig");

const Io = std.Io;

pub const Supervisor = struct {
    io: Io,
    allocator: std.mem.Allocator,
    max_stdout_bytes: usize = 256 * 1024,
    max_stderr_bytes: usize = 64 * 1024,
    last_stderr: []u8 = &.{},

    pub fn deinit(self: *Supervisor) void {
        if (self.last_stderr.len != 0) self.allocator.free(self.last_stderr);
        self.last_stderr = &.{};
    }

    pub fn transport(self: *Supervisor) external.Transport {
        return .{
            .context = self,
            .invoke_fn = invokeTransport,
        };
    }

    pub fn stderr(self: *const Supervisor) []const u8 {
        return self.last_stderr;
    }

    fn clearStderr(self: *Supervisor) void {
        if (self.last_stderr.len != 0) self.allocator.free(self.last_stderr);
        self.last_stderr = &.{};
    }

    fn invokeTransport(
        context: ?*anyopaque,
        invocation: external.Invocation,
        request: []const u8,
        response_buffer: []u8,
    ) anyerror![]const u8 {
        const raw_context = context orelse return error.MissingProcessSupervisorContext;
        const self: *Supervisor = @ptrCast(@alignCast(raw_context));
        return self.invoke(invocation, request, response_buffer);
    }

    pub fn invoke(
        self: *Supervisor,
        invocation: external.Invocation,
        request: []const u8,
        response_buffer: []u8,
    ) ![]const u8 {
        self.clearStderr();

        var python_argv: [4][]const u8 = undefined;
        const argv = switch (invocation) {
            .subprocess => |adapter| blk: {
                if (adapter.argv.len == 0) return error.InvalidExternalInvocation;
                break :blk adapter.argv;
            },
            .python => |adapter| adapter.command(&python_argv),
        };

        if (invocation.timeoutMs() == 0) return error.InvalidExternalTimeout;

        var child = std.process.spawn(self.io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch return error.OperatorSpawnFailed;
        var child_active = true;
        errdefer if (child_active) child.kill(self.io);

        {
            var write_buffer: [4096]u8 = undefined;
            var file_writer = child.stdin.?.writer(self.io, &write_buffer);
            file_writer.interface.writeAll(request) catch return error.OperatorCrashed;
            file_writer.interface.flush() catch return error.OperatorCrashed;
            child.stdin.?.close(self.io);
            child.stdin = null;
        }

        var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: Io.File.MultiReader = undefined;
        multi_reader.init(
            self.allocator,
            self.io,
            multi_reader_buffer.toStreams(),
            &.{ child.stdout.?, child.stderr.? },
        );
        defer multi_reader.deinit();

        const stdout_reader = multi_reader.reader(0);
        const stderr_reader = multi_reader.reader(1);

        const timeout_duration: Io.Clock.Duration = .{
            .clock = .awake,
            .raw = .fromMilliseconds(@intCast(invocation.timeoutMs())),
        };
        const deadline = Io.Clock.Timestamp.fromNow(
            self.io,
            timeout_duration,
        ) catch return error.ExternalTimeoutUnavailable;

        while (true) {
            if (stdout_reader.buffered().len > self.max_stdout_bytes) {
                child.kill(self.io);
                child_active = false;
                return error.OperatorStdoutTooLarge;
            }
            if (stderr_reader.buffered().len > self.max_stderr_bytes) {
                child.kill(self.io);
                child_active = false;
                return error.OperatorStderrTooLarge;
            }

            multi_reader.fill(4096, .{ .deadline = deadline }) catch |err| switch (err) {
                error.Timeout => {
                    child.kill(self.io);
                    child_active = false;
                    return error.OperatorTimeout;
                },
                error.EndOfStream => break,
                else => return err,
            };
        }

        if (stdout_reader.buffered().len > self.max_stdout_bytes) {
            child.kill(self.io);
            child_active = false;
            return error.OperatorStdoutTooLarge;
        }
        if (stderr_reader.buffered().len > self.max_stderr_bytes) {
            child.kill(self.io);
            child_active = false;
            return error.OperatorStderrTooLarge;
        }

        if (stderr_reader.buffered().len != 0) {
            self.last_stderr = try self.allocator.dupe(u8, stderr_reader.buffered());
        }

        const stdout = stdout_reader.buffered();

        const term = try child.wait(self.io);
        child_active = false;
        switch (term) {
            .exited => |code| if (code != 0) return error.OperatorCrashed,
            .signal, .stopped, .unknown => return error.OperatorCrashed,
        }

        if (stdout.len > response_buffer.len) return error.WireBufferTooSmall;
        @memcpy(response_buffer[0..stdout.len], stdout);
        return response_buffer[0..stdout.len];
    }
};

test "real subprocess transport captures a bounded response" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var supervisor = Supervisor{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
    };
    defer supervisor.deinit();

    const transport = supervisor.transport();
    const invocation: external.Invocation = .{ .subprocess = .{
        .argv = &.{ "/bin/sh", "-c", "cat" },
        .timeout_ms = 1000,
    } };

    const request = "supervised external operator\n";
    var response_buffer: [128]u8 = undefined;
    const response = try transport.invoke(invocation, request, &response_buffer);
    try std.testing.expectEqualStrings(request, response);
}

test "real subprocess transport classifies nonzero exit as crash" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var supervisor = Supervisor{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
    };
    defer supervisor.deinit();

    const transport = supervisor.transport();
    const invocation: external.Invocation = .{ .subprocess = .{
        .argv = &.{ "/bin/sh", "-c", "cat >/dev/null; exit 7" },
        .timeout_ms = 1000,
    } };

    var response_buffer: [64]u8 = undefined;
    try std.testing.expectError(
        error.OperatorCrashed,
        transport.invoke(invocation, "request\n", &response_buffer),
    );
}

test "real subprocess transport enforces timeout" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var supervisor = Supervisor{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
    };
    defer supervisor.deinit();

    const transport = supervisor.transport();
    const invocation: external.Invocation = .{ .subprocess = .{
        .argv = &.{ "/bin/sh", "-c", "cat >/dev/null; sleep 1" },
        .timeout_ms = 20,
    } };

    var response_buffer: [64]u8 = undefined;
    try std.testing.expectError(
        error.OperatorTimeout,
        transport.invoke(invocation, "request\n", &response_buffer),
    );
}

test "real subprocess transport powers canonical external operator parsing" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var supervisor = Supervisor{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
    };
    defer supervisor.deinit();

    const operator = external.ExternalOperator{
        .invocation = .{ .subprocess = .{
            .argv = &.{
                "/bin/sh",
                "-c",
                "cat >/dev/null; printf '%s\\n' 'STARLINGS/1 RESPONSE' 'operator=7' 'claim=2,3,1000,7,b:1' 'END'",
            },
            .timeout_ms = 1000,
        } },
        .transport = supervisor.transport(),
    };

    var response_buffer: [256]u8 = undefined;
    const output = try operator.invoke("STARLINGS/1 REQUEST\noperator=7\nround=1\nEND\n", &response_buffer);
    try std.testing.expectEqual(@as(usize, 1), output.variable_claim_count);
    try std.testing.expect(output.variable_claims[0].value.?.boolean);
}
