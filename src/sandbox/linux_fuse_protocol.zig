const std = @import("std");
pub const uapi = @import("linux_fuse_uapi.zig");

pub const DecodeError = error{
    TruncatedHeader,
    InvalidLength,
    FrameTooLarge,
    TruncatedFrame,
    TrailingBytes,
    BodyTooShort,
    MissingNul,
    EmptyName,
    InvalidName,
    TrailingNameData,
};

pub const EncodeError = error{
    NoSpace,
    InvalidErrno,
    EmptyName,
    NameTooLong,
    InvalidName,
    LengthOverflow,
};

pub const Request = struct {
    header: uapi.InHeader,
    opcode: ?uapi.Opcode,
    body: []const u8,

    pub fn bodyAs(self: Request, comptime T: type) DecodeError!T {
        comptime assertWireValue(T);
        if (self.body.len < @sizeOf(T)) return error.BodyTooShort;
        return decodeNative(T, self.body[0..@sizeOf(T)]);
    }
};

pub const hard_max_frame_len: usize = 16 * 1024 * 1024;

pub fn decodeRequest(frame: []const u8, max_frame_len: usize) DecodeError!Request {
    if (frame.len < @sizeOf(uapi.InHeader)) return error.TruncatedHeader;

    const header = decodeNative(uapi.InHeader, frame[0..@sizeOf(uapi.InHeader)]);
    const declared_len: usize = header.len;
    if (declared_len < @sizeOf(uapi.InHeader)) return error.InvalidLength;

    const effective_max = @min(max_frame_len, hard_max_frame_len);
    if (declared_len > effective_max) return error.FrameTooLarge;
    if (declared_len > frame.len) return error.TruncatedFrame;
    if (declared_len < frame.len) return error.TrailingBytes;

    return .{
        .header = header,
        .opcode = std.enums.fromInt(uapi.Opcode, header.opcode),
        .body = frame[@sizeOf(uapi.InHeader)..declared_len],
    };
}

pub fn singleName(body: []const u8, fixed_prefix_len: usize) DecodeError![]const u8 {
    const field = try nulTerminated(body, fixed_prefix_len);
    if (field.next_offset != body.len) return error.TrailingNameData;
    try validateName(field.value);
    return field.value;
}

pub const NamePair = struct {
    first: []const u8,
    second: []const u8,
};

pub fn twoNames(body: []const u8, fixed_prefix_len: usize) DecodeError!NamePair {
    const first = try nulTerminated(body, fixed_prefix_len);
    try validateName(first.value);
    const second = try nulTerminated(body, first.next_offset);
    try validateName(second.value);
    if (second.next_offset != body.len) return error.TrailingNameData;
    return .{
        .first = first.value,
        .second = second.value,
    };
}

pub const NulField = struct {
    value: []const u8,
    next_offset: usize,
};

pub fn nulTerminated(body: []const u8, offset: usize) DecodeError!NulField {
    if (offset > body.len) return error.BodyTooShort;
    const tail = body[offset..];
    const relative_end = std.mem.indexOfScalar(u8, tail, 0) orelse return error.MissingNul;
    return .{
        .value = tail[0..relative_end],
        .next_offset = offset + relative_end + 1,
    };
}

fn validateName(name: []const u8) DecodeError!void {
    if (name.len == 0) return error.EmptyName;
    if (name.len > uapi.max_name_len) return error.InvalidName;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidName;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidName;
}

pub const InitConfig = struct {
    max_readahead: u32 = 1024 * 1024,
    max_write: u32 = 1024 * 1024,
    max_background: u16 = 64,
    congestion_threshold: u16 = 48,
    max_pages: u16 = 256,
    time_gran: u32 = 1,
};

pub const InitNegotiation = union(enum) {
    retry_with_major: uapi.InitVersionOut,
    ready: uapi.InitOut,
};

pub const InitError = error{
    UnsupportedProtocol,
    InvalidConfig,
};

pub fn negotiateInit(input: uapi.InitIn, config: InitConfig) InitError!InitNegotiation {
    if (input.major > uapi.kernel_version) {
        return .{ .retry_with_major = .{
            .major = uapi.kernel_version,
            .minor = uapi.kernel_minor_version,
        } };
    }
    if (input.major < uapi.kernel_version or input.minor < uapi.kernel_minor_version) {
        return error.UnsupportedProtocol;
    }
    if (config.max_write == 0 or
        config.max_write > hard_max_frame_len - @sizeOf(uapi.InHeader) - @sizeOf(uapi.WriteIn) or
        config.time_gran == 0 or
        config.congestion_threshold > config.max_background)
    {
        return error.InvalidConfig;
    }

    const supported_flags = uapi.init_async_read |
        uapi.init_big_writes |
        uapi.init_auto_inval_data |
        uapi.init_max_pages;
    var flags = input.flags & supported_flags;
    if (config.max_pages == 0) flags &= ~uapi.init_max_pages;

    return .{ .ready = .{
        .major = uapi.kernel_version,
        .minor = @min(input.minor, uapi.kernel_minor_version),
        .max_readahead = @min(input.max_readahead, config.max_readahead),
        .flags = flags,
        .max_background = config.max_background,
        .congestion_threshold = config.congestion_threshold,
        .max_write = config.max_write,
        .time_gran = config.time_gran,
        .max_pages = if (flags & uapi.init_max_pages != 0) config.max_pages else 0,
        .map_alignment = 0,
        .unused = .{0} ** 8,
    } };
}

pub const ReplyWriter = struct {
    buffer: []u8,
    unique: u64,
    cursor: usize,

    pub fn init(buffer: []u8, unique: u64) EncodeError!ReplyWriter {
        if (buffer.len < @sizeOf(uapi.OutHeader)) return error.NoSpace;
        return .{
            .buffer = buffer,
            .unique = unique,
            .cursor = @sizeOf(uapi.OutHeader),
        };
    }

    pub fn appendValue(self: *ReplyWriter, value: anytype) EncodeError!void {
        const T = @TypeOf(value);
        comptime assertWireValue(T);
        const bytes = std.mem.asBytes(&value);
        try self.reserve(bytes.len);
        @memcpy(self.buffer[self.cursor .. self.cursor + bytes.len], bytes);
        self.cursor += bytes.len;
    }

    pub fn appendBytes(self: *ReplyWriter, bytes: []const u8) EncodeError!void {
        try self.reserve(bytes.len);
        @memcpy(self.buffer[self.cursor .. self.cursor + bytes.len], bytes);
        self.cursor += bytes.len;
    }

    pub fn appendDirent(
        self: *ReplyWriter,
        ino: u64,
        next_offset: u64,
        kind: u32,
        name: []const u8,
    ) EncodeError!void {
        try validateDirentName(name);
        const raw_len = std.math.add(usize, @sizeOf(uapi.Dirent), name.len) catch return error.LengthOverflow;
        const encoded_len = try align8(raw_len);
        try self.reserve(encoded_len);

        const output = self.buffer[self.cursor .. self.cursor + encoded_len];
        @memset(output, 0);
        encodeNative(uapi.Dirent, output[0..@sizeOf(uapi.Dirent)], .{
            .ino = ino,
            .off = next_offset,
            .namelen = @intCast(name.len),
            .kind = kind,
        });
        @memcpy(output[@sizeOf(uapi.Dirent) .. @sizeOf(uapi.Dirent) + name.len], name);
        self.cursor += encoded_len;
    }

    pub fn finish(self: *ReplyWriter) EncodeError![]const u8 {
        if (self.cursor > std.math.maxInt(u32)) return error.LengthOverflow;
        encodeNative(uapi.OutHeader, self.buffer[0..@sizeOf(uapi.OutHeader)], .{
            .len = @intCast(self.cursor),
            .err = 0,
            .unique = self.unique,
        });
        return self.buffer[0..self.cursor];
    }

    fn reserve(self: *const ReplyWriter, additional: usize) EncodeError!void {
        const remaining = self.buffer.len - self.cursor;
        if (additional > remaining) return error.NoSpace;
    }
};

pub fn encodeError(buffer: []u8, unique: u64, errno: u16) EncodeError![]const u8 {
    if (errno == 0 or errno > uapi.max_errno) return error.InvalidErrno;
    if (buffer.len < @sizeOf(uapi.OutHeader)) return error.NoSpace;

    encodeNative(uapi.OutHeader, buffer[0..@sizeOf(uapi.OutHeader)], .{
        .len = @sizeOf(uapi.OutHeader),
        .err = -@as(i32, errno),
        .unique = unique,
    });
    return buffer[0..@sizeOf(uapi.OutHeader)];
}

fn assertWireValue(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (info.layout != .@"extern") {
                @compileError("FUSE reply values must be extern structs");
            }
            comptime var fields_size: usize = 0;
            inline for (info.fields) |field| {
                assertWireField(field.type);
                fields_size += @sizeOf(field.type);
            }
            if (fields_size != @sizeOf(T)) {
                @compileError("FUSE wire structs must declare all ABI padding");
            }
        },
        else => @compileError("FUSE reply values must be extern structs"),
    }
}

fn assertWireField(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int => {},
        .array => |info| assertWireField(info.child),
        .@"struct" => assertWireValue(T),
        else => @compileError("FUSE wire structs may contain only integers, arrays, and extern structs"),
    }
}

fn validateDirentName(name: []const u8) EncodeError!void {
    if (name.len == 0) return error.EmptyName;
    if (name.len > uapi.max_name_len) return error.NameTooLong;
    if (std.mem.indexOfScalar(u8, name, 0) != null or
        std.mem.indexOfScalar(u8, name, '/') != null)
    {
        return error.InvalidName;
    }
}

fn align8(value: usize) EncodeError!usize {
    const with_padding = std.math.add(usize, value, 7) catch return error.LengthOverflow;
    return with_padding & ~@as(usize, 7);
}

fn decodeNative(comptime T: type, bytes: []const u8) T {
    std.debug.assert(bytes.len == @sizeOf(T));
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), bytes);
    return value;
}

fn encodeNative(comptime T: type, output: []u8, value: T) void {
    std.debug.assert(output.len == @sizeOf(T));
    @memcpy(output, std.mem.asBytes(&value));
}

fn appendRaw(comptime T: type, output: []u8, cursor: *usize, value: T) void {
    const bytes = std.mem.asBytes(&value);
    @memcpy(output[cursor.* .. cursor.* + bytes.len], bytes);
    cursor.* += bytes.len;
}

fn requestFrame(buffer: []u8, opcode: u32, unique: u64, body: []const u8) []const u8 {
    var cursor: usize = 0;
    appendRaw(uapi.InHeader, buffer, &cursor, .{
        .len = @intCast(@sizeOf(uapi.InHeader) + body.len),
        .opcode = opcode,
        .unique = unique,
        .nodeid = uapi.root_id,
        .uid = 501,
        .gid = 20,
        .pid = 42,
        .padding = 0,
    });
    @memcpy(buffer[cursor .. cursor + body.len], body);
    return buffer[0 .. cursor + body.len];
}

fn setFrameLength(frame: []u8, len: u32) void {
    var header = decodeNative(uapi.InHeader, frame[0..@sizeOf(uapi.InHeader)]);
    header.len = len;
    encodeNative(uapi.InHeader, frame[0..@sizeOf(uapi.InHeader)], header);
}

test "decode request preserves known and unknown opcodes without allocating" {
    var storage: [128]u8 = undefined;
    const frame = requestFrame(&storage, @intFromEnum(uapi.Opcode.lookup), 0x1234, "file.txt\x00");
    const request = try decodeRequest(frame, storage.len);

    try std.testing.expectEqual(uapi.Opcode.lookup, request.opcode.?);
    try std.testing.expectEqual(@as(u64, 0x1234), request.header.unique);
    try std.testing.expectEqualStrings("file.txt\x00", request.body);

    const unknown_frame = requestFrame(&storage, 0xdead, 9, "");
    const unknown = try decodeRequest(unknown_frame, storage.len);
    try std.testing.expectEqual(@as(?uapi.Opcode, null), unknown.opcode);
    try std.testing.expectEqual(@as(u32, 0xdead), unknown.header.opcode);
}

test "decode request rejects malformed truncated oversized and trailing frames" {
    var storage: [128]u8 = undefined;
    const frame = requestFrame(&storage, @intFromEnum(uapi.Opcode.getattr), 1, "\x00");

    try std.testing.expectError(
        error.TruncatedHeader,
        decodeRequest(frame[0 .. @sizeOf(uapi.InHeader) - 1], storage.len),
    );
    try std.testing.expectError(error.FrameTooLarge, decodeRequest(frame, frame.len - 1));

    var malformed = storage;
    setFrameLength(&malformed, @intCast(frame.len + 1));
    try std.testing.expectError(error.TruncatedFrame, decodeRequest(malformed[0..frame.len], storage.len));

    setFrameLength(&malformed, @intCast(frame.len - 1));
    try std.testing.expectError(error.TrailingBytes, decodeRequest(malformed[0..frame.len], storage.len));

    setFrameLength(&malformed, @sizeOf(uapi.InHeader) - 1);
    try std.testing.expectError(error.InvalidLength, decodeRequest(malformed[0..frame.len], storage.len));

    setFrameLength(&malformed, hard_max_frame_len + 1);
    try std.testing.expectError(error.FrameTooLarge, decodeRequest(malformed[0..frame.len], std.math.maxInt(usize)));
}

test "request decoding supports unaligned frames and checked fixed bodies" {
    var storage: [128]u8 = undefined;
    const body = uapi.OpenIn{
        .flags = 0x1234,
        .unused = 0,
    };
    const frame = requestFrame(storage[1..], @intFromEnum(uapi.Opcode.open), 8, std.mem.asBytes(&body));
    const request = try decodeRequest(frame, storage.len);
    const decoded = try request.bodyAs(uapi.OpenIn);

    try std.testing.expectEqual(body.flags, decoded.flags);
    var short_storage: [128]u8 = undefined;
    const short = requestFrame(&short_storage, @intFromEnum(uapi.Opcode.open), 8, "\x00");
    const short_request = try decodeRequest(short, short_storage.len);
    try std.testing.expectError(error.BodyTooShort, short_request.bodyAs(uapi.OpenIn));
}

test "name parsing requires exact NUL terminated safe components" {
    try std.testing.expectEqualStrings("alpha", try singleName("alpha\x00", 0));
    try std.testing.expectError(error.MissingNul, singleName("alpha", 0));
    try std.testing.expectError(error.EmptyName, singleName("\x00", 0));
    try std.testing.expectError(error.InvalidName, singleName("../secret\x00", 0));
    try std.testing.expectError(error.InvalidName, singleName("nested/name\x00", 0));
    try std.testing.expectError(error.TrailingNameData, singleName("alpha\x00smuggle", 0));
    try std.testing.expectError(error.BodyTooShort, singleName("alpha\x00", 7));

    const pair = try twoNames("old\x00new\x00", 0);
    try std.testing.expectEqualStrings("old", pair.first);
    try std.testing.expectEqualStrings("new", pair.second);
    try std.testing.expectError(error.MissingNul, twoNames("old\x00new", 0));
    try std.testing.expectError(error.TrailingNameData, twoNames("old\x00new\x00third", 0));
}

test "init negotiation is conservative and excludes writeback and map alignment" {
    const offered = uapi.init_async_read |
        uapi.init_big_writes |
        uapi.init_auto_inval_data |
        uapi.init_writeback_cache |
        uapi.init_parallel_dirops |
        uapi.init_handle_killpriv |
        uapi.init_max_pages |
        uapi.init_map_alignment;
    const negotiation = try negotiateInit(.{
        .major = 7,
        .minor = 36,
        .max_readahead = 2 * 1024 * 1024,
        .flags = offered,
    }, .{});
    const output = negotiation.ready;
    try std.testing.expectEqual(@as(u32, 7), output.major);
    try std.testing.expectEqual(@as(u32, 31), output.minor);
    try std.testing.expectEqual(@as(u32, 1024 * 1024), output.max_readahead);
    try std.testing.expectEqual(@as(u32, 0), output.flags & uapi.init_writeback_cache);
    try std.testing.expectEqual(@as(u32, 0), output.flags & uapi.init_map_alignment);
    try std.testing.expectEqual(@as(u32, 0), output.flags & uapi.init_parallel_dirops);
    try std.testing.expectEqual(@as(u32, 0), output.flags & uapi.init_handle_killpriv);
    try std.testing.expectEqual(@as(u16, 0), output.map_alignment);

    const retry = try negotiateInit(.{
        .major = 8,
        .minor = 0,
        .max_readahead = 0,
        .flags = 0,
    }, .{});
    try std.testing.expectEqual(@as(u32, 7), retry.retry_with_major.major);
    try std.testing.expectError(error.UnsupportedProtocol, negotiateInit(.{
        .major = 6,
        .minor = 99,
        .max_readahead = 0,
        .flags = 0,
    }, .{}));
    try std.testing.expectError(error.InvalidConfig, negotiateInit(.{
        .major = 7,
        .minor = 31,
        .max_readahead = 0,
        .flags = 0,
    }, .{ .max_write = 0 }));
}

test "reply encoding uses negative errno and aligned directory entries" {
    var error_storage: [64]u8 = undefined;
    const error_reply = try encodeError(&error_storage, 0x55, 13);
    try std.testing.expectEqual(@as(usize, @sizeOf(uapi.OutHeader)), error_reply.len);
    try std.testing.expectEqual(@as(i32, -13), std.mem.bytesToValue(uapi.OutHeader, error_reply).err);
    try std.testing.expectError(error.InvalidErrno, encodeError(&error_storage, 1, 0));
    try std.testing.expectError(error.InvalidErrno, encodeError(&error_storage, 1, uapi.max_errno + 1));

    var payload_storage: [64]u8 = undefined;
    var payload_writer = try ReplyWriter.init(&payload_storage, 0x66);
    try payload_writer.appendValue(uapi.WriteOut{ .size = 3, .padding = 0 });
    try payload_writer.appendBytes("raw");
    const payload_reply = try payload_writer.finish();
    const payload_start = @sizeOf(uapi.OutHeader) + @sizeOf(uapi.WriteOut);
    try std.testing.expectEqualStrings("raw", payload_reply[payload_start..]);

    var storage: [128]u8 = undefined;
    var writer = try ReplyWriter.init(&storage, 0x77);
    try writer.appendDirent(12, 1, 8, "abc");
    try writer.appendDirent(13, 2, 4, "12345678");
    const reply = try writer.finish();

    const first_size = @sizeOf(uapi.Dirent) + 8;
    const second_size = @sizeOf(uapi.Dirent) + 8;
    const prefix_size = @sizeOf(uapi.OutHeader);
    try std.testing.expectEqual(prefix_size + first_size + second_size, reply.len);
    try std.testing.expectEqual(@as(u8, 0), reply[prefix_size + @sizeOf(uapi.Dirent) + 3]);
    try std.testing.expectEqual(@as(u64, 13), std.mem.bytesToValue(
        uapi.Dirent,
        reply[prefix_size + first_size ..],
    ).ino);
}

test "reply writer leaves cursor unchanged on bounded output failure" {
    var storage: [@sizeOf(uapi.OutHeader) + @sizeOf(uapi.Dirent) + 7]u8 = undefined;
    var writer = try ReplyWriter.init(&storage, 1);
    const before = writer.cursor;
    try std.testing.expectError(error.NoSpace, writer.appendDirent(1, 1, 8, "eight888"));
    try std.testing.expectEqual(before, writer.cursor);

    try std.testing.expectError(error.EmptyName, writer.appendDirent(1, 1, 8, ""));
    try std.testing.expectError(error.InvalidName, writer.appendDirent(1, 1, 8, "a/b"));
    try std.testing.expectError(error.InvalidName, writer.appendDirent(1, 1, 8, "a\x00b"));
    try std.testing.expectEqual(before, writer.cursor);

    var long_name: [uapi.max_name_len + 1]u8 = .{'a'} ** (uapi.max_name_len + 1);
    _ = &long_name;
    try std.testing.expectError(error.NameTooLong, writer.appendDirent(1, 1, 8, &long_name));
    try std.testing.expectEqual(before, writer.cursor);

    var too_small: [@sizeOf(uapi.OutHeader) - 1]u8 = undefined;
    try std.testing.expectError(error.NoSpace, ReplyWriter.init(&too_small, 1));
    try std.testing.expectError(error.NoSpace, encodeError(&too_small, 1, uapi.errno_access));
}
