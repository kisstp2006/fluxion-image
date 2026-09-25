// SPDX-License-Identifier: BSD-2-Clause

//! Reading a JPEG, and writing one: see `jpeg_write.zig` for that.
//!
//! ```zig
//! var photo = try jpeg.readFile(gpa, io, "photo.jpg", .{});
//! defer photo.deinit(gpa);
//! try jpeg.writeFile(io, "copy.jpg", .{ .width = photo.width, .height = photo.height, .pixels = photo.pixels, .row_pitch = photo.width * 4 }, .{ .quality = 85 });
//! ```
//!
//! **What comes out is what a PNG gives: RGBA, eight bits a channel, top row
//! first.** The alpha is always 255, since a JPEG has none. Grey, colour
//! (YCbCr or plain RGB) and CMYK files are all turned into that one shape, so
//! a caller never asks which it was.
//!
//! **Read: every JPEG a camera, a phone or a paint program writes.** That is
//! Huffman coding in all its orders - baseline, extended sequential, and
//! progressive, whose picture arrives in several passes - with eight bits a
//! sample, any sampling of the colour against the brightness, restart markers,
//! and the Adobe marker that says a four-channel file is CMYK or YCCK. A
//! phone's sideways photo comes out upright: the orientation its Exif data
//! gives is applied.
//!
//! **Refused by name:** arithmetic coding, lossless and hierarchical JPEGs,
//! and twelve bits a sample. Almost nothing writes them, and an error saying
//! which is a better answer than a wrong picture.
//!
//! **How it is read.** Every scan's coefficients go into one store per
//! component, whichever order the file sends them in; once the file is read,
//! each block is dequantised and turned back into pixels by a float inverse
//! DCT, the colour is brought up to the picture's size the way libjpeg does
//! it by default - by a triangle filter where it was halved, so an edge in
//! the colour does not come out as steps - and turned into RGB.
//!
//! A file cut short gives the picture as far as it got, as a browser shows
//! it; one with nothing to show fails.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const png = @import("png.zig");
const write = @import("jpeg_write.zig");

/// How a JPEG is written: its quality and how finely its colour is kept.
pub const EncodeOptions = write.EncodeOptions;
pub const EncodeError = write.EncodeError;
/// Write a baseline JPEG of an `Image`, into a writer, into memory, or
/// into a file.
pub const encode = write.encode;
pub const encodeAlloc = write.encodeAlloc;
pub const writeFile = write.writeFile;

/// A decoded picture, and the memory it lives in: the same as a PNG's.
pub const Decoded = png.Decoded;

/// How far to trust a file this program did not write. `max_pixels` is what
/// counts here; a JPEG has no checksums to verify.
pub const DecodeOptions = png.DecodeOptions;

/// The bytes every JPEG starts with: a start-of-image marker, and the first
/// byte of the marker after it.
pub const signature = [_]u8{ 0xFF, 0xD8, 0xFF };

pub const DecodeError = error{
    /// The first bytes are not a JPEG's.
    NotAJpeg,
    /// The file ends before there is anything to show.
    Truncated,
    /// A frame header that describes no picture: no width or no height, a
    /// sampling factor out of range, or a second frame.
    BadHeader,
    /// Arithmetic coding, or a lossless or hierarchical file.
    UnsupportedCoding,
    /// Samples of other than eight bits.
    UnsupportedPrecision,
    /// Other than one, three or four components.
    UnsupportedColour,
    /// A scan uses a Huffman or quantisation table the file never gave.
    MissingTable,
    /// No frame, or no scan.
    MissingImageData,
    /// A segment or the coded data does not say anything a JPEG can say.
    CorruptImageData,
    /// The header claims more pixels than `DecodeOptions.max_pixels`.
    ImageTooLarge,
} || Allocator.Error;

/// Read a JPEG. The caller owns what comes back and frees it with `deinit`.
pub fn decode(gpa: Allocator, bytes: []const u8) DecodeError!Decoded {
    return decodeWith(gpa, bytes, .{});
}

pub fn decodeWith(gpa: Allocator, bytes: []const u8, options: DecodeOptions) DecodeError!Decoded {
    if (bytes.len < signature.len or !std.mem.eql(u8, bytes[0..signature.len], &signature)) return error.NotAJpeg;
    var decoder: Decoder = .{ .gpa = gpa, .bytes = bytes, .options = options };
    defer decoder.deinit();
    try decoder.readSegments();
    return decoder.picture();
}

/// Read the file at `path` and decode it.
pub fn readFile(gpa: Allocator, io: Io, path: []const u8, options: DecodeOptions) !Decoded {
    // Four bytes a pixel would not reach this compressed, and a file bigger
    // than it is not a texture.
    const limit: Io.Limit = .limited64(@min(options.max_pixels * 4, std.math.maxInt(usize)));
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, limit);
    defer gpa.free(bytes);
    return decodeWith(gpa, bytes, options);
}

// -------------------------------------------------------------------------
// The file
// -------------------------------------------------------------------------

const max_components = 4;

/// Where each coefficient of a block, sent in zigzag order, sits in the
/// block, row by row - and sixteen more, all the last, so a run in a damaged
/// file that goes past the end writes somewhere harmless.
const natural = [_]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
} ++ [_]u8{63} ** 16;

const Component = struct {
    id: u8,
    /// How many blocks across and down it has in each MCU.
    h: u8,
    v: u8,
    /// The quantisation table it names, and the table itself as it stood
    /// when the component's first scan began - a file may define another
    /// under the same number later, for another component.
    table: u8,
    quant: ?[64]u16 = null,
    /// Its blocks, as many as whole MCUs cover.
    blocks_across: u32 = 0,
    blocks_down: u32 = 0,
    /// The blocks that hold the picture: what a scan of it alone goes
    /// through.
    used_across: u32 = 0,
    used_down: u32 = 0,
    /// Its samples across and down, before they are brought up to the
    /// picture's size.
    width: u32 = 0,
    height: u32 = 0,
    coefficients: []i16 = &.{},
    /// The last DC value, which the next block's is sent against.
    dc: i32 = 0,

    fn block(self: *Component, across: u32, down: u32) *[64]i16 {
        const at = (@as(usize, down) * self.blocks_across + across) * 64;
        return self.coefficients[at..][0..64];
    }
};

/// What the colour components are, as the file says it in its markers.
const Transform = enum { unknown, none, ycc, ycck };

const Decoder = struct {
    gpa: Allocator,
    bytes: []const u8,
    options: DecodeOptions,

    quant: [4]?[64]u16 = @splat(null),
    dc_tables: [4]Huffman = @splat(.{}),
    ac_tables: [4]Huffman = @splat(.{}),
    restart_interval: u32 = 0,

    framed: bool = false,
    progressive: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    components: [max_components]Component = undefined,
    count: usize = 0,
    h_max: u8 = 1,
    v_max: u8 = 1,
    mcus_across: u32 = 0,
    mcus_down: u32 = 0,
    scans: usize = 0,

    jfif: bool = false,
    adobe: ?u8 = null,
    /// Exif's orientation, one to eight; one is as stored.
    orientation: u8 = 1,

    fn deinit(self: *Decoder) void {
        for (self.components[0..self.count]) |*c| self.gpa.free(c.coefficients);
    }

    /// Every segment in turn, the scans' coded data with them, to the end of
    /// the picture - or of the file, where one is cut short after a scan.
    fn readSegments(self: *Decoder) DecodeError!void {
        const bytes = self.bytes;
        var pos: usize = 2;
        while (true) {
            // Anything between segments is walked past, as libjpeg does.
            while (pos < bytes.len and bytes[pos] != 0xFF) pos += 1;
            while (pos < bytes.len and bytes[pos] == 0xFF) pos += 1;
            if (pos >= bytes.len) return self.endedEarly();
            const marker = bytes[pos];
            pos += 1;
            switch (marker) {
                0xD9 => return,
                0xD8, 0x01, 0xD0...0xD7 => continue,
                else => {},
            }
            if (bytes.len - pos < 2) return self.endedEarly();
            const length = std.mem.readInt(u16, bytes[pos..][0..2], .big);
            if (length < 2) return error.CorruptImageData;
            if (bytes.len - pos < length) return self.endedEarly();
            const body = bytes[pos + 2 .. pos + length];
            pos += length;
            switch (marker) {
                0xC0, 0xC1, 0xC2 => try self.frame(body, marker == 0xC2),
                0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => return error.UnsupportedCoding,
                0xC4 => try self.huffmanTables(body),
                0xDB => try self.quantTables(body),
                0xDD => {
                    if (body.len < 2) return error.CorruptImageData;
                    self.restart_interval = std.mem.readInt(u16, body[0..2], .big);
                },
                0xDA => pos = try self.scan(body, pos),
                0xE0 => {
                    if (std.mem.startsWith(u8, body, "JFIF\x00")) self.jfif = true;
                },
                0xE1 => if (std.mem.startsWith(u8, body, "Exif\x00\x00")) {
                    self.orientation = exifOrientation(body[6..]) orelse 1;
                },
                0xEE => if (body.len >= 12 and std.mem.startsWith(u8, body, "Adobe")) {
                    self.adobe = body[11];
                },
                else => {},
            }
        }
    }

    /// The file is over: what the scans so far show, or nothing.
    fn endedEarly(self: *const Decoder) DecodeError!void {
        if (self.scans == 0) return error.Truncated;
    }

    fn frame(self: *Decoder, body: []const u8, progressive: bool) DecodeError!void {
        if (self.framed) return error.BadHeader;
        if (body.len < 6) return error.CorruptImageData;
        if (body[0] != 8) return error.UnsupportedPrecision;
        const height = std.mem.readInt(u16, body[1..3], .big);
        const width = std.mem.readInt(u16, body[3..5], .big);
        const count = body[5];
        if (width == 0 or height == 0) return error.BadHeader;
        if (count != 1 and count != 3 and count != 4) return error.UnsupportedColour;
        if (body.len < 6 + @as(usize, count) * 3) return error.CorruptImageData;
        if (@as(u64, width) * height > self.options.max_pixels) return error.ImageTooLarge;

        self.width = width;
        self.height = height;
        self.progressive = progressive;
        for (0..count) |i| {
            const at = body[6 + i * 3 ..][0..3];
            const h = at[1] >> 4;
            const v = at[1] & 15;
            if (h < 1 or h > 4 or v < 1 or v > 4 or at[2] > 3) return error.BadHeader;
            self.components[i] = .{ .id = at[0], .h = h, .v = v, .table = at[2] };
            self.h_max = @max(self.h_max, h);
            self.v_max = @max(self.v_max, v);
        }
        self.mcus_across = divCeil(width, 8 * @as(u32, self.h_max));
        self.mcus_down = divCeil(height, 8 * @as(u32, self.v_max));
        for (self.components[0..count]) |*c| {
            c.width = divCeil(width * @as(u32, c.h), self.h_max);
            c.height = divCeil(height * @as(u32, c.v), self.v_max);
            c.blocks_across = self.mcus_across * c.h;
            c.blocks_down = self.mcus_down * c.v;
            c.used_across = divCeil(c.width, 8);
            c.used_down = divCeil(c.height, 8);
            const blocks = @as(usize, c.blocks_across) * c.blocks_down;
            c.coefficients = try self.gpa.alloc(i16, blocks * 64);
            @memset(c.coefficients, 0);
            self.count += 1;
        }
        self.framed = true;
    }

    fn huffmanTables(self: *Decoder, body: []const u8) DecodeError!void {
        var at: usize = 0;
        while (at < body.len) {
            if (body.len - at < 17) return error.CorruptImageData;
            const class = body[at] >> 4;
            const slot = body[at] & 15;
            if (class > 1 or slot > 3) return error.CorruptImageData;
            const counts = body[at + 1 ..][0..16];
            var total: usize = 0;
            for (counts) |n| total += n;
            if (total > 256 or body.len - at - 17 < total) return error.CorruptImageData;
            const values = body[at + 17 ..][0..total];
            const table = if (class == 0) &self.dc_tables[slot] else &self.ac_tables[slot];
            try table.build(counts, values);
            at += 17 + total;
        }
    }

    fn quantTables(self: *Decoder, body: []const u8) DecodeError!void {
        var at: usize = 0;
        while (at < body.len) {
            const wide = body[at] >> 4;
            const slot = body[at] & 15;
            if (wide > 1 or slot > 3) return error.CorruptImageData;
            const size: usize = if (wide == 1) 128 else 64;
            if (body.len - at - 1 < size) return error.CorruptImageData;
            var table: [64]u16 = undefined;
            for (0..64) |i| {
                const value: u16 = if (wide == 1) std.mem.readInt(u16, body[at + 1 + i * 2 ..][0..2], .big) else body[at + 1 + i];
                table[natural[i]] = value;
            }
            self.quant[slot] = table;
            at += 1 + size;
        }
    }

    /// A scan's header, then its coded data from `data`. Gives where the
    /// segment after it starts.
    fn scan(self: *Decoder, body: []const u8, data: usize) DecodeError!usize {
        if (!self.framed) return error.MissingImageData;
        if (body.len < 1) return error.CorruptImageData;
        const count = body[0];
        if (count < 1 or count > self.count or body.len < 1 + @as(usize, count) * 2 + 3) return error.CorruptImageData;
        var in_scan: [max_components]*Component = undefined;
        var dc_of: [max_components]u8 = undefined;
        var ac_of: [max_components]u8 = undefined;
        for (0..count) |i| {
            const id = body[1 + i * 2];
            const tables = body[2 + i * 2];
            const component = for (self.components[0..self.count]) |*c| {
                if (c.id == id) break c;
            } else return error.CorruptImageData;
            in_scan[i] = component;
            dc_of[i] = tables >> 4;
            ac_of[i] = tables & 15;
            if (dc_of[i] > 3 or ac_of[i] > 3) return error.CorruptImageData;
            if (component.quant == null) component.quant = self.quant[component.table] orelse return error.MissingTable;
        }
        const tail = body[1 + @as(usize, count) * 2 ..];
        var pass: Pass = .{
            .start = tail[0],
            .end = tail[1],
            .high = tail[2] >> 4,
            .low = tail[2] & 15,
        };
        if (!self.progressive) {
            pass = .{ .start = 0, .end = 63, .high = 0, .low = 0 };
        } else {
            if (pass.end > 63 or pass.start > pass.end or pass.low > 13) return error.CorruptImageData;
            // The DC coefficient goes alone; the others one component at a
            // time.
            if ((pass.start == 0) != (pass.end == 0)) return error.CorruptImageData;
            if (pass.start > 0 and count != 1) return error.CorruptImageData;
        }

        // The tables this scan decodes with, all there before a bit is read.
        var dc_tables: [max_components]*const Huffman = undefined;
        var ac_tables: [max_components]*const Huffman = undefined;
        for (0..count) |i| {
            dc_tables[i] = &self.dc_tables[dc_of[i]];
            ac_tables[i] = &self.ac_tables[ac_of[i]];
            const needs_dc = pass.start == 0 and pass.high == 0;
            const needs_ac = pass.end > 0;
            if (needs_dc and !dc_tables[i].defined) return error.MissingTable;
            if (needs_ac and !ac_tables[i].defined) return error.MissingTable;
        }

        var coded: Coded = .{ .bits = .{ .bytes = self.bytes, .at = data }, .pass = pass };
        for (in_scan[0..count]) |c| c.dc = 0;
        var left = self.restart_interval;

        if (count == 1) {
            // One component: its blocks in order, each its own MCU.
            const c = in_scan[0];
            var down: u32 = 0;
            while (down < c.used_down) : (down += 1) {
                var across: u32 = 0;
                while (across < c.used_across) : (across += 1) {
                    try self.restartIfDue(&coded, in_scan[0..count], &left);
                    try coded.block(c.block(across, down), &c.dc, dc_tables[0], ac_tables[0]);
                }
            }
        } else {
            var my: u32 = 0;
            while (my < self.mcus_down) : (my += 1) {
                var mx: u32 = 0;
                while (mx < self.mcus_across) : (mx += 1) {
                    try self.restartIfDue(&coded, in_scan[0..count], &left);
                    for (in_scan[0..count], 0..) |c, i| {
                        for (0..c.v) |by| for (0..c.h) |bx| {
                            const across = mx * c.h + @as(u32, @intCast(bx));
                            const down = my * c.v + @as(u32, @intCast(by));
                            try coded.block(c.block(across, down), &c.dc, dc_tables[i], ac_tables[i]);
                        };
                    }
                }
            }
        }
        self.scans += 1;
        return coded.bits.nextMarker();
    }

    /// Every `restart_interval` MCUs the coder starts afresh after a restart
    /// marker: the bits left over are padding, and the DC values are sent
    /// against nought again.
    fn restartIfDue(self: *const Decoder, coded: *Coded, in_scan: []const *Component, left: *u32) DecodeError!void {
        if (self.restart_interval == 0) return;
        if (left.* == 0) {
            coded.bits.restart();
            coded.eob_run = 0;
            for (in_scan) |c| c.dc = 0;
            left.* = self.restart_interval;
        }
        left.* -= 1;
    }

    // ---------------------------------------------------------------------
    // The picture
    // ---------------------------------------------------------------------

    fn picture(self: *Decoder) DecodeError!Decoded {
        if (!self.framed or self.scans == 0) return error.MissingImageData;
        const gpa = self.gpa;
        const width = self.width;
        const height = self.height;
        const pixels = @as(usize, width) * height;

        // Each component's samples, brought up to the picture's size.
        var planes: [max_components][]u8 = undefined;
        var made: usize = 0;
        defer for (planes[0..made]) |plane| gpa.free(plane);
        for (self.components[0..self.count]) |*c| {
            const samples = try self.samplesOf(c);
            defer gpa.free(samples);
            planes[made] = try gpa.alloc(u8, pixels);
            made += 1;
            upsample(samples, c.blocks_across * 8, c.width, c.height, self.h_max / c.h, self.v_max / c.v, c.h, c.v, self.h_max, self.v_max, planes[made - 1], width, height);
        }

        const rgba = try gpa.alloc(u8, pixels * 4);
        errdefer gpa.free(rgba);
        const transform = self.colourTransform();
        for (0..pixels) |i| {
            const out = rgba[i * 4 ..][0..4];
            switch (self.count) {
                1 => out.* = .{ planes[0][i], planes[0][i], planes[0][i], 255 },
                3 => out.* = if (transform == .none)
                    .{ planes[0][i], planes[1][i], planes[2][i], 255 }
                else
                    yccToRgb(planes[0][i], planes[1][i], planes[2][i]),
                else => {
                    // Four: CMYK, or YCCK - CMY sent as YCbCr. An Adobe file
                    // stores them inverted, which is how a program reading
                    // it knows to read them back.
                    const k = planes[3][i];
                    var cmy: [3]u8 = .{ planes[0][i], planes[1][i], planes[2][i] };
                    if (transform == .ycck) {
                        const rgb = yccToRgb(cmy[0], cmy[1], cmy[2]);
                        cmy = .{ 255 - rgb[0], 255 - rgb[1], 255 - rgb[2] };
                    }
                    const inverted = self.adobe != null;
                    out.* = .{ inkToLight(cmy[0], k, inverted), inkToLight(cmy[1], k, inverted), inkToLight(cmy[2], k, inverted), 255 };
                },
            }
        }
        var decoded: Decoded = .{ .width = width, .height = height, .pixels = rgba };
        if (self.orientation != 1) {
            const turned = try orient(gpa, decoded, self.orientation);
            gpa.free(rgba);
            decoded = turned;
        }
        return decoded;
    }

    /// What the components are, as libjpeg decides it: JFIF says YCbCr, an
    /// Adobe marker says which, and otherwise the components' ids tell RGB
    /// from YCbCr.
    fn colourTransform(self: *const Decoder) Transform {
        if (self.count == 3) {
            if (self.jfif) return .ycc;
            if (self.adobe) |said| return if (said == 0) .none else .ycc;
            const ids = [3]u8{ self.components[0].id, self.components[1].id, self.components[2].id };
            if (std.mem.eql(u8, &ids, "RGB")) return .none;
            return .ycc;
        }
        if (self.count == 4) {
            if (self.adobe) |said| return if (said == 2) .ycck else .none;
            return .none;
        }
        return .unknown;
    }

    /// A component's samples, block by block: dequantised and back through
    /// the inverse DCT.
    fn samplesOf(self: *Decoder, c: *Component) Allocator.Error![]u8 {
        const stride = @as(usize, c.blocks_across) * 8;
        const samples = try self.gpa.alloc(u8, stride * @as(usize, c.blocks_down) * 8);
        // A component no scan reached is grey, as its coefficients are all
        // nought.
        const table = c.quant orelse [_]u16{1} ** 64;
        var down: u32 = 0;
        while (down < c.used_down) : (down += 1) {
            var across: u32 = 0;
            while (across < c.used_across) : (across += 1) {
                const at = @as(usize, down) * 8 * stride + @as(usize, across) * 8;
                inverseDct(c.block(across, down), &table, samples[at..], stride);
            }
        }
        return samples;
    }
};

fn divCeil(a: u32, b: u32) u32 {
    return (a + b - 1) / b;
}

// -------------------------------------------------------------------------
// The coded data
// -------------------------------------------------------------------------

/// A canonical Huffman table: the first nine bits of every code looked up
/// at once, and the longer ones found by length.
const Huffman = struct {
    defined: bool = false,
    /// For each nine-bit prefix: the code's length in the high byte and its
    /// value in the low one, or nought where the code is longer.
    fast: [512]u16 = @splat(0),
    /// For each length, the largest code of it, or -1 for none.
    max_code: [17]i32 = @splat(-1),
    /// For each length, where its values start, less its first code.
    offset: [17]i32 = @splat(0),
    values: [256]u8 = @splat(0),

    fn build(self: *Huffman, counts: *const [16]u8, values: []const u8) DecodeError!void {
        self.* = .{ .defined = true };
        @memcpy(self.values[0..values.len], values);
        var code: u32 = 0;
        var k: usize = 0;
        for (1..17) |length| {
            const n = counts[length - 1];
            self.offset[length] = @as(i32, @intCast(k)) - @as(i32, @intCast(code));
            for (0..n) |_| {
                // A code that does not fit in its length is no table at all.
                if (code >= (@as(u32, 1) << @intCast(length))) return error.CorruptImageData;
                if (length <= 9) {
                    const shift: u4 = @intCast(9 - length);
                    const first = code << shift;
                    const last = (code + 1) << shift;
                    for (first..last) |slot| self.fast[slot] = @intCast((length << 8) | self.values[k]);
                }
                code += 1;
                k += 1;
            }
            if (n > 0) self.max_code[length] = @intCast(code - 1);
            code <<= 1;
        }
    }

    fn decode(self: *const Huffman, bits: *Bits) DecodeError!u8 {
        bits.fill();
        const quick = self.fast[bits.peek(9)];
        if (quick != 0) {
            bits.skip(@intCast(quick >> 8));
            return @truncate(quick);
        }
        const sixteen = bits.peek(16);
        for (10..17) |length| {
            const code: i32 = @intCast(sixteen >> @intCast(16 - length));
            if (code <= self.max_code[length]) {
                bits.skip(@intCast(length));
                const at = code + self.offset[length];
                if (at < 0 or at > 255) return error.CorruptImageData;
                return self.values[@intCast(at)];
            }
        }
        return error.CorruptImageData;
    }
};

/// The bits of a scan's coded data, with the stuffed nought after each 0xFF
/// taken out. At a marker it stops and hands out noughts, so a scan cut
/// short ends rather than reading the next segment as pictures.
const Bits = struct {
    bytes: []const u8,
    /// The next byte to take.
    at: usize,
    /// The bits taken and not yet used: the low `count` of them.
    held: u64 = 0,
    count: u7 = 0,
    /// Where the marker that stopped it starts, once it has.
    marker_at: ?usize = null,

    /// At least 57 bits held.
    fn fill(self: *Bits) void {
        while (self.count <= 56) {
            var byte: u8 = 0;
            if (self.marker_at == null and self.at < self.bytes.len) {
                byte = self.bytes[self.at];
                if (byte == 0xFF) {
                    var next = self.at + 1;
                    while (next < self.bytes.len and self.bytes[next] == 0xFF) next += 1;
                    if (next < self.bytes.len and self.bytes[next] == 0x00) {
                        self.at = next + 1;
                    } else {
                        self.marker_at = self.at;
                        byte = 0;
                    }
                } else self.at += 1;
            }
            self.held = (self.held << 8) | byte;
            self.count += 8;
        }
    }

    fn peek(self: *const Bits, n: u5) u32 {
        return @intCast((self.held >> @intCast(self.count - n)) & ((@as(u64, 1) << n) - 1));
    }

    fn skip(self: *Bits, n: u5) void {
        self.count -= n;
    }

    fn take(self: *Bits, n: u5) u32 {
        if (n == 0) return 0;
        if (self.count < n) self.fill();
        const value = self.peek(n);
        self.skip(n);
        return value;
    }

    /// `n` bits as the signed number they stand for: the ones below half of
    /// the range are negative.
    fn signed(self: *Bits, n: u5) i32 {
        if (n == 0) return 0;
        const value: i32 = @intCast(self.take(n));
        const half: i32 = @as(i32, 1) << @intCast(n - 1);
        return if (value < half) value - (@as(i32, 1) << @intCast(n)) + 1 else value;
    }

    /// Past the restart marker that comes next: the bits held are padding.
    fn restart(self: *Bits) void {
        var i = self.marker_at orelse self.at;
        while (i + 1 < self.bytes.len) : (i += 1) {
            if (self.bytes[i] != 0xFF) continue;
            const kind = self.bytes[i + 1];
            if (kind >= 0xD0 and kind <= 0xD7) {
                i += 2;
                break;
            }
            // Another marker: the restart is missing, and what follows is
            // not this scan's.
            if (kind != 0x00 and kind != 0xFF) break;
        }
        self.at = @min(i, self.bytes.len);
        self.held = 0;
        self.count = 0;
        self.marker_at = null;
    }

    /// Where the segment after the scan starts.
    fn nextMarker(self: *const Bits) usize {
        var i = self.marker_at orelse self.at;
        while (i + 1 < self.bytes.len) : (i += 1) {
            if (self.bytes[i] != 0xFF) continue;
            const kind = self.bytes[i + 1];
            if (kind == 0x00 or kind == 0xFF or (kind >= 0xD0 and kind <= 0xD7)) continue;
            return i;
        }
        return self.bytes.len;
    }
};

/// Which coefficients a scan sends, and which of their bits: all of them in
/// a sequential file; a band of them, and first their high bits and then
/// one lower bit at a time, in a progressive one.
const Pass = struct {
    start: u8,
    end: u8,
    /// The bit sent before, or nought for the first time; the bit sent now.
    high: u8,
    low: u8,
};

const Coded = struct {
    bits: Bits,
    pass: Pass,
    /// Blocks still to come with nothing more in this band: a progressive
    /// scan's end-of-band run.
    eob_run: u32 = 0,

    fn block(self: *Coded, coefficients: *[64]i16, dc: *i32, dc_table: *const Huffman, ac_table: *const Huffman) DecodeError!void {
        const pass = self.pass;
        if (pass.start == 0) {
            if (pass.high == 0) {
                try self.firstDc(coefficients, dc, dc_table);
            } else if (self.bits.take(1) == 1) {
                coefficients[0] |= @as(i16, 1) << @intCast(pass.low);
            }
            if (pass.end == 0) return;
        }
        if (pass.high == 0) return self.firstAc(coefficients, ac_table);
        return self.refineAc(coefficients, ac_table);
    }

    fn firstDc(self: *Coded, coefficients: *[64]i16, dc: *i32, table: *const Huffman) DecodeError!void {
        const size = try table.decode(&self.bits);
        if (size > 16) return error.CorruptImageData;
        dc.* += self.bits.signed(@intCast(size));
        coefficients[0] = clampCoefficient(dc.* * (@as(i32, 1) << @intCast(self.pass.low)));
    }

    fn firstAc(self: *Coded, coefficients: *[64]i16, table: *const Huffman) DecodeError!void {
        if (self.eob_run > 0) {
            self.eob_run -= 1;
            return;
        }
        const low: u5 = @intCast(self.pass.low);
        var k: usize = @max(self.pass.start, 1);
        while (k <= self.pass.end) : (k += 1) {
            const symbol = try table.decode(&self.bits);
            const run = symbol >> 4;
            const size = symbol & 15;
            if (size != 0) {
                k += run;
                coefficients[natural[k]] = clampCoefficient(self.bits.signed(@intCast(size)) * (@as(i32, 1) << low));
            } else if (run == 15) {
                k += 15;
            } else {
                // End of band, for this block and as many more as it says.
                var blocks: u32 = @as(u32, 1) << @intCast(run);
                if (run > 0) blocks += self.bits.take(@intCast(run));
                self.eob_run = blocks - 1;
                break;
            }
        }
    }

    /// A lower bit of every coefficient in the band: of those already
    /// sent, one correction bit each; of those still nought, the ones that
    /// now become plus or minus this bit. As libjpeg's `decode_mcu_AC_refine`.
    fn refineAc(self: *Coded, coefficients: *[64]i16, table: *const Huffman) DecodeError!void {
        const plus: i16 = @as(i16, 1) << @intCast(self.pass.low);
        const minus: i16 = -plus;
        var k: usize = self.pass.start;
        if (self.eob_run == 0) {
            while (k <= self.pass.end) : (k += 1) {
                const symbol = try table.decode(&self.bits);
                var run: i32 = symbol >> 4;
                const size = symbol & 15;
                var value: i16 = 0;
                if (size != 0) {
                    // A new coefficient is always one bit, and its sign.
                    value = if (self.bits.take(1) == 1) plus else minus;
                } else if (run != 15) {
                    self.eob_run = @as(u32, 1) << @intCast(run);
                    if (run > 0) self.eob_run += self.bits.take(@intCast(run));
                    break;
                }
                // Past the coefficients already sent, correcting each, and
                // `run` of those still nought, to the one that is new.
                while (k <= self.pass.end) : (k += 1) {
                    const at = natural[k];
                    if (coefficients[at] != 0) {
                        self.correct(&coefficients[at], plus, minus);
                    } else {
                        if (run == 0) break;
                        run -= 1;
                    }
                }
                if (value != 0 and k <= 63) coefficients[natural[k]] = value;
            }
        }
        if (self.eob_run > 0) {
            // The rest of the band has nothing new: only corrections.
            while (k <= self.pass.end) : (k += 1) {
                const at = natural[k];
                if (coefficients[at] != 0) self.correct(&coefficients[at], plus, minus);
            }
            self.eob_run -= 1;
        }
    }

    /// One correction bit: a one adds this pass's bit to the coefficient's
    /// size, away from nought, unless it is there already.
    fn correct(self: *Coded, coefficient: *i16, plus: i16, minus: i16) void {
        if (self.bits.take(1) == 0) return;
        if ((coefficient.* & plus) != 0) return;
        coefficient.* += if (coefficient.* >= 0) plus else minus;
    }
};

fn clampCoefficient(value: i32) i16 {
    return @intCast(std.math.clamp(value, std.math.minInt(i16), std.math.maxInt(i16)));
}

// -------------------------------------------------------------------------
// Back to pixels
// -------------------------------------------------------------------------

const Row = @Vector(8, f32);

/// The inverse DCT's basis: for each frequency, its cosine at each of the
/// eight places, scaled as the transform wants.
const cosines: [8][8]f32 = blk: {
    @setEvalBranchQuota(10_000);
    var rows: [8][8]f32 = undefined;
    for (0..8) |u| {
        const scale: f64 = if (u == 0) 1.0 / @sqrt(2.0) else 1.0;
        for (0..8) |x| {
            rows[u][x] = @floatCast(scale / 2.0 * @cos(@as(f64, @floatFromInt((2 * x + 1) * u)) * std.math.pi / 16.0));
        }
    }
    break :blk rows;
};

/// The same, a frequency's eight as one vector.
const basis: [8]Row = blk: {
    var rows: [8]Row = undefined;
    for (0..8) |u| rows[u] = cosines[u];
    break :blk rows;
};

/// One block: dequantised, through the inverse DCT row by row and then
/// column by column, and written as eight rows of eight samples.
fn inverseDct(coefficients: *const [64]i16, table: *const [64]u16, out: []u8, stride: usize) void {
    var rows: [8]Row = undefined;
    for (0..8) |v| {
        var sum: Row = @splat(0);
        for (0..8) |u| {
            const c = coefficients[v * 8 + u];
            if (c == 0) continue;
            const value: f32 = @floatFromInt(@as(i32, c) * table[v * 8 + u]);
            sum += @as(Row, @splat(value)) * basis[u];
        }
        rows[v] = sum;
    }
    for (0..8) |y| {
        var sum: Row = @splat(128);
        for (0..8) |v| sum += @as(Row, @splat(cosines[v][y])) * rows[v];
        const clamped = @min(@max(@round(sum), @as(Row, @splat(0))), @as(Row, @splat(255)));
        const bytes: @Vector(8, u8) = @intFromFloat(clamped);
        out[y * stride ..][0..8].* = bytes;
    }
}

/// A component's samples at the picture's size. Halved across, down or both,
/// it is brought up by libjpeg's triangle filters - each new sample three
/// parts the nearest and one part the next - and any other factor by
/// repeating each sample.
fn upsample(
    samples: []const u8,
    stride: usize,
    width: u32,
    height: u32,
    across: u8,
    down: u8,
    h: u8,
    v: u8,
    h_max: u8,
    v_max: u8,
    out: []u8,
    out_width: u32,
    out_height: u32,
) void {
    const whole_across = @as(u32, h) * across == h_max;
    const whole_down = @as(u32, v) * down == v_max;
    const clampX = struct {
        fn f(x: i64, n: u32) usize {
            return @intCast(std.math.clamp(x, 0, @as(i64, n) - 1));
        }
    }.f;
    for (0..out_height) |oy| {
        const line = out[oy * out_width ..][0..out_width];
        if (across == 1 and down == 1 and whole_across and whole_down) {
            @memcpy(line, samples[oy * stride ..][0..out_width]);
        } else if (across == 2 and down == 1 and whole_across and whole_down) {
            const row = samples[oy * stride ..];
            for (0..out_width) |ox| {
                const i = ox / 2;
                const near: u32 = row[i];
                if (ox % 2 == 0) {
                    line[ox] = @intCast((3 * near + row[clampX(@as(i64, @intCast(i)) - 1, width)] + 1) >> 2);
                } else {
                    line[ox] = @intCast((3 * near + row[clampX(@as(i64, @intCast(i)) + 1, width)] + 2) >> 2);
                }
            }
        } else if (across == 1 and down == 2 and whole_across and whole_down) {
            const j = oy / 2;
            const far_row = if (oy % 2 == 0) clampX(@as(i64, @intCast(j)) - 1, height) else clampX(@as(i64, @intCast(j)) + 1, height);
            const bias: u32 = if (oy % 2 == 0) 1 else 2;
            const near = samples[j * stride ..];
            const far = samples[far_row * stride ..];
            for (0..out_width) |ox| line[ox] = @intCast((3 * @as(u32, near[ox]) + far[ox] + bias) >> 2);
        } else if (across == 2 and down == 2 and whole_across and whole_down) {
            const j = oy / 2;
            const far_row = if (oy % 2 == 0) clampX(@as(i64, @intCast(j)) - 1, height) else clampX(@as(i64, @intCast(j)) + 1, height);
            const near = samples[j * stride ..];
            const far = samples[far_row * stride ..];
            const Sum = struct {
                fn at(n: []const u8, f: []const u8, i: usize) u32 {
                    return 3 * @as(u32, n[i]) + f[i];
                }
            };
            for (0..out_width) |ox| {
                const i = ox / 2;
                const this = Sum.at(near, far, i);
                if (ox % 2 == 0) {
                    line[ox] = @intCast((3 * this + Sum.at(near, far, clampX(@as(i64, @intCast(i)) - 1, width)) + 8) >> 4);
                } else {
                    line[ox] = @intCast((3 * this + Sum.at(near, far, clampX(@as(i64, @intCast(i)) + 1, width)) + 7) >> 4);
                }
            }
        } else {
            const sy = @min(oy * v / v_max, height - 1);
            for (0..out_width) |ox| {
                const sx = @min(ox * h / h_max, width - 1);
                line[ox] = samples[sy * stride + sx];
            }
        }
    }
}

/// JFIF's YCbCr to RGB, in libjpeg's fixed point, so the same file comes out
/// the same here as there.
fn yccToRgb(y: u8, cb: u8, cr: u8) [4]u8 {
    const luma: i32 = y;
    const blue: i32 = @as(i32, cb) - 128;
    const red: i32 = @as(i32, cr) - 128;
    const half: i32 = 1 << 15;
    const r = luma + ((91881 * red + half) >> 16);
    const g = luma + ((-22554 * blue - 46802 * red + half) >> 16);
    const b = luma + ((116130 * blue + half) >> 16);
    return .{ clampByte(r), clampByte(g), clampByte(b), 255 };
}

fn clampByte(value: i32) u8 {
    return @intCast(std.math.clamp(value, 0, 255));
}

/// How much light is left of one ink under black. `inverted`, the ink is
/// stored as the light it leaves, as Adobe's programs write it.
fn inkToLight(ink: u8, black: u8, inverted: bool) u8 {
    const i: u32 = if (inverted) ink else 255 - ink;
    const k: u32 = if (inverted) black else 255 - black;
    return @intCast((i * k + 127) / 255);
}

// -------------------------------------------------------------------------
// Exif's orientation
// -------------------------------------------------------------------------

/// The orientation tag of the TIFF block an Exif segment holds, if it has
/// one that makes sense.
fn exifOrientation(tiff: []const u8) ?u8 {
    if (tiff.len < 8) return null;
    const endian: std.builtin.Endian = if (std.mem.eql(u8, tiff[0..2], "II")) .little else if (std.mem.eql(u8, tiff[0..2], "MM")) .big else return null;
    const first = std.mem.readInt(u32, tiff[4..8], endian);
    if (first > tiff.len or tiff.len - first < 2) return null;
    const entries = std.mem.readInt(u16, tiff[first..][0..2], endian);
    for (0..entries) |i| {
        const at = first + 2 + i * 12;
        if (at + 12 > tiff.len) return null;
        const entry = tiff[at..][0..12];
        if (std.mem.readInt(u16, entry[0..2], endian) != 0x0112) continue;
        // A SHORT, whose value sits in the first two bytes of the four.
        if (std.mem.readInt(u16, entry[2..4], endian) != 3) return null;
        const value = std.mem.readInt(u16, entry[8..10], endian);
        return if (value >= 1 and value <= 8) @intCast(value) else null;
    }
    return null;
}

/// The picture turned or flipped as Exif's orientation says it was taken:
/// 2 mirrored, 3 turned half round, 4 upside down, 5 mirrored along the
/// diagonal, 6 turned a quarter clockwise, 7 mirrored along the other
/// diagonal, 8 turned a quarter the other way.
fn orient(gpa: Allocator, picture: Decoded, orientation: u8) Allocator.Error!Decoded {
    const w = picture.width;
    const h = picture.height;
    const swapped = orientation >= 5;
    const out_width = if (swapped) h else w;
    const out_height = if (swapped) w else h;
    const pixels = try gpa.alloc(u8, @as(usize, w) * h * 4);
    for (0..out_height) |y| for (0..out_width) |x| {
        const from: [2]usize = switch (orientation) {
            2 => .{ w - 1 - x, y },
            3 => .{ w - 1 - x, h - 1 - y },
            4 => .{ x, h - 1 - y },
            5 => .{ y, x },
            6 => .{ y, h - 1 - x },
            7 => .{ w - 1 - y, h - 1 - x },
            8 => .{ w - 1 - y, x },
            else => .{ x, y },
        };
        const source = (from[1] * w + from[0]) * 4;
        const target = (y * out_width + x) * 4;
        @memcpy(pixels[target..][0..4], picture.pixels[source..][0..4]);
    };
    return .{ .width = out_width, .height = out_height, .pixels = pixels };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// Every test picture, and what libjpeg read from it: they differ by little
/// more than the rounding of two inverse DCTs.
fn expectLikeLibjpeg(comptime name: []const u8) !void {
    const file = @embedFile("testdata/" ++ name ++ ".jpg");
    const reference = @embedFile("testdata/" ++ name ++ ".png");
    var got = try decode(testing.allocator, file);
    defer got.deinit(testing.allocator);
    var want = try png.decode(testing.allocator, reference);
    defer want.deinit(testing.allocator);
    try testing.expectEqual(want.width, got.width);
    try testing.expectEqual(want.height, got.height);
    var worst: u8 = 0;
    var total: u64 = 0;
    for (got.pixels, want.pixels, 0..) |a, b, i| {
        if (i % 4 == 3) {
            try testing.expectEqual(@as(u8, 255), a);
            continue;
        }
        const apart = if (a > b) a - b else b - a;
        worst = @max(worst, apart);
        total += apart;
    }
    const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(got.width * got.height * 3));
    if (worst > 4 or mean > 0.25) {
        std.debug.print("{s}: {d} apart at worst, {d:.3} on average\n", .{ name, worst, mean });
        return error.TestUnexpectedResult;
    }
}

test "baseline files, with the colour kept whole, halved across, and halved both ways" {
    try expectLikeLibjpeg("baseline_444");
    try expectLikeLibjpeg("baseline_422");
    try expectLikeLibjpeg("baseline_420");
}

test "progressive files, their bands and bits in several scans" {
    try expectLikeLibjpeg("progressive_420");
    try expectLikeLibjpeg("progressive_444");
}

test "restart markers, in a baseline file and a progressive one" {
    try expectLikeLibjpeg("restart_420");
    try expectLikeLibjpeg("progressive_restart");
}

test "grey files, and CMYK stored inverted as Adobe's programs write it" {
    try expectLikeLibjpeg("grey");
    try expectLikeLibjpeg("grey_progressive");
    try expectLikeLibjpeg("cmyk");
}

test "a photo stored on its side comes out as Exif says it was taken" {
    try expectLikeLibjpeg("orientation_6");
    try expectLikeLibjpeg("orientation_3");
    var turned = try decode(testing.allocator, @embedFile("testdata/orientation_6.jpg"));
    defer turned.deinit(testing.allocator);
    // Stored 23 across and 37 down; shown 37 across.
    try testing.expectEqual(@as(u32, 37), turned.width);
    try testing.expectEqual(@as(u32, 23), turned.height);
}

test "what is not a JPEG, or not one this reads, is said by name" {
    const file = @embedFile("testdata/baseline_420.jpg");
    try testing.expectError(error.NotAJpeg, decode(testing.allocator, "GIF89a"));
    try testing.expectError(error.NotAJpeg, decode(testing.allocator, &png.signature));

    // Cut off before its first scan: nothing to show.
    try testing.expectError(error.Truncated, decode(testing.allocator, file[0..200]));

    // Cut off inside it: what arrived.
    var part = try decode(testing.allocator, file[0 .. file.len - 300]);
    defer part.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 37), part.width);

    // Arithmetic coding, and twelve bits a sample.
    var changed = try testing.allocator.dupe(u8, file);
    defer testing.allocator.free(changed);
    const frame = std.mem.indexOf(u8, changed, &.{ 0xFF, 0xC0 }).?;
    changed[frame + 1] = 0xC9;
    try testing.expectError(error.UnsupportedCoding, decode(testing.allocator, changed));
    changed[frame + 1] = 0xC0;
    changed[frame + 4] = 12;
    try testing.expectError(error.UnsupportedPrecision, decode(testing.allocator, changed));

    // A picture bigger than the caller will take.
    changed[frame + 4] = 8;
    try testing.expectError(error.ImageTooLarge, decodeWith(testing.allocator, changed, .{ .max_pixels = 100 }));
}

test "an Exif orientation is read in either byte order, and nonsense is none" {
    const little = "II*\x00\x08\x00\x00\x00\x01\x00\x12\x01\x03\x00\x01\x00\x00\x00\x06\x00\x00\x00";
    const big = "MM\x00*\x00\x00\x00\x08\x00\x01\x01\x12\x00\x03\x00\x00\x00\x01\x00\x08\x00\x00";
    try testing.expectEqual(@as(?u8, 6), exifOrientation(little));
    try testing.expectEqual(@as(?u8, 8), exifOrientation(big));
    try testing.expectEqual(@as(?u8, null), exifOrientation("II*\x00\xff\x00\x00\x00"));
    try testing.expectEqual(@as(?u8, null), exifOrientation("XX"));
}
