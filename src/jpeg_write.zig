// SPDX-License-Identifier: BSD-2-Clause

//! Writing a JPEG: baseline, eight bits a sample, in colour - the kind every
//! program reads. Taken from the same `Image` a PNG is written from, so a
//! frame read back from the GPU goes out as either.
//!
//! ```zig
//! try jpeg.writeFile(io, "shot.jpg", .{
//!     .width = 960,
//!     .height = 540,
//!     .pixels = pixels,
//!     .row_pitch = 960 * 4,
//! }, .{ .quality = 85 });
//! ```
//!
//! **A JPEG has no alpha**: the colour is written as it is, and what was see-through
//! comes back opaque. **Quality** is the scale a paint program's slider
//! means: the standard's tables, scaled the way libjpeg scales them, so a
//! file written at 85 here is about the size of one written at 85 there.
//! The colour is kept at half the brightness's resolution each way by
//! default, as cameras keep it; `chroma = .full` keeps hard coloured edges -
//! text, pixel art - sharp, in a larger file.
//!
//! The standard's Huffman tables are used, so the file is written in one
//! pass without looking at it first.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const png = @import("png.zig");

const Image = png.Image;

pub const EncodeOptions = struct {
    /// From 1, the smallest file and the most lost, to 100, the least lost.
    /// 75 to 95 for a photo or a screenshot.
    quality: u8 = 90,
    chroma: Chroma = .half,

    pub const Chroma = enum {
        /// Half the brightness's resolution each way (4:2:0): what cameras
        /// write, a third smaller.
        half,
        /// The same resolution (4:4:4): for hard coloured edges.
        full,
    };
};

pub const EncodeError = error{
    /// `pixels` is shorter than `row_pitch * height`, or a row is narrower
    /// than the width says.
    PixelsTooShort,
    /// `width` or `height` is zero.
    EmptyImage,
    /// A side longer than 65535 pixels, which a JPEG cannot say.
    TooLarge,
} || Io.Writer.Error;

/// Encode `image` as a JPEG into `w`.
pub fn encode(w: *Io.Writer, image: Image, options: EncodeOptions) EncodeError!void {
    if (image.width == 0 or image.height == 0) return error.EmptyImage;
    if (image.width > 65535 or image.height > 65535) return error.TooLarge;
    if (image.row_pitch < image.rowBytes()) return error.PixelsTooShort;
    if (image.pixels.len < image.row_pitch * (image.height - 1) + image.rowBytes()) return error.PixelsTooShort;

    const luma = scaledTable(luma_table, options.quality);
    const chroma = scaledTable(chroma_table, options.quality);
    try writeHeaders(w, image, options.chroma, &luma, &chroma);

    const luma_divisors = divisors(&luma);
    const chroma_divisors = divisors(&chroma);
    var bits: Bits = .{ .w = w };
    var previous = [3]i32{ 0, 0, 0 };

    const side: u32 = if (options.chroma == .half) 16 else 8;
    var top: u32 = 0;
    while (top < image.height) : (top += side) {
        var left: u32 = 0;
        while (left < image.width) : (left += side) {
            var planes: Planes = undefined;
            planes.fill(image, left, top, side);
            if (options.chroma == .half) {
                for ([_][2]u32{ .{ 0, 0 }, .{ 8, 0 }, .{ 0, 8 }, .{ 8, 8 } }) |at| {
                    try bits.block(&planes.blockOf(0, at[0], at[1], 1), &luma_divisors, &previous[0], &dc_luma, &ac_luma);
                }
                try bits.block(&planes.blockOf(1, 0, 0, 2), &chroma_divisors, &previous[1], &dc_chroma, &ac_chroma);
                try bits.block(&planes.blockOf(2, 0, 0, 2), &chroma_divisors, &previous[2], &dc_chroma, &ac_chroma);
            } else {
                try bits.block(&planes.blockOf(0, 0, 0, 1), &luma_divisors, &previous[0], &dc_luma, &ac_luma);
                try bits.block(&planes.blockOf(1, 0, 0, 1), &chroma_divisors, &previous[1], &dc_chroma, &ac_chroma);
                try bits.block(&planes.blockOf(2, 0, 0, 1), &chroma_divisors, &previous[2], &dc_chroma, &ac_chroma);
            }
        }
    }
    try bits.flush();
    try w.writeAll(&.{ 0xFF, 0xD9 });
}

/// Encode into memory the caller owns.
pub fn encodeAlloc(gpa: Allocator, image: Image, options: EncodeOptions) (EncodeError || Allocator.Error)![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    encode(&out.writer, image, options) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return out.toOwnedSlice();
}

/// Encode straight into a file at `path`, made or truncated.
pub fn writeFile(io: Io, path: []const u8, image: Image, options: EncodeOptions) !void {
    var file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var out = file.writer(io, &buffer);
    try encode(&out.interface, image, options);
    try out.interface.flush();
}

// -------------------------------------------------------------------------
// The tables
// -------------------------------------------------------------------------

/// Where the k-th coefficient sent sits in the block, row by row.
const natural = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

/// The standard's quantisation tables (its annex K), row by row: what each
/// frequency is divided by at quality 50.
const luma_table = [64]u8{
    16, 11, 10, 16, 24,  40,  51,  61,
    12, 12, 14, 19, 26,  58,  60,  55,
    14, 13, 16, 24, 40,  57,  69,  56,
    14, 17, 22, 29, 51,  87,  80,  62,
    18, 22, 37, 56, 68,  109, 103, 77,
    24, 35, 55, 64, 81,  104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99,
};

const chroma_table = [32]u8{
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
} ++ [_]u8{99} ** 32;

/// A table scaled for `quality` as libjpeg scales it.
fn scaledTable(base: [64]u8, quality: u8) [64]u8 {
    const q: u32 = std.math.clamp(quality, 1, 100);
    const scale: u32 = if (q < 50) 5000 / q else 200 - 2 * q;
    var out: [64]u8 = undefined;
    for (base, &out) |b, *o| o.* = @intCast(std.math.clamp((@as(u32, b) * scale + 50) / 100, 1, 255));
    return out;
}

/// What each of the DCT's coefficients is divided by: the table, row by row.
fn divisors(table: *const [64]u8) [64]f32 {
    var out: [64]f32 = undefined;
    for (table, &out) |t, *o| o.* = @floatFromInt(t);
    return out;
}

/// The standard's Huffman tables (its annex K.3): how many codes of each
/// length from 1 to 16, then the symbols in the order of their codes.
const dc_luma_counts = [16]u8{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 };
const dc_chroma_counts = [16]u8{ 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 };
const dc_symbols = [12]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };

const ac_luma_counts = [16]u8{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d };
const ac_luma_symbols = [162]u8{
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
};

const ac_chroma_counts = [16]u8{ 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77 };
const ac_chroma_symbols = [162]u8{
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
    0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
    0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
    0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
};

/// Each symbol's code and its length, zero for a symbol the table has not.
const Codes = struct {
    code: [256]u16 = @splat(0),
    length: [256]u8 = @splat(0),
};

fn codesOf(comptime counts: [16]u8, comptime symbols: []const u8) Codes {
    @setEvalBranchQuota(10_000);
    var out: Codes = .{};
    var code: u32 = 0;
    var next: usize = 0;
    for (counts, 1..) |count, length| {
        for (0..count) |_| {
            out.code[symbols[next]] = @intCast(code);
            out.length[symbols[next]] = @intCast(length);
            code += 1;
            next += 1;
        }
        code <<= 1;
    }
    if (next != symbols.len) @compileError("the counts do not add up to the symbols");
    return out;
}

const dc_luma = codesOf(dc_luma_counts, &dc_symbols);
const dc_chroma = codesOf(dc_chroma_counts, &dc_symbols);
const ac_luma = codesOf(ac_luma_counts, &ac_luma_symbols);
const ac_chroma = codesOf(ac_chroma_counts, &ac_chroma_symbols);

comptime {
    // Every symbol a block can need has a code: an end of block, sixteen
    // zeros, and each run of up to fifteen zeros before a value of up to ten
    // bits - and a difference of up to eleven bits for the first coefficient.
    for ([_]Codes{ ac_luma, ac_chroma }) |codes| {
        if (codes.length[0x00] == 0 or codes.length[0xF0] == 0) @compileError("an AC table lacks its end of block or its sixteen zeros");
        for (0..16) |run| for (1..11) |size| {
            if (codes.length[run << 4 | size] == 0) @compileError("an AC table lacks a symbol");
        };
    }
    for ([_]Codes{ dc_luma, dc_chroma }) |codes| for (0..12) |size| {
        if (codes.length[size] == 0) @compileError("a DC table lacks a size");
    };
}

// -------------------------------------------------------------------------
// The headers
// -------------------------------------------------------------------------

fn writeHeaders(w: *Io.Writer, image: Image, chroma: EncodeOptions.Chroma, luma: *const [64]u8, colour: *const [64]u8) Io.Writer.Error!void {
    // The start, and JFIF's marker: version 1.1, no density, no thumbnail.
    try w.writeAll(&.{ 0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 'J', 'F', 'I', 'F', 0, 1, 1, 0, 0, 1, 0, 1, 0, 0 });

    // The two quantisation tables, in the order the coefficients are sent.
    try w.writeAll(&.{ 0xFF, 0xDB, 0, 2 + 2 * 65 });
    for ([_]*const [64]u8{ luma, colour }, 0..) |table, id| {
        try w.writeByte(@intCast(id));
        for (natural) |at| try w.writeByte(table[at]);
    }

    // The frame: eight bits a sample, three components, the brightness
    // sampled twice as finely each way when the colour is halved.
    try w.writeAll(&.{ 0xFF, 0xC0, 0, 17, 8 });
    try w.writeInt(u16, @intCast(image.height), .big);
    try w.writeInt(u16, @intCast(image.width), .big);
    const sampling: u8 = if (chroma == .half) 0x22 else 0x11;
    try w.writeAll(&.{ 3, 1, sampling, 0, 2, 0x11, 1, 3, 0x11, 1 });

    // The four Huffman tables.
    const Table = struct { class_and_id: u8, counts: *const [16]u8, symbols: []const u8 };
    const tables = [_]Table{
        .{ .class_and_id = 0x00, .counts = &dc_luma_counts, .symbols = &dc_symbols },
        .{ .class_and_id = 0x10, .counts = &ac_luma_counts, .symbols = &ac_luma_symbols },
        .{ .class_and_id = 0x01, .counts = &dc_chroma_counts, .symbols = &dc_symbols },
        .{ .class_and_id = 0x11, .counts = &ac_chroma_counts, .symbols = &ac_chroma_symbols },
    };
    var length: u16 = 2;
    for (tables) |t| length += @intCast(1 + 16 + t.symbols.len);
    try w.writeAll(&.{ 0xFF, 0xC4 });
    try w.writeInt(u16, length, .big);
    for (tables) |t| {
        try w.writeByte(t.class_and_id);
        try w.writeAll(t.counts);
        try w.writeAll(t.symbols);
    }

    // The one scan: all three components, every coefficient.
    try w.writeAll(&.{ 0xFF, 0xDA, 0, 12, 3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0 });
}

// -------------------------------------------------------------------------
// The pixels
// -------------------------------------------------------------------------

/// One MCU's brightness and colour, level-shifted to round nought, up to 16
/// by 16; past the picture's right and bottom edge, its last column and row
/// again, so the edge does not ring.
const Planes = struct {
    samples: [3][16][16]f32,

    fn fill(self: *Planes, image: Image, left: u32, top: u32, side: u32) void {
        const channels = image.format.bytesPerPixel();
        for (0..side) |dy| {
            const y = @min(top + dy, image.height - 1);
            const row = image.row(y);
            for (0..side) |dx| {
                const x = @min(left + dx, image.width - 1);
                const pixel = row[x * channels ..][0..3];
                const r: f32 = @floatFromInt(pixel[0]);
                const g: f32 = @floatFromInt(pixel[1]);
                const b: f32 = @floatFromInt(pixel[2]);
                self.samples[0][dy][dx] = 0.299 * r + 0.587 * g + 0.114 * b - 128;
                self.samples[1][dy][dx] = -0.168736 * r - 0.331264 * g + 0.5 * b;
                self.samples[2][dy][dx] = 0.5 * r - 0.418688 * g - 0.081312 * b;
            }
        }
    }

    /// The 8 by 8 block of `plane` from (`left`, `top`), each sample the
    /// mean of `step` by `step` of them.
    fn blockOf(self: *const Planes, plane: usize, left: usize, top: usize, step: usize) [64]f32 {
        var out: [64]f32 = undefined;
        const share = 1 / @as(f32, @floatFromInt(step * step));
        for (0..8) |y| for (0..8) |x| {
            var sum: f32 = 0;
            for (0..step) |sy| for (0..step) |sx| {
                sum += self.samples[plane][top + y * step + sy][left + x * step + sx];
            };
            out[y * 8 + x] = sum * share;
        };
        return out;
    }
};

/// cos((2x + 1)uπ / 16), with the DCT's scale: a half, and 1/√2 more for
/// the first frequency.
const basis: [8][8]f32 = blk: {
    var out: [8][8]f32 = undefined;
    for (0..8) |u| for (0..8) |x| {
        const scale: f32 = if (u == 0) 0.5 * std.math.sqrt1_2 else 0.5;
        out[u][x] = scale * @cos(@as(f32, @floatFromInt((2 * x + 1) * u)) * std.math.pi / 16);
    };
    break :blk out;
};

/// The block's frequencies, row by row: its rows transformed, then its
/// columns.
fn forwardDct(block: *const [64]f32) [64]f32 {
    var rows: [64]f32 = undefined;
    for (0..8) |y| for (0..8) |u| {
        var sum: f32 = 0;
        for (0..8) |x| sum += block[y * 8 + x] * basis[u][x];
        rows[y * 8 + u] = sum;
    };
    var out: [64]f32 = undefined;
    for (0..8) |u| for (0..8) |v| {
        var sum: f32 = 0;
        for (0..8) |y| sum += rows[y * 8 + u] * basis[v][y];
        out[v * 8 + u] = sum;
    };
    return out;
}

/// The entropy-coded bits, with every 0xFF byte followed by a nought so it
/// is not read as a marker.
const Bits = struct {
    w: *Io.Writer,
    held: u64 = 0,
    count: u6 = 0,

    fn put(self: *Bits, code: u32, length: u6) Io.Writer.Error!void {
        self.held = (self.held << length) | code;
        self.count += length;
        while (self.count >= 8) {
            self.count -= 8;
            const byte: u8 = @truncate(self.held >> self.count);
            try self.w.writeByte(byte);
            if (byte == 0xFF) try self.w.writeByte(0);
        }
        self.held &= (@as(u64, 1) << self.count) - 1;
    }

    /// The last byte filled with ones, as the standard asks.
    fn flush(self: *Bits) Io.Writer.Error!void {
        if (self.count > 0) try self.put((@as(u32, 1) << @intCast(8 - self.count)) - 1, 8 - self.count);
    }

    fn symbol(self: *Bits, codes: *const Codes, which: u8) Io.Writer.Error!void {
        try self.put(codes.code[which], @intCast(codes.length[which]));
    }

    /// A value in its size's bits: as it is when positive, less one when not.
    fn value(self: *Bits, v: i32, size: u6) Io.Writer.Error!void {
        if (size == 0) return;
        const bits: u32 = @bitCast(if (v < 0) v - 1 else v);
        try self.put(bits & ((@as(u32, 1) << @intCast(size)) - 1), size);
    }

    fn block(
        self: *Bits,
        samples: *const [64]f32,
        quantisers: *const [64]f32,
        previous: *i32,
        dc: *const Codes,
        ac: *const Codes,
    ) Io.Writer.Error!void {
        const frequencies = forwardDct(samples);
        var sent: [64]i32 = undefined;
        for (natural, &sent) |at, *s| {
            // Past ten bits a baseline file cannot say it.
            s.* = std.math.clamp(@as(i32, @intFromFloat(@round(frequencies[at] / quantisers[at]))), -1023, 1023);
        }

        const difference = sent[0] - previous.*;
        previous.* = sent[0];
        const size = sizeOf(difference);
        try self.symbol(dc, size);
        try self.value(difference, size);

        var run: u8 = 0;
        for (sent[1..]) |s| {
            if (s == 0) {
                run += 1;
                continue;
            }
            while (run > 15) : (run -= 16) try self.symbol(ac, 0xF0);
            const bits = sizeOf(s);
            try self.symbol(ac, run << 4 | @as(u8, bits));
            try self.value(s, bits);
            run = 0;
        }
        if (run > 0) try self.symbol(ac, 0x00);
    }
};

/// How many bits a value's size says: nought for nought.
fn sizeOf(v: i32) u6 {
    const magnitude: u32 = @abs(v);
    return @intCast(32 - @clz(magnitude));
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const jpeg = @import("jpeg.zig");

/// A picture with something in it: soft gradients, a hard edge, and colour.
fn testPicture(comptime width: u32, comptime height: u32) [width * height * 4]u8 {
    var out: [width * height * 4]u8 = undefined;
    for (0..height) |y| for (0..width) |x| {
        const i = (y * width + x) * 4;
        out[i + 0] = @intCast(x * 255 / (width - 1));
        out[i + 1] = @intCast(y * 255 / (height - 1));
        out[i + 2] = if (x > width / 2) 200 else 40;
        out[i + 3] = 255;
    };
    return out;
}

fn meanError(a: []const u8, b: []const u8) f64 {
    var sum: u64 = 0;
    var count: u64 = 0;
    var i: usize = 0;
    while (i < a.len) : (i += 4) {
        for (0..3) |c| sum += @abs(@as(i32, a[i + c]) - @as(i32, b[i + c]));
        count += 3;
    }
    return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(count));
}

test "a picture written is read back close to what it was, at either chroma" {
    const gpa = testing.allocator;
    const pixels = testPicture(37, 23);
    const image: Image = .{ .width = 37, .height = 23, .pixels = &pixels, .row_pitch = 37 * 4 };
    for ([_]EncodeOptions.Chroma{ .half, .full }) |chroma| {
        const bytes = try encodeAlloc(gpa, image, .{ .quality = 92, .chroma = chroma });
        defer gpa.free(bytes);
        try testing.expect(std.mem.startsWith(u8, bytes, &jpeg.signature));
        try testing.expect(std.mem.endsWith(u8, bytes, &.{ 0xFF, 0xD9 }));

        var back = try jpeg.decode(gpa, bytes);
        defer back.deinit(gpa);
        try testing.expectEqual(@as(u32, 37), back.width);
        try testing.expectEqual(@as(u32, 23), back.height);
        try testing.expect(meanError(&pixels, back.pixels) < 3);
    }
}

test "a lower quality is a smaller file, and still the picture" {
    const gpa = testing.allocator;
    const pixels = testPicture(64, 48);
    const image: Image = .{ .width = 64, .height = 48, .pixels = &pixels, .row_pitch = 64 * 4 };
    const good = try encodeAlloc(gpa, image, .{ .quality = 95 });
    defer gpa.free(good);
    const poor = try encodeAlloc(gpa, image, .{ .quality = 10 });
    defer gpa.free(poor);
    try testing.expect(poor.len < good.len);

    var back = try jpeg.decode(gpa, poor);
    defer back.deinit(gpa);
    try testing.expect(meanError(&pixels, back.pixels) < 12);
}

test "three channels and a bottom row first are read as the image says" {
    const gpa = testing.allocator;
    // Two rows of three: red over blue, the bottom row first, padded to 12.
    const pixels = [_]u8{
        0, 0, 255, 0, 0, 255, 0, 0, 255, 9, 9, 9,
        255, 0, 0, 255, 0, 0, 255, 0, 0, 9, 9, 9,
    };
    const bytes = try encodeAlloc(gpa, .{ .width = 3, .height = 2, .pixels = &pixels, .row_pitch = 12, .format = .rgb8, .origin = .bottom_left }, .{ .quality = 100, .chroma = .full });
    defer gpa.free(bytes);
    var back = try jpeg.decode(gpa, bytes);
    defer back.deinit(gpa);
    try testing.expect(back.pixels[0] > 200 and back.pixels[2] < 60);
    try testing.expect(back.pixels[3 * 4 + 2] > 200 and back.pixels[3 * 4] < 60);
}

test "a picture with no pixels, or too few, is refused" {
    const gpa = testing.allocator;
    try testing.expectError(error.EmptyImage, encodeAlloc(gpa, .{ .width = 0, .height = 4, .pixels = &.{}, .row_pitch = 0 }, .{}));
    try testing.expectError(error.PixelsTooShort, encodeAlloc(gpa, .{ .width = 4, .height = 4, .pixels = &[_]u8{0} ** 20, .row_pitch = 16 }, .{}));
    try testing.expectError(error.TooLarge, encodeAlloc(gpa, .{ .width = 70000, .height = 1, .pixels = &.{}, .row_pitch = 280000 }, .{}));
}

test "a value is sent in as many bits as its size, less one when negative" {
    try testing.expectEqual(@as(u6, 0), sizeOf(0));
    try testing.expectEqual(@as(u6, 1), sizeOf(-1));
    try testing.expectEqual(@as(u6, 3), sizeOf(5));
    try testing.expectEqual(@as(u6, 10), sizeOf(-1023));
    try testing.expectEqual(@as(u8, 99), scaledTable(luma_table, 50)[63]);
    try testing.expectEqual(@as(u8, 1), scaledTable(luma_table, 100)[0]);
}
