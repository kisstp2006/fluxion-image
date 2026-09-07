// SPDX-License-Identifier: BSD-2-Clause

//! Writing a PNG.
//!
//! The encoder is the minimum a PNG needs: one `IHDR`, one `IDAT` holding a
//! zlib stream of the rows, one `IEND`, and a CRC on each. Every row is
//! prefixed with a zero, which is PNG's way of saying "this row is not
//! predicted from the one above" - the filters that make PNGs small are worth
//! having for a texture pipeline and are not worth having for a screenshot,
//! and this is the screenshot end of the format.
//!
//! ```zig
//! try png.writeFile(gpa, io, "frame.png", .{
//!     .width = width,
//!     .height = height,
//!     .pixels = pixels,
//!     .row_pitch = pitch,
//!     .origin = .bottom_left,
//! });
//! ```
//!
//! **The alpha is dropped unless asked for.** A frame read back from a swap
//! chain is opaque, and three channels is a quarter less to compress. A
//! program that wants the alpha - a sprite atlas, a mask - says so with
//! `keep_alpha`, and gets colour type 6.
//!
//! **The CRC is fluxion-hash's.** PNG's is CRC-32 with the IEEE polynomial,
//! which is the one everything means by CRC-32, so there is no reason to
//! carry a second table.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const hashing = @import("fluxion_hash");

/// Which corner row zero of `pixels` is.
pub const Origin = enum {
    /// Row zero is the top of the picture. Direct3D, Vulkan, every image
    /// file, and PNG itself.
    top_left,
    /// Row zero is the bottom. What `glReadPixels` hands back, because
    /// OpenGL's window coordinates start at the bottom left corner.
    bottom_left,
};

/// How the bytes of one pixel are laid out.
pub const Format = enum {
    /// Red, green, blue, alpha; one byte each.
    rgba8,
    /// Red, green, blue; one byte each.
    rgb8,

    pub fn bytesPerPixel(self: Format) usize {
        return switch (self) {
            .rgba8 => 4,
            .rgb8 => 3,
        };
    }
};

/// A rectangle of pixels somebody else owns.
pub const Image = struct {
    width: u32,
    height: u32,
    /// At least `row_pitch * height` bytes.
    pixels: []const u8,
    /// Bytes from the start of one row to the start of the next. At least
    /// `width * format.bytesPerPixel()`; more where a driver padded its rows,
    /// which is a fact the caller knows and this library does not guess.
    row_pitch: usize,
    format: Format = .rgba8,
    origin: Origin = .top_left,

    /// Bytes in one row of pixels, without any padding after them.
    pub fn rowBytes(self: Image) usize {
        return @as(usize, self.width) * self.format.bytesPerPixel();
    }

    /// Row `y` of the picture, counted from the top, wherever it lives in
    /// `pixels`.
    pub fn row(self: Image, y: usize) []const u8 {
        const index = switch (self.origin) {
            .top_left => y,
            .bottom_left => self.height - 1 - y,
        };
        return self.pixels[index * self.row_pitch ..][0..self.rowBytes()];
    }
};

pub const Options = struct {
    /// Write four channels rather than three. Off for a frame, on for a
    /// texture. Ignored for `rgb8`, which has no alpha to keep.
    keep_alpha: bool = false,
};

pub const Error = error{
    /// `pixels` is shorter than `row_pitch * height`, or a row is narrower
    /// than the width says. Caught here, because the alternative is reading
    /// past the end of the buffer into whatever the driver put after it.
    PixelsTooShort,
    /// `width` or `height` is zero. PNG has no such picture.
    EmptyImage,
} || std.mem.Allocator.Error || Io.Writer.Error;

/// Encode `image` as a PNG into `w`.
pub fn encode(gpa: std.mem.Allocator, w: *Io.Writer, image: Image, options: Options) Error!void {
    if (image.width == 0 or image.height == 0) return error.EmptyImage;
    if (image.row_pitch < image.rowBytes()) return error.PixelsTooShort;
    if (image.pixels.len < image.row_pitch * (image.height - 1) + image.rowBytes()) return error.PixelsTooShort;

    const in_channels = image.format.bytesPerPixel();
    const out_channels: usize = if (image.format == .rgba8 and options.keep_alpha) 4 else 3;

    // The rows, top first, each behind the filter byte PNG puts in front of
    // it, and with the alpha dropped on the way when it is not wanted.
    const row_bytes = 1 + @as(usize, image.width) * out_channels;
    const raw = try gpa.alloc(u8, row_bytes * image.height);
    defer gpa.free(raw);

    for (0..image.height) |y| {
        const destination = raw[y * row_bytes ..][0..row_bytes];
        destination[0] = 0; // filter 0: this row is not predicted from another
        const source = image.row(y);
        if (in_channels == out_channels) {
            @memcpy(destination[1..], source);
        } else {
            for (0..image.width) |x| {
                @memcpy(destination[1 + x * out_channels ..][0..out_channels], source[x * in_channels ..][0..out_channels]);
            }
        }
    }

    // ... deflated, in the zlib wrapper PNG asks for. The sink is sized for
    // the case where compression achieves nothing, which is the only bound
    // that holds for arbitrary pixels.
    const scratch = try gpa.alloc(u8, raw.len + 64 * 1024);
    defer gpa.free(scratch);
    var deflated: Io.Writer = .fixed(scratch);

    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);

    var compress: std.compress.flate.Compress = try .init(&deflated, window, .zlib, .default);
    try compress.writer.writeAll(raw);
    try compress.finish();

    try w.writeAll(&signature);

    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], image.width, .big);
    std.mem.writeInt(u32, header[4..8], image.height, .big);
    header[8] = 8; // bits per channel
    header[9] = if (out_channels == 4) 6 else 2; // colour type: RGBA, or RGB
    header[10] = 0; // the only compression method there is
    header[11] = 0; // the only filter method there is
    header[12] = 0; // not interlaced
    try writeChunk(w, "IHDR", &header);

    try writeChunk(w, "IDAT", deflated.buffered());
    try writeChunk(w, "IEND", "");
}

/// Encode into fresh memory. The caller frees it.
pub fn encodeAlloc(gpa: std.mem.Allocator, image: Image, options: Options) Error![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try encode(gpa, &out.writer, image, options);
    return out.toOwnedSlice();
}

/// Encode straight into a file at `path`, made or truncated.
pub fn writeFile(
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    image: Image,
    options: Options,
) !void {
    var file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var out = file.writer(io, &buffer);
    try encode(gpa, &out.interface, image, options);
    try out.interface.flush();
}

/// The eight bytes every PNG starts with.
pub const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

/// Length, type, data, and a CRC over the type and the data - which is every
/// chunk in the format.
fn writeChunk(w: *Io.Writer, comptime kind: *const [4]u8, data: []const u8) Io.Writer.Error!void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);

    var crc: hashing.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a chunk carries its own length and checksum" {
    var buffer: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try writeChunk(&writer, "IEND", "");

    // Four bytes of length, four of type, no data, four of CRC - and the CRC
    // of an empty IEND is the one every PNG in the world ends with.
    try testing.expectEqualSlices(u8, &.{
        0, 0, 0, 0, 'I', 'E', 'N', 'D', 0xAE, 0x42, 0x60, 0x82,
    }, writer.buffered());
}

/// Two by two, RGBA, with a distinct colour in each corner, top row first.
const corners = [_]u8{
    255, 0, 0, 255, 0, 255, 0, 255, // red, green
    0, 0, 255, 255, 9, 9, 9, 128, // blue, grey
};

test "the header says what the picture is" {
    const bytes = try encodeAlloc(testing.allocator, .{
        .width = 2,
        .height = 2,
        .pixels = &corners,
        .row_pitch = 8,
    }, .{});
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, &signature, bytes[0..8]);
    // IHDR: length 13, then the type.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 13, 'I', 'H', 'D', 'R' }, bytes[8..16]);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, bytes[16..20], .big));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, bytes[20..24], .big));
    try testing.expectEqual(@as(u8, 8), bytes[24]); // bit depth
    try testing.expectEqual(@as(u8, 2), bytes[25]); // RGB

    // And it ends with the IEND every viewer looks for.
    try testing.expectEqualSlices(u8, &.{ 'I', 'E', 'N', 'D', 0xAE, 0x42, 0x60, 0x82 }, bytes[bytes.len - 8 ..]);
}

test "keeping the alpha changes the colour type" {
    const bytes = try encodeAlloc(testing.allocator, .{
        .width = 2,
        .height = 2,
        .pixels = &corners,
        .row_pitch = 8,
    }, .{ .keep_alpha = true });
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(u8, 6), bytes[25]); // RGBA
}

/// The rows as they went into the zlib stream: filter bytes and all.
fn inflateRows(gpa: std.mem.Allocator, png_bytes: []const u8) ![]u8 {
    // The IDAT is the second chunk; its length is at the front of it.
    const idat_at = 8 + 12 + 13;
    const len = std.mem.readInt(u32, png_bytes[idat_at..][0..4], .big);
    try testing.expectEqualSlices(u8, "IDAT", png_bytes[idat_at + 4 ..][0..4]);
    const zlib = png_bytes[idat_at + 8 ..][0..len];

    var reader: Io.Reader = .fixed(zlib);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&reader, .zlib, &window);
    return inflate.reader.allocRemaining(gpa, .unlimited);
}

test "the rows come out top first whichever way they went in" {
    // The same picture handed over twice: once as a file would hold it, once
    // as OpenGL would - bottom row first. Both must encode to the same rows.
    const upright = try encodeAlloc(testing.allocator, .{
        .width = 2,
        .height = 2,
        .pixels = &corners,
        .row_pitch = 8,
    }, .{});
    defer testing.allocator.free(upright);

    const flipped = [_]u8{
        0, 0, 255, 255, 9, 9, 9, 128, // blue, grey - the bottom row, first
        255, 0, 0, 255, 0, 255, 0, 255, // red, green
    };
    const from_gl = try encodeAlloc(testing.allocator, .{
        .width = 2,
        .height = 2,
        .pixels = &flipped,
        .row_pitch = 8,
        .origin = .bottom_left,
    }, .{});
    defer testing.allocator.free(from_gl);

    try testing.expectEqualSlices(u8, upright, from_gl);

    const rows = try inflateRows(testing.allocator, upright);
    defer testing.allocator.free(rows);
    try testing.expectEqualSlices(u8, &.{
        0, 255, 0, 0, 0, 255, 0, // filter, red, green
        0, 0, 0, 255, 9, 9, 9, // filter, blue, grey
    }, rows);
}

test "a padded row pitch is honoured" {
    // Two pixels a row, but sixteen bytes from one row to the next, which is
    // what a driver that pads to sixteen hands back.
    var padded: [32]u8 = @splat(0xEE);
    @memcpy(padded[0..8], corners[0..8]);
    @memcpy(padded[16..24], corners[8..16]);

    const bytes = try encodeAlloc(testing.allocator, .{
        .width = 2,
        .height = 2,
        .pixels = &padded,
        .row_pitch = 16,
    }, .{});
    defer testing.allocator.free(bytes);

    const rows = try inflateRows(testing.allocator, bytes);
    defer testing.allocator.free(rows);
    // None of the padding made it in.
    try testing.expectEqual(null, std.mem.indexOfScalar(u8, rows, 0xEE));
}

test "a buffer that is too short is refused, not read past" {
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.PixelsTooShort, encode(testing.allocator, &sink.writer, .{
        .width = 2,
        .height = 2,
        .pixels = corners[0..15],
        .row_pitch = 8,
    }, .{}));
    try testing.expectError(error.PixelsTooShort, encode(testing.allocator, &sink.writer, .{
        .width = 4,
        .height = 1,
        .pixels = &corners,
        .row_pitch = 8, // narrower than four RGBA pixels
    }, .{}));
    try testing.expectError(error.EmptyImage, encode(testing.allocator, &sink.writer, .{
        .width = 0,
        .height = 2,
        .pixels = &corners,
        .row_pitch = 8,
    }, .{}));
}
