// SPDX-License-Identifier: BSD-2-Clause

//! Fluxion Image - pixels, and the files they travel in.
//!
//! Two pieces, and one door into both:
//!
//!   `png`   A PNG, read and written: a frame saved so it can be looked at,
//!           and a texture loaded so it can be drawn.
//!   `jpeg`  A JPEG, read and written: a photo or a painting as a texture,
//!           and a screenshot small enough to keep.
//!
//!   `decode` and `readFile` read either, whichever the file's first bytes
//!   say it is - not its name, which a person can get wrong.
//!
//! ```zig
//! // Out, to be looked at.
//! try image.png.writeFile(gpa, io, "frame.png", .{
//!     .width = 960,
//!     .height = 540,
//!     .pixels = pixels,          // RGBA, eight bits a channel
//!     .row_pitch = 960 * 4,
//!     .origin = .bottom_left,    // what glReadPixels hands back
//! }, .{});
//!
//! // In, to be drawn: a PNG or a JPEG.
//! var atlas = try image.readFile(gpa, io, "atlas.png", .{});
//! defer atlas.deinit(gpa);
//! const texture = try device.createTexture(.{
//!     .width = atlas.width,
//!     .height = atlas.height,
//!     .data = atlas.pixels,
//! });
//! ```
//!
//! **A frame is not one shape.** OpenGL reads pixels back bottom row first;
//! Direct3D and Vulkan top row first. A driver pads rows to suit itself, so
//! the distance from one row to the next is a fact the caller knows and this
//! library does not guess. Both are fields of `Image`, and a program that
//! knows which GPU it is talking to fills them in once.
//!
//! **What comes back from a file is one shape.** RGBA, eight bits a channel,
//! top row first, tightly packed - whatever the file held. That is what a
//! texture wants, and a caller that had to branch on what an exporter chose
//! would be doing the decoder's job.
//!
//! Nothing here allocates except through the allocator it is handed. What
//! `encode` takes it borrows; what `decode` returns it owns, until `deinit`.

const std = @import("std");

pub const png = @import("png.zig");
pub const jpeg = @import("jpeg.zig");

/// A rectangle of pixels somebody else owns. See `png`.
pub const Image = png.Image;

/// Which corner row zero is. See `png`.
pub const Origin = png.Origin;

/// How the bytes of a pixel are laid out. See `png`.
pub const Format = png.Format;

/// A picture read from a file, and the memory it lives in. See `png`.
pub const Decoded = png.Decoded;

/// Everything reading one can fail with: a PNG's troubles, a JPEG's, and a
/// file that is neither.
pub const DecodeError = png.DecodeError || jpeg.DecodeError || error{
    /// The first bytes are neither a PNG's nor a JPEG's.
    UnknownFormat,
};

/// How far to trust a file this program did not write. See `png`.
pub const DecodeOptions = png.DecodeOptions;

/// The kinds of file `decode` reads.
pub const Kind = enum { png, jpeg };

/// What a file's first bytes say it is, if it is one `decode` reads.
pub fn kindOf(bytes: []const u8) ?Kind {
    if (std.mem.startsWith(u8, bytes, &png.signature)) return .png;
    if (std.mem.startsWith(u8, bytes, &jpeg.signature)) return .jpeg;
    return null;
}

/// Read a PNG or a JPEG. The caller owns what comes back and frees it with
/// `deinit`.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) DecodeError!Decoded {
    return decodeWith(gpa, bytes, .{});
}

pub fn decodeWith(gpa: std.mem.Allocator, bytes: []const u8, options: DecodeOptions) DecodeError!Decoded {
    return switch (kindOf(bytes) orelse return error.UnknownFormat) {
        .png => png.decodeWith(gpa, bytes, options),
        .jpeg => jpeg.decodeWith(gpa, bytes, options),
    };
}

/// Read the file at `path`, a PNG or a JPEG, and decode it.
pub fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8, options: DecodeOptions) !Decoded {
    // Four bytes a pixel would not reach this compressed, and a file bigger
    // than it is not a texture.
    const limit: std.Io.Limit = .limited64(@min(options.max_pixels * 4, std.math.maxInt(usize)));
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, limit);
    defer gpa.free(bytes);
    return decodeWith(gpa, bytes, options);
}

test "either kind of file is read by what it starts with" {
    const gpa = std.testing.allocator;
    var photo = try decode(gpa, @embedFile("testdata/baseline_420.jpg"));
    defer photo.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 37), photo.width);
    var drawing = try decode(gpa, @embedFile("testdata/baseline_420.png"));
    defer drawing.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 37), drawing.width);
    try std.testing.expectEqual(Kind.jpeg, kindOf(@embedFile("testdata/grey.jpg")).?);
    try std.testing.expectError(error.UnknownFormat, decode(gpa, "BM6\x00"));
}

test {
    _ = png;
    _ = jpeg;
    _ = @import("jpeg_write.zig");
}
