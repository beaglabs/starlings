const std = @import("std");
const content_id = @import("../core/content_id.zig");
const core = @import("core_types.zig");
const output_state = @import("output_state.zig");

pub const artifact_storage_version: u8 = 1;
pub const artifacts_dir_name = "artifacts";
pub const artifact_file_suffix = ".artifact";
pub const max_media_type_bytes: usize = 4 * 1024;
pub const max_artifact_bytes: usize = 64 * 1024 * 1024;
pub const max_artifact_file_bytes: usize =
    8 + 1 + 4 + 8 + max_media_type_bytes + max_artifact_bytes;

const artifact_magic = "STARTF01";

pub const Verifier = struct {
    context: ?*anyopaque = null,
    verify_fn: *const fn (?*anyopaque, core.ArtifactRef) anyerror!void,

    pub fn verify(self: Verifier, artifact: core.ArtifactRef) !void {
        return self.verify_fn(self.context, artifact);
    }
};

pub const LoadedArtifact = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    ref: core.ArtifactRef,
    bytes: []const u8,

    pub fn deinit(self: *LoadedArtifact) void {
        self.allocator.free(self.storage);
    }
};

pub const Store = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,

    pub fn create(
        io: std.Io,
        allocator: std.mem.Allocator,
        run_dir: std.Io.Dir,
    ) !Store {
        try run_dir.createDir(io, artifacts_dir_name, .default_dir);
        return open(io, allocator, run_dir);
    }

    pub fn open(
        io: std.Io,
        allocator: std.mem.Allocator,
        run_dir: std.Io.Dir,
    ) !Store {
        return .{
            .io = io,
            .allocator = allocator,
            .dir = try run_dir.openDir(io, artifacts_dir_name, .{}),
        };
    }

    pub fn deinit(self: *Store) void {
        self.dir.close(self.io);
    }

    pub fn verifier(self: *Store) Verifier {
        return .{
            .context = self,
            .verify_fn = verifyFromInterface,
        };
    }

    pub fn put(
        self: *Store,
        media_type: []const u8,
        bytes: []const u8,
    ) !core.ArtifactRef {
        if (media_type.len == 0) return error.InvalidArtifactMediaType;
        if (media_type.len > max_media_type_bytes) return error.ArtifactMediaTypeTooLarge;
        if (bytes.len > max_artifact_bytes) return error.ArtifactTooLarge;

        const artifact = output_state.artifactRef(media_type, bytes);
        var name_buffer: [64 + artifact_file_suffix.len]u8 = undefined;
        const name = formatArtifactName(artifact.id, &name_buffer);

        var file = self.dir.createFile(self.io, name, .{
            .exclusive = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                try self.verify(artifact);
                return artifact;
            },
            else => return err,
        };
        defer file.close(self.io);

        var header: [8 + 1 + 4 + 8]u8 = undefined;
        @memcpy(header[0..artifact_magic.len], artifact_magic);
        header[8] = artifact_storage_version;
        encodeU32(@intCast(media_type.len), header[9..13]);
        encodeU64(@intCast(bytes.len), header[13..21]);

        try file.writeStreamingAll(self.io, &header);
        try file.writeStreamingAll(self.io, media_type);
        try file.writeStreamingAll(self.io, bytes);
        try file.sync(self.io);

        return artifact;
    }

    pub fn verify(self: *Store, artifact: core.ArtifactRef) !void {
        var loaded = try self.load(artifact.id);
        defer loaded.deinit();

        if (!std.mem.eql(u8, loaded.ref.media_type, artifact.media_type)) {
            return error.ArtifactMediaTypeMismatch;
        }
        if (loaded.ref.size_bytes != artifact.size_bytes) {
            return error.ArtifactSizeMismatch;
        }
        if (!content_id.eql(loaded.ref.id, artifact.id)) {
            return error.ArtifactIdMismatch;
        }
    }

    pub fn load(self: *Store, id: core.ContentId) !LoadedArtifact {
        var name_buffer: [64 + artifact_file_suffix.len]u8 = undefined;
        const name = formatArtifactName(id, &name_buffer);

        const storage = try self.dir.readFileAlloc(
            self.io,
            name,
            self.allocator,
            .limited(max_artifact_file_bytes),
        );
        errdefer self.allocator.free(storage);

        if (storage.len < 21) return error.TruncatedArtifact;
        if (!std.mem.eql(u8, storage[0..8], artifact_magic)) {
            return error.InvalidArtifactFile;
        }
        if (storage[8] != artifact_storage_version) {
            return error.UnsupportedArtifactStorageVersion;
        }

        const media_type_len: usize = @intCast(decodeU32(storage[9..13]));
        const size_bytes_u64 = decodeU64(storage[13..21]);
        if (media_type_len == 0 or media_type_len > max_media_type_bytes) {
            return error.InvalidArtifactMediaType;
        }
        if (size_bytes_u64 > @as(u64, max_artifact_bytes)) return error.ArtifactTooLarge;
        const size_bytes: usize = @intCast(size_bytes_u64);

        const payload_start = 21 + media_type_len;
        if (payload_start > storage.len) return error.TruncatedArtifact;
        if (size_bytes != storage.len - payload_start) return error.ArtifactSizeMismatch;

        const media_type = storage[21..payload_start];
        const bytes = storage[payload_start..];
        const actual_id = output_state.artifactContentId(media_type, bytes);
        if (!content_id.eql(actual_id, id)) return error.ArtifactIdMismatch;

        return .{
            .allocator = self.allocator,
            .storage = storage,
            .ref = .{
                .id = actual_id,
                .media_type = media_type,
                .size_bytes = size_bytes_u64,
            },
            .bytes = bytes,
        };
    }

    fn verifyFromInterface(
        context: ?*anyopaque,
        artifact: core.ArtifactRef,
    ) anyerror!void {
        const raw_context = context orelse return error.MissingArtifactStoreContext;
        const self: *Store = @ptrCast(@alignCast(raw_context));
        try self.verify(artifact);
    }
};

pub fn formatArtifactName(
    id: core.ContentId,
    out: *[64 + artifact_file_suffix.len]u8,
) []const u8 {
    encodeHex(&id, out[0..64]);
    @memcpy(out[64..], artifact_file_suffix);
    return out;
}

fn encodeHex(input: []const u8, output: []u8) void {
    const alphabet = "0123456789abcdef";
    std.debug.assert(output.len == input.len * 2);
    for (input, 0..) |byte, i| {
        output[i * 2] = alphabet[byte >> 4];
        output[i * 2 + 1] = alphabet[byte & 0x0f];
    }
}

fn encodeU32(value: u32, out: []u8) void {
    std.debug.assert(out.len == 4);
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const shift: u5 = @intCast(i * 8);
        out[i] = @truncate(value >> shift);
    }
}

fn encodeU64(value: u64, out: []u8) void {
    std.debug.assert(out.len == 8);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const shift: u6 = @intCast(i * 8);
        out[i] = @truncate(value >> shift);
    }
}

fn decodeU32(bytes: []const u8) u32 {
    std.debug.assert(bytes.len == 4);
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn decodeU64(bytes: []const u8) u64 {
    std.debug.assert(bytes.len == 8);
    var value: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const shift: u6 = @intCast(i * 8);
        value |= @as(u64, bytes[i]) << shift;
    }
    return value;
}

test "artifact store persists verifies loads and deduplicates bytes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.create(io, std.testing.allocator, tmp.dir);
    defer store.deinit();

    const first = try store.put("application/json", "{\"answer\":42}");
    const duplicate = try store.put("application/json", "{\"answer\":42}");
    try std.testing.expect(content_id.eql(first.id, duplicate.id));

    try store.verify(first);

    var loaded = try store.load(first.id);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("application/json", loaded.ref.media_type);
    try std.testing.expectEqualStrings("{\"answer\":42}", loaded.bytes);
    try std.testing.expectEqual(@as(u64, 13), loaded.ref.size_bytes);
}

test "artifact verifier rejects a mismatched reference" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.create(io, std.testing.allocator, tmp.dir);
    defer store.deinit();

    var artifact = try store.put("text/plain", "hello");
    artifact.size_bytes += 1;

    try std.testing.expectError(
        error.ArtifactSizeMismatch,
        store.verifier().verify(artifact),
    );
}
