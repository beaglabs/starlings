const std = @import("std");
const pack_loader = @import("pack/loader.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len == 4 and
        std.mem.eql(u8, args[1], "pack") and
        std.mem.eql(u8, args[2], "validate"))
    {
        const compiled = pack_loader.loadAndCompile(
            io,
            init.gpa,
            init.arena.allocator(),
            args[3],
        ) catch |err| {
            try writeLine(
                io,
                std.Io.File.stderr(),
                "pack validation failed: {t}\n",
                .{err},
            );
            std.process.exit(2);
        };

        try writeLine(
            io,
            std.Io.File.stdout(),
            "VALID {s}@{s} variables={d} invariants={d} operators={d} targets={d}\n",
            .{
                compiled.name,
                compiled.version,
                compiled.variable_count,
                compiled.invariant_count,
                compiled.operator_count,
                compiled.target_count,
            },
        );
        return;
    }

    if (args.len == 4 and
        std.mem.eql(u8, args[1], "pack") and
        std.mem.eql(u8, args[2], "inspect"))
    {
        const compiled = pack_loader.loadAndCompile(
            io,
            init.gpa,
            init.arena.allocator(),
            args[3],
        ) catch |err| {
            try writeLine(
                io,
                std.Io.File.stderr(),
                "pack inspection failed: {t}\n",
                .{err},
            );
            std.process.exit(2);
        };

        try inspect(io, &compiled);
        return;
    }

    try std.Io.File.stderr().writeStreamingAll(
        io,
        "usage:\n" ++
            "  starlings pack validate <pack-dir>\n" ++
            "  starlings pack inspect <pack-dir>\n",
    );
    std.process.exit(2);
}

fn inspect(io: std.Io, compiled: anytype) !void {
    const out = std.Io.File.stdout();

    try writeLine(io, out, "Pack: {s} {s}\n\n", .{ compiled.name, compiled.version });
    try writeLine(io, out, "Variables:  {d}\n", .{compiled.variable_count});
    try writeLine(io, out, "Invariants: {d}\n", .{compiled.invariant_count});
    try writeLine(io, out, "Operators:  {d}\n", .{compiled.operator_count});
    try writeLine(io, out, "Targets:    {d}\n\n", .{compiled.target_count});

    try writeLine(io, out, "VARIABLES\n", .{});
    for (compiled.variables[0..compiled.variable_count]) |schema| {
        try writeLine(
            io,
            out,
            "  {s}  type={s} merge={s} id=0x{x}\n",
            .{
                schema.variable.name,
                @tagName(schema.variable.kind),
                @tagName(schema.variable.merge_policy),
                schema.variable.id,
            },
        );
    }

    try writeLine(io, out, "\nINVARIANTS\n", .{});
    for (compiled.invariants[0..compiled.invariant_count]) |invariant| {
        try writeLine(
            io,
            out,
            "  {s}  requires={d} id=0x{x}\n",
            .{ invariant.name, invariant.require_count, invariant.id },
        );
    }

    try writeLine(io, out, "\nOPERATORS\n", .{});
    for (compiled.operators[0..compiled.operator_count]) |operator| {
        try writeLine(
            io,
            out,
            "  {s}  runtime={s} requires={d}+{d} provides={d}+{d} id=0x{x}\n",
            .{
                operator.name,
                @tagName(operator.runtime.kind),
                operator.requires_variable_count,
                operator.requires_invariant_count,
                operator.provides_variable_count,
                operator.provides_invariant_count,
                operator.id,
            },
        );
    }

    try writeLine(io, out, "\nTARGETS\n", .{});
    for (compiled.targets[0..compiled.target_count]) |target_id| {
        var target_name: []const u8 = "<unknown>";
        for (compiled.variables[0..compiled.variable_count]) |schema| {
            if (schema.variable.id == target_id) {
                target_name = schema.variable.name;
                break;
            }
        }
        try writeLine(io, out, "  {s}  id=0x{x}\n", .{ target_name, target_id });
    }
}

fn writeLine(
    io: std.Io,
    out: std.Io.File,
    comptime format: []const u8,
    args: anytype,
) !void {
    var buffer: [4096]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, format, args);
    try out.writeStreamingAll(io, line);
}
