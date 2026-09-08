// SPDX-License-Identifier: BSD-2-Clause

//! Reading and writing a PNG.
//!
//! ```zig
//! try png.writeFile(gpa, io, "frame.png", .{
//!     .width = width,
//!     .height = height,
//!     .pixels = pixels,
//!     .row_pitch = pitch,
//!     .origin = .bottom_left,
//! }, .{});
//!
//! var texture = try png.readFile(gpa, io, "atlas.png", .{});
//! defer texture.deinit(gpa);
//! ```
//!
//! **The two halves are not the same size, and should not be.** Writing one
//! is the minimum the format needs: one `IHDR`, one `IDAT` holding a zlib
//! stream of the rows, one `IEND`, a CRC on each, and every row prefixed with
//! a zero to say it was not predicted from the one above. Reading one is
//! reading what somebody else's exporter produced - a palette, four bits an
//! index, a `tRNS` table, and a different filter on every row - and there is
//! no choosing not to.
//!
//! **What comes out is always RGBA, eight bits a channel, top row first.**
//! Whatever the file held. A caller that had to branch on whether a picture
//! happened to be greyscale would be doing the decoder's job, and that one
//! shape is what `createTexture` takes.
//!
//! **The alpha is dropped on the way out unless asked for.** A frame read
//! back from a swap chain is opaque, and three channels is a quarter less to
//! compress. A program that wants the alpha - a sprite atlas, a mask - says
//! so with `keep_alpha`, and gets colour type 6.
//!
//! **Interlacing is refused by name.** Adam7 splits a picture into seven
//! passes of scattered pixels, and a decoder for it is most of a second
//! decoder. Almost nothing writes one on purpose, and `error.UnsupportedInterlace`
//! is a better answer than a picture with holes in it.
//!
//! **The CRC is fluxion-hash's.** PNG's is CRC-32 with the IEEE polynomial,
//! which is the one everything means by CRC-32, so there is no reason to
//! carry a second table - and having it means a damaged file can be told from
//! a picture with a stripe through it.

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
// Reading
// -------------------------------------------------------------------------

/// A decoded picture, and the memory it lives in.
pub const Decoded = struct {
    width: u32,
    height: u32,
    /// RGBA, eight bits a channel, top row first, tightly packed - whatever
    /// the file happened to hold. One shape out, because a caller that has to
    /// branch on whether a file was greyscale or palettised is doing the
    /// decoder's job, and because that shape is what `createTexture` takes.
    pixels: []u8,

    pub fn deinit(self: *Decoded, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }

    /// This, as something `encode` will take.
    pub fn image(self: Decoded) Image {
        return .{
            .width = self.width,
            .height = self.height,
            .pixels = self.pixels,
            .row_pitch = @as(usize, self.width) * 4,
        };
    }

    pub fn at(self: Decoded, x: u32, y: u32) [4]u8 {
        return self.pixels[(@as(usize, y) * self.width + x) * 4 ..][0..4].*;
    }
};

pub const DecodeError = error{
    /// The first eight bytes are not a PNG's.
    NotAPng,
    /// A chunk says it is longer than what is left.
    Truncated,
    /// A chunk's CRC is not the CRC of the chunk.
    BadChecksum,
    /// A header that describes no picture: no width, no height, or a bit
    /// depth that colour type is not allowed to have.
    BadHeader,
    /// A colour type this does not read. There are five, and it reads five;
    /// this is a file claiming a sixth.
    UnsupportedColour,
    /// Adam7. See the module comment.
    UnsupportedInterlace,
    /// A row that begins with a filter number the format does not have.
    BadFilter,
    /// A palettised picture with no palette in it.
    MissingPalette,
    /// No `IDAT` at all.
    MissingImageData,
    /// The compressed data did not decompress, or decompressed to the wrong
    /// number of bytes, or an index reached past the palette.
    CorruptImageData,
    /// The header claims more pixels than `DecodeOptions.max_pixels`.
    ImageTooLarge,
} || std.mem.Allocator.Error;

pub const DecodeOptions = struct {
    /// The most pixels this will decode.
    ///
    /// A PNG says how big it is in its first chunk, and a file this program
    /// did not write is entitled to claim four billion pixels a side. The
    /// default is generous for a texture and small enough that a claim like
    /// that fails at once, rather than after the allocator has tried to find
    /// sixty-eight gigabytes.
    max_pixels: u64 = 64 << 20,
    /// Check every chunk against its CRC. On, because it is one pass over
    /// bytes that are already in cache and it turns a damaged file into a
    /// message rather than into a picture with a stripe through it.
    verify_checksums: bool = true,
};

/// Read a PNG. The caller owns what comes back and frees it with `deinit`.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) DecodeError!Decoded {
    return decodeWith(gpa, bytes, .{});
}

pub fn decodeWith(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    options: DecodeOptions,
) DecodeError!Decoded {
    var chunks: Chunks = try Chunks.begin(bytes, options.verify_checksums);
    const header = try readHeader(&chunks);

    if (header.interlace != 0) return error.UnsupportedInterlace;
    const pixels = @as(u64, header.width) * header.height;
    if (pixels > options.max_pixels) return error.ImageTooLarge;
    if (pixels * 4 > std.math.maxInt(usize)) return error.ImageTooLarge;

    var palette: [256][3]u8 = undefined;
    var palette_len: usize = 0;
    var alphas: [256]u8 = @splat(255);
    var alphas_len: usize = 0;
    var transparent: ?[3]u16 = null;

    var compressed: std.ArrayListUnmanaged(u8) = .empty;
    defer compressed.deinit(gpa);

    while (try chunks.next()) |chunk| {
        if (std.mem.eql(u8, chunk.kind, "IEND")) break;
        if (std.mem.eql(u8, chunk.kind, "IDAT")) {
            try compressed.appendSlice(gpa, chunk.data);
        } else if (std.mem.eql(u8, chunk.kind, "PLTE")) {
            if (chunk.data.len % 3 != 0 or chunk.data.len > 256 * 3) return error.CorruptImageData;
            palette_len = chunk.data.len / 3;
            for (0..palette_len) |i| palette[i] = chunk.data[i * 3 ..][0..3].*;
        } else if (std.mem.eql(u8, chunk.kind, "tRNS")) {
            switch (header.colour) {
                .palette => {
                    if (chunk.data.len > 256) return error.CorruptImageData;
                    alphas_len = chunk.data.len;
                    @memcpy(alphas[0..alphas_len], chunk.data);
                },
                // One colour, at the file's own bit depth, that stands for
                // nothing being there.
                .grey => {
                    if (chunk.data.len < 2) return error.CorruptImageData;
                    const v = std.mem.readInt(u16, chunk.data[0..2], .big);
                    transparent = .{ v, v, v };
                },
                .rgb => {
                    if (chunk.data.len < 6) return error.CorruptImageData;
                    transparent = .{
                        std.mem.readInt(u16, chunk.data[0..2], .big),
                        std.mem.readInt(u16, chunk.data[2..4], .big),
                        std.mem.readInt(u16, chunk.data[4..6], .big),
                    };
                },
                // The two that already carry an alpha channel may not also
                // name a transparent colour, and a file that does is wrong
                // rather than ambiguous.
                .grey_alpha, .rgba => return error.CorruptImageData,
            }
        }
        // Everything else - gamma, text, physical dimensions, the colour
        // space - is ancillary, and a decoder that only wants the pixels
        // walks past it.
    }

    if (compressed.items.len == 0) return error.MissingImageData;
    if (header.colour == .palette and palette_len == 0) return error.MissingPalette;

    const stride = rowBytes(header);
    const wanted = (stride + 1) * @as(usize, header.height);

    const raw = inflate(gpa, compressed.items, wanted) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CorruptImageData,
    };
    defer gpa.free(raw);
    if (raw.len != wanted) return error.CorruptImageData;

    try unfilter(header, raw, stride);

    const out = try gpa.alloc(u8, @intCast(pixels * 4));
    errdefer gpa.free(out);
    try expand(header, palette[0..palette_len], alphas[0..alphas_len], transparent, raw, stride, out);

    return .{ .width = header.width, .height = header.height, .pixels = out };
}

/// How big a PNG says it is, without decoding it. Reads the first chunk and
/// stops.
pub fn size(bytes: []const u8) DecodeError!struct { width: u32, height: u32 } {
    var chunks: Chunks = try Chunks.begin(bytes, false);
    const header = try readHeader(&chunks);
    return .{ .width = header.width, .height = header.height };
}

/// Read a PNG from a file.
pub fn readFile(
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    options: DecodeOptions,
) !Decoded {
    // Four bytes a pixel compressed to nothing would still not reach this,
    // and a file bigger than it is not a texture.
    const limit: Io.Limit = .limited64(@min(options.max_pixels * 4, std.math.maxInt(usize)));
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, limit);
    defer gpa.free(bytes);
    return decodeWith(gpa, bytes, options);
}

// -------------------------------------------------------------------------
// The parts of reading one
// -------------------------------------------------------------------------

const Colour = enum(u8) {
    grey = 0,
    rgb = 2,
    palette = 3,
    grey_alpha = 4,
    rgba = 6,

    /// Samples per pixel in the file, which is not four until this is done
    /// with it.
    fn channels(self: Colour) u32 {
        return switch (self) {
            .grey, .palette => 1,
            .grey_alpha => 2,
            .rgb => 3,
            .rgba => 4,
        };
    }

    /// Which bit depths the format lets this colour type have. Not every
    /// combination exists: there is no sixteen-bit palette, and no
    /// four-bit truecolour.
    fn allows(self: Colour, depth: u8) bool {
        return switch (self) {
            .grey => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
            .palette => depth == 1 or depth == 2 or depth == 4 or depth == 8,
            .rgb, .grey_alpha, .rgba => depth == 8 or depth == 16,
        };
    }
};

const Header = struct {
    width: u32,
    height: u32,
    depth: u8,
    colour: Colour,
    interlace: u8,
};

const Chunk = struct {
    kind: []const u8,
    data: []const u8,
};

/// A cursor over the chunks, which is all a PNG is after its signature.
const Chunks = struct {
    bytes: []const u8,
    at: usize,
    verify: bool,

    fn begin(bytes: []const u8, verify: bool) DecodeError!Chunks {
        if (bytes.len < signature.len) return error.NotAPng;
        if (!std.mem.eql(u8, bytes[0..signature.len], &signature)) return error.NotAPng;
        return .{ .bytes = bytes, .at = signature.len, .verify = verify };
    }

    fn next(self: *Chunks) DecodeError!?Chunk {
        if (self.at >= self.bytes.len) return null;
        // Four of length, four of type, and four of CRC, whatever is between.
        if (self.bytes.len - self.at < 12) return error.Truncated;
        const length = std.mem.readInt(u32, self.bytes[self.at..][0..4], .big);
        if (length > self.bytes.len - self.at - 12) return error.Truncated;

        const kind = self.bytes[self.at + 4 ..][0..4];
        const data = self.bytes[self.at + 8 ..][0..length];

        if (self.verify) {
            var crc: hashing.Crc32 = .init();
            crc.update(kind);
            crc.update(data);
            const stated = std.mem.readInt(u32, self.bytes[self.at + 8 + length ..][0..4], .big);
            if (crc.final() != stated) return error.BadChecksum;
        }

        self.at += 12 + length;
        return .{ .kind = kind, .data = data };
    }
};

/// The first chunk, which the format requires to be `IHDR`.
fn readHeader(chunks: *Chunks) DecodeError!Header {
    const first = (try chunks.next()) orelse return error.Truncated;
    if (!std.mem.eql(u8, first.kind, "IHDR") or first.data.len < 13) return error.BadHeader;

    const width = std.mem.readInt(u32, first.data[0..4], .big);
    const height = std.mem.readInt(u32, first.data[4..8], .big);
    const depth = first.data[8];
    const colour = std.enums.fromInt(Colour, first.data[9]) orelse return error.UnsupportedColour;
    // Byte ten is the compression method and byte eleven the filter method,
    // and the format has exactly one of each.
    if (first.data[10] != 0 or first.data[11] != 0) return error.BadHeader;

    if (width == 0 or height == 0) return error.BadHeader;
    if (!colour.allows(depth)) return error.BadHeader;

    return .{
        .width = width,
        .height = height,
        .depth = depth,
        .colour = colour,
        .interlace = first.data[12],
    };
}

/// Bytes in one row of samples, before the filter byte in front of it.
fn rowBytes(header: Header) usize {
    const bits = @as(usize, header.width) * header.colour.channels() * header.depth;
    return (bits + 7) / 8;
}

/// How far back a filter looks: one whole pixel, or one byte where a pixel
/// is narrower than that.
fn bytesPerPixel(header: Header) usize {
    const bits = @as(usize, header.colour.channels()) * header.depth;
    return @max(1, bits / 8);
}

fn inflate(gpa: std.mem.Allocator, compressed: []const u8, wanted: usize) ![]u8 {
    var reader: Io.Reader = .fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var stream: std.compress.flate.Decompress = .init(&reader, .zlib, &window);
    // Bounded: the header already said how many bytes this has to be, so a
    // stream that keeps producing them is a stream to stop reading.
    return stream.reader.allocRemaining(gpa, .limited(wanted + 1));
}

/// Undo the per-row prediction, in place.
///
/// Each row carries the number of the filter it was written with, and each
/// filter is defined against the byte one pixel to the left, the byte above,
/// and the byte above and to the left. The first row has nothing above it,
/// which is the same as a row of zeroes.
fn unfilter(header: Header, raw: []u8, stride: usize) DecodeError!void {
    const bpp = bytesPerPixel(header);
    var previous: []const u8 = &.{};

    for (0..header.height) |y| {
        const start = y * (stride + 1);
        const filter = raw[start];
        const row = raw[start + 1 ..][0..stride];

        switch (filter) {
            0 => {},
            1 => for (bpp..stride) |i| {
                row[i] +%= row[i - bpp];
            },
            2 => if (previous.len != 0) {
                for (0..stride) |i| row[i] +%= previous[i];
            },
            3 => for (0..stride) |i| {
                const left: u16 = if (i >= bpp) row[i - bpp] else 0;
                const up: u16 = if (previous.len != 0) previous[i] else 0;
                row[i] +%= @intCast((left + up) / 2);
            },
            4 => for (0..stride) |i| {
                const left: u8 = if (i >= bpp) row[i - bpp] else 0;
                const up: u8 = if (previous.len != 0) previous[i] else 0;
                const corner: u8 = if (i >= bpp and previous.len != 0) previous[i - bpp] else 0;
                row[i] +%= paeth(left, up, corner);
            },
            else => return error.BadFilter,
        }
        previous = row;
    }
}

/// The predictor from the specification: whichever of the three neighbours
/// is nearest to their linear combination.
fn paeth(left: u8, up: u8, corner: u8) u8 {
    const estimate = @as(i32, left) + @as(i32, up) - @as(i32, corner);
    const to_left = @abs(estimate - @as(i32, left));
    const to_up = @abs(estimate - @as(i32, up));
    const to_corner = @abs(estimate - @as(i32, corner));
    if (to_left <= to_up and to_left <= to_corner) return left;
    if (to_up <= to_corner) return up;
    return corner;
}

/// One sample as the file stored it, at whatever width that was.
fn rawSample(row: []const u8, index: usize, depth: u8) u16 {
    return switch (depth) {
        1 => (row[index >> 3] >> @intCast(7 - (index & 7))) & 1,
        2 => (row[index >> 2] >> @intCast(6 - 2 * (index & 3))) & 3,
        4 => (row[index >> 1] >> @intCast(if (index & 1 == 0) @as(u3, 4) else 0)) & 15,
        8 => row[index],
        16 => std.mem.readInt(u16, row[index * 2 ..][0..2], .big),
        else => unreachable,
    };
}

/// That sample as one byte, spread over the whole range rather than left at
/// the bottom of it: a one-bit white is 255 and not 1.
fn toByte(sample: u16, depth: u8) u8 {
    return switch (depth) {
        1 => if (sample != 0) 255 else 0,
        2 => @intCast(sample * 85),
        4 => @intCast(sample * 17),
        8 => @intCast(sample),
        // The low byte of a sixteen-bit sample is below what eight bits can
        // hold, and dropping it is what every renderer does with one.
        16 => @intCast(sample >> 8),
        else => unreachable,
    };
}

/// Whatever the file held, as RGBA.
fn expand(
    header: Header,
    palette: []const [3]u8,
    alphas: []const u8,
    transparent: ?[3]u16,
    raw: []const u8,
    stride: usize,
    out: []u8,
) DecodeError!void {
    const channels = header.colour.channels();
    const depth = header.depth;

    for (0..header.height) |y| {
        const row = raw[y * (stride + 1) + 1 ..][0..stride];
        const line = out[y * header.width * 4 ..][0 .. header.width * 4];

        for (0..header.width) |x| {
            const base = x * channels;
            var rgba: [4]u8 = .{ 0, 0, 0, 255 };

            switch (header.colour) {
                .grey, .grey_alpha => {
                    const grey = rawSample(row, base, depth);
                    const v = toByte(grey, depth);
                    rgba = .{ v, v, v, 255 };
                    if (header.colour == .grey_alpha) {
                        rgba[3] = toByte(rawSample(row, base + 1, depth), depth);
                    } else if (transparent) |t| {
                        if (grey == t[0]) rgba[3] = 0;
                    }
                },
                .rgb, .rgba => {
                    const r = rawSample(row, base, depth);
                    const g = rawSample(row, base + 1, depth);
                    const b = rawSample(row, base + 2, depth);
                    rgba = .{ toByte(r, depth), toByte(g, depth), toByte(b, depth), 255 };
                    if (header.colour == .rgba) {
                        rgba[3] = toByte(rawSample(row, base + 3, depth), depth);
                    } else if (transparent) |t| {
                        if (r == t[0] and g == t[1] and b == t[2]) rgba[3] = 0;
                    }
                },
                .palette => {
                    const index = rawSample(row, base, depth);
                    if (index >= palette.len) return error.CorruptImageData;
                    const entry = palette[index];
                    rgba = .{
                        entry[0],
                        entry[1],
                        entry[2],
                        if (index < alphas.len) alphas[index] else 255,
                    };
                },
            }

            line[x * 4 ..][0..4].* = rgba;
        }
    }
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
    var stream: std.compress.flate.Decompress = .init(&reader, .zlib, &window);
    return stream.reader.allocRemaining(gpa, .unlimited);
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

// -------------------------------------------------------------------------
// Tests: reading
//
// Three of these read files another program wrote: Python's zlib did the
// compressing, and the filters were applied a second time from the
// specification rather than from the code above. So what they check is the
// decoder against the format, and not the decoder against the encoder in this
// same file.
// -------------------------------------------------------------------------

/// Four by four, RGB, written elsewhere with a different filter on each row:
/// Sub, Up, Average and Paeth, in that order.
const rgb_every_filter = [_]u8{
    137, 80,  78,  71,  13,  10,  26, 10, 0,  0,  0,  13,  73,  72,  68,
    82,  0,   0,   0,   4,   0,   0,  0,  4,  8,  2,  0,   0,   0,   38,
    147, 9,   41,  0,   0,   0,   34, 73, 68, 65, 84, 120, 218, 99,  228,
    18,  97,  181, 97,  144, 131, 32, 38, 6,  27, 57, 56,  98,  102, 77,
    49,  144, 131, 1,   22,  144, 24, 3,  20, 1,  0,  138, 98,  4,   255,
    222, 247, 225, 119, 0,   0,   0,  0,  73, 69, 78, 68,  174, 66,  96,
    130,
};

/// Four by two, a four-bit palette, and a `tRNS` that leaves the first entry
/// opaque, makes the second half transparent and the third invisible.
const palette_four_bit = [_]u8{
    137, 80,  78, 71,  13,  10,  26,  10,  0,   0,   0,   13,  73, 72, 68,
    82,  0,   0,  0,   4,   0,   0,   0,   2,   4,   3,   0,   0,  0,  141,
    134, 96,  80, 0,   0,   0,   12,  80,  76,  84,  69,  255, 0,  0,  0,
    255, 0,   0,  0,   255, 40,  40,  40,  165, 8,   87,  236, 0,  0,  0,
    3,   116, 82, 78,  83,  255, 128, 0,   127, 109, 104, 120, 0,  0,  0,
    14,  73,  68, 65,  84,  120, 218, 99,  96,  84,  102, 48,  18, 0,  0,
    1,   11,  0,  103, 71,  140, 142, 203, 0,   0,   0,   0,   73, 69, 78,
    68,  174, 66, 96,  130,
};

/// Two by two, sixteen bits of grey a pixel.
const grey_sixteen_bit = [_]u8{
    137, 80,  78,  71,  13,  10,  26,  10,  0,  0,  0,  13,  73,  72,  68,
    82,  0,   0,   0,   2,   0,   0,   0,   2,  16, 0,  0,   0,   0,   7,
    77,  142, 187, 0,   0,   0,   18,  73,  68, 65, 84, 120, 218, 99,  248,
    255, 191, 129, 129, 129, 145, 137, 129, 1,  0,  20, 131, 2,   130, 196,
    242, 148, 231, 0,   0,   0,   0,   73,  69, 78, 68, 174, 66,  96,  130,
};

/// Building a PNG by hand, for the cases no encoder would produce.
const Builder = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayListUnmanaged(u8) = .empty,

    fn init(gpa: std.mem.Allocator) !Builder {
        var self: Builder = .{ .gpa = gpa };
        try self.bytes.appendSlice(gpa, &signature);
        return self;
    }

    fn deinit(self: *Builder) void {
        self.bytes.deinit(self.gpa);
    }

    fn chunk(self: *Builder, kind: []const u8, payload: []const u8) !void {
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(payload.len), .big);
        try self.bytes.appendSlice(self.gpa, &length);
        try self.bytes.appendSlice(self.gpa, kind);
        try self.bytes.appendSlice(self.gpa, payload);

        var crc: hashing.Crc32 = .init();
        crc.update(kind);
        crc.update(payload);
        var check: [4]u8 = undefined;
        std.mem.writeInt(u32, &check, crc.final(), .big);
        try self.bytes.appendSlice(self.gpa, &check);
    }

    fn header(self: *Builder, w: u32, h: u32, depth: u8, colour: u8, interlace: u8) !void {
        var ihdr: [13]u8 = undefined;
        std.mem.writeInt(u32, ihdr[0..4], w, .big);
        std.mem.writeInt(u32, ihdr[4..8], h, .big);
        ihdr[8] = depth;
        ihdr[9] = colour;
        ihdr[10] = 0;
        ihdr[11] = 0;
        ihdr[12] = interlace;
        try self.chunk("IHDR", &ihdr);
    }

    /// The rows, filter bytes and all, deflated and written as `pieces`
    /// `IDAT` chunks - because the format lets a writer split them wherever
    /// it likes, and a reader has to join them back.
    fn data(self: *Builder, raw: []const u8, pieces: usize) !void {
        const scratch = try self.gpa.alloc(u8, raw.len + 4096);
        defer self.gpa.free(scratch);
        var out: Io.Writer = .fixed(scratch);

        const window = try self.gpa.alloc(u8, std.compress.flate.max_window_len);
        defer self.gpa.free(window);
        var compress: std.compress.flate.Compress = try .init(&out, window, .zlib, .default);
        try compress.writer.writeAll(raw);
        try compress.finish();

        const all = out.buffered();
        const per = (all.len + pieces - 1) / pieces;
        var at: usize = 0;
        while (at < all.len) {
            const end = @min(at + per, all.len);
            try self.chunk("IDAT", all[at..end]);
            at = end;
        }
    }

    fn finish(self: *Builder) ![]const u8 {
        try self.chunk("IEND", "");
        return self.bytes.items;
    }
};

test "what the encoder wrote, read back" {
    // Three channels out of four: the alpha the encoder dropped comes back
    // opaque, which is what dropping it meant.
    const written = try encodeAlloc(testing.allocator, .{
        .width = 2,
        .height = 2,
        .pixels = &corners,
        .row_pitch = 8,
    }, .{});
    defer testing.allocator.free(written);

    var picture = try decode(testing.allocator, written);
    defer picture.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 2), picture.width);
    try testing.expectEqual(@as(u32, 2), picture.height);
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, picture.at(0, 0));
    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, picture.at(1, 0));
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, picture.at(0, 1));
    try testing.expectEqual([4]u8{ 9, 9, 9, 255 }, picture.at(1, 1));
}

test "an alpha channel survives the trip" {
    const written = try encodeAlloc(testing.allocator, .{
        .width = 2,
        .height = 2,
        .pixels = &corners,
        .row_pitch = 8,
    }, .{ .keep_alpha = true });
    defer testing.allocator.free(written);

    var picture = try decode(testing.allocator, written);
    defer picture.deinit(testing.allocator);
    // The grey corner was written with an alpha of 128 and comes back with it.
    try testing.expectEqual([4]u8{ 9, 9, 9, 128 }, picture.at(1, 1));
}

test "a picture that has been round the houses is the one it started as" {
    var first = try decode(testing.allocator, &rgb_every_filter);
    defer first.deinit(testing.allocator);

    const written = try encodeAlloc(testing.allocator, first.image(), .{ .keep_alpha = true });
    defer testing.allocator.free(written);

    var second = try decode(testing.allocator, written);
    defer second.deinit(testing.allocator);

    try testing.expectEqualSlices(u8, first.pixels, second.pixels);
}

test "every filter is undone" {
    // Sub, Up, Average and Paeth, one to a row, in a file written elsewhere.
    var picture = try decode(testing.allocator, &rgb_every_filter);
    defer picture.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 4), picture.width);
    for (0..4) |y| {
        for (0..4) |x| {
            const expected: [4]u8 = .{
                @intCast(x * 60 + 10),
                @intCast(y * 60 + 20),
                @intCast((x + y) * 30 + 5),
                255,
            };
            try testing.expectEqual(expected, picture.at(@intCast(x), @intCast(y)));
        }
    }
}

test "a palette, four bits an index, with a transparency table" {
    var picture = try decode(testing.allocator, &palette_four_bit);
    defer picture.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 4), picture.width);
    try testing.expectEqual(@as(u32, 2), picture.height);

    // Indices 0, 1, 2, 3 across the top and back again underneath. The tRNS
    // gave the second entry an alpha of 128 and the third one of zero; the
    // fourth had no entry at all and is opaque.
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, picture.at(0, 0));
    try testing.expectEqual([4]u8{ 0, 255, 0, 128 }, picture.at(1, 0));
    try testing.expectEqual([4]u8{ 0, 0, 255, 0 }, picture.at(2, 0));
    try testing.expectEqual([4]u8{ 40, 40, 40, 255 }, picture.at(3, 0));
    try testing.expectEqual([4]u8{ 40, 40, 40, 255 }, picture.at(0, 1));
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, picture.at(3, 1));
}

test "sixteen bits a channel keeps the top eight" {
    var picture = try decode(testing.allocator, &grey_sixteen_bit);
    defer picture.deinit(testing.allocator);

    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, picture.at(0, 0));
    try testing.expectEqual([4]u8{ 128, 128, 128, 255 }, picture.at(1, 0));
    // 0x0102 is one and a bit, and the bit is below what a byte holds.
    try testing.expectEqual([4]u8{ 1, 1, 1, 255 }, picture.at(0, 1));
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, picture.at(1, 1));
}

test "the narrow depths are spread over the whole range" {
    // One bit of grey: two pixels, off and on, and on is white rather than
    // one two-hundred-and-fifty-fifth of it.
    var one = try Builder.init(testing.allocator);
    defer one.deinit();
    try one.header(2, 1, 1, 0, 0);
    try one.data(&.{ 0, 0b0100_0000 }, 1);

    var picture = try decode(testing.allocator, try one.finish());
    defer picture.deinit(testing.allocator);
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, picture.at(0, 0));
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, picture.at(1, 0));

    // Four bits: the range is nought to fifteen, and fifteen is white.
    var four = try Builder.init(testing.allocator);
    defer four.deinit();
    try four.header(2, 1, 4, 0, 0);
    try four.data(&.{ 0, 0x0F }, 1);

    var narrow = try decode(testing.allocator, try four.finish());
    defer narrow.deinit(testing.allocator);
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, narrow.at(0, 0));
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, narrow.at(1, 0));
}

test "grey with an alpha channel, and grey with a transparent shade" {
    var pair = try Builder.init(testing.allocator);
    defer pair.deinit();
    try pair.header(2, 1, 8, 4, 0);
    try pair.data(&.{ 0, 200, 255, 100, 0 }, 1);

    var picture = try decode(testing.allocator, try pair.finish());
    defer picture.deinit(testing.allocator);
    try testing.expectEqual([4]u8{ 200, 200, 200, 255 }, picture.at(0, 0));
    try testing.expectEqual([4]u8{ 100, 100, 100, 0 }, picture.at(1, 0));

    // The other way of saying it: one shade that means nothing is there.
    var keyed = try Builder.init(testing.allocator);
    defer keyed.deinit();
    try keyed.header(2, 1, 8, 0, 0);
    try keyed.chunk("tRNS", &.{ 0, 100 });
    try keyed.data(&.{ 0, 200, 100 }, 1);

    var shade = try decode(testing.allocator, try keyed.finish());
    defer shade.deinit(testing.allocator);
    try testing.expectEqual([4]u8{ 200, 200, 200, 255 }, shade.at(0, 0));
    try testing.expectEqual([4]u8{ 100, 100, 100, 0 }, shade.at(1, 0));
}

test "a colour that means nothing is there" {
    var keyed = try Builder.init(testing.allocator);
    defer keyed.deinit();
    try keyed.header(2, 1, 8, 2, 0);
    // Sixteen bits a channel in tRNS, whatever the picture's own depth.
    try keyed.chunk("tRNS", &.{ 0, 255, 0, 0, 0, 0 });
    try keyed.data(&.{ 0, 255, 0, 0, 10, 20, 30 }, 1);

    var picture = try decode(testing.allocator, try keyed.finish());
    defer picture.deinit(testing.allocator);
    try testing.expectEqual([4]u8{ 255, 0, 0, 0 }, picture.at(0, 0));
    try testing.expectEqual([4]u8{ 10, 20, 30, 255 }, picture.at(1, 0));
}

test "the image data may arrive in pieces, and other chunks are walked past" {
    var split = try Builder.init(testing.allocator);
    defer split.deinit();
    try split.header(4, 4, 8, 2, 0);
    // Things a decoder that only wants pixels has no use for.
    try split.chunk("gAMA", &.{ 0, 1, 134, 160 });
    try split.chunk("tEXt", "Software\x00something else");

    var rows: [4 * (1 + 12)]u8 = @splat(0);
    for (0..4) |y| {
        rows[y * 13] = 0;
        for (0..4) |x| {
            rows[y * 13 + 1 + x * 3] = @intCast(x * 60);
            rows[y * 13 + 2 + x * 3] = @intCast(y * 60);
            rows[y * 13 + 3 + x * 3] = 7;
        }
    }
    try split.data(&rows, 3);
    try split.chunk("tIME", &.{ 7, 230, 1, 1, 0, 0, 0 });

    var picture = try decode(testing.allocator, try split.finish());
    defer picture.deinit(testing.allocator);
    try testing.expectEqual([4]u8{ 180, 180, 7, 255 }, picture.at(3, 3));
}

test "how big it is, without decoding it" {
    const measured = try size(&rgb_every_filter);
    try testing.expectEqual(@as(u32, 4), measured.width);
    try testing.expectEqual(@as(u32, 4), measured.height);
    // Which is what makes it worth having: an asset list can be built from
    // the headers alone, without a single pixel being expanded.
    try testing.expectError(error.NotAPng, size("not a png at all"));
}

test "what it refuses, and what it calls each one" {
    const gpa = testing.allocator;

    try testing.expectError(error.NotAPng, decode(gpa, "short"));
    try testing.expectError(error.NotAPng, decode(gpa, &[_]u8{0} ** 32));

    // A chunk that says it is longer than what is left.
    var truncated = try Builder.init(gpa);
    defer truncated.deinit();
    try truncated.header(1, 1, 8, 2, 0);
    const cut = truncated.bytes.items[0 .. truncated.bytes.items.len - 4];
    try testing.expectError(error.Truncated, decode(gpa, cut));

    // One bit flipped in a chunk's data, which is what a CRC is for.
    var damaged = try Builder.init(gpa);
    defer damaged.deinit();
    try damaged.header(1, 1, 8, 2, 0);
    try damaged.data(&.{ 0, 1, 2, 3 }, 1);
    const copy = try gpa.dupe(u8, try damaged.finish());
    defer gpa.free(copy);
    copy[20] ^= 0xFF;
    try testing.expectError(error.BadChecksum, decode(gpa, copy));

    // Adam7.
    var interlaced = try Builder.init(gpa);
    defer interlaced.deinit();
    try interlaced.header(1, 1, 8, 2, 1);
    try interlaced.data(&.{ 0, 1, 2, 3 }, 1);
    try testing.expectError(error.UnsupportedInterlace, decode(gpa, try interlaced.finish()));

    // A colour type the format does not have.
    var invented = try Builder.init(gpa);
    defer invented.deinit();
    try invented.header(1, 1, 8, 5, 0);
    try testing.expectError(error.UnsupportedColour, decode(gpa, try invented.finish()));

    // A depth that colour type is not allowed: there is no sixteen-bit
    // palette.
    var wide = try Builder.init(gpa);
    defer wide.deinit();
    try wide.header(1, 1, 16, 3, 0);
    try testing.expectError(error.BadHeader, decode(gpa, try wide.finish()));

    // No pixels at all.
    var empty = try Builder.init(gpa);
    defer empty.deinit();
    try empty.header(1, 1, 8, 2, 0);
    try testing.expectError(error.MissingImageData, decode(gpa, try empty.finish()));

    // Palettised, with no palette.
    var unpainted = try Builder.init(gpa);
    defer unpainted.deinit();
    try unpainted.header(1, 1, 8, 3, 0);
    try unpainted.data(&.{ 0, 0 }, 1);
    try testing.expectError(error.MissingPalette, decode(gpa, try unpainted.finish()));

    // A filter number the format does not have.
    var strange = try Builder.init(gpa);
    defer strange.deinit();
    try strange.header(1, 1, 8, 2, 0);
    try strange.data(&.{ 9, 1, 2, 3 }, 1);
    try testing.expectError(error.BadFilter, decode(gpa, try strange.finish()));

    // Fewer bytes than the header promised.
    var thin = try Builder.init(gpa);
    defer thin.deinit();
    try thin.header(4, 4, 8, 2, 0);
    try thin.data(&.{ 0, 1, 2, 3 }, 1);
    try testing.expectError(error.CorruptImageData, decode(gpa, try thin.finish()));

    // An index past the end of the palette.
    var out_of_range = try Builder.init(gpa);
    defer out_of_range.deinit();
    try out_of_range.header(1, 1, 8, 3, 0);
    try out_of_range.chunk("PLTE", &.{ 1, 2, 3 });
    try out_of_range.data(&.{ 0, 7 }, 1);
    try testing.expectError(error.CorruptImageData, decode(gpa, try out_of_range.finish()));
}

test "a picture too big to be one is refused before the allocator is asked" {
    var enormous = try Builder.init(testing.allocator);
    defer enormous.deinit();
    // A hundred thousand a side is ten gigapixels, and no texture is that.
    try enormous.header(100_000, 100_000, 8, 2, 0);
    try enormous.data(&.{ 0, 1, 2, 3 }, 1);
    const bytes = try enormous.finish();
    try testing.expectError(error.ImageTooLarge, decode(testing.allocator, bytes));

    // And a caller who means it says so, and gets as far as the pixels not
    // being there.
    try testing.expectError(error.CorruptImageData, decodeWith(testing.allocator, bytes, .{
        .max_pixels = 20 << 30,
    }));
}
