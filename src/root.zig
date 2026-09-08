// SPDX-License-Identifier: BSD-2-Clause

//! Fluxion Image - pixels, and the files they travel in.
//!
//! One piece so far:
//!
//!   `png`  A PNG, read and written: a frame saved so it can be looked at,
//!          and a texture loaded so it can be drawn.
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
//! // In, to be drawn.
//! var atlas = try image.png.readFile(gpa, io, "atlas.png", .{});
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

/// A rectangle of pixels somebody else owns. See `png`.
pub const Image = png.Image;

/// Which corner row zero is. See `png`.
pub const Origin = png.Origin;

/// How the bytes of a pixel are laid out. See `png`.
pub const Format = png.Format;

/// A picture read from a file, and the memory it lives in. See `png`.
pub const Decoded = png.Decoded;

/// Everything reading one can fail with. See `png`.
pub const DecodeError = png.DecodeError;

/// How far to trust a file this program did not write. See `png`.
pub const DecodeOptions = png.DecodeOptions;

test {
    _ = png;
}
