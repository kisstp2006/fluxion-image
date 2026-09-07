// SPDX-License-Identifier: BSD-2-Clause

//! Fluxion Image - pixels, and the files they travel in.
//!
//! One piece so far:
//!
//!   `png`  Writing a PNG: the minimum the format needs, and nothing it does
//!          not, so a frame read back from a GPU can be looked at by anybody.
//!
//! ```zig
//! try image.png.writeFile(gpa, io, "frame.png", .{
//!     .width = 960,
//!     .height = 540,
//!     .pixels = pixels,          // RGBA, eight bits a channel
//!     .row_pitch = 960 * 4,
//!     .origin = .bottom_left,    // what glReadPixels hands back
//! });
//! ```
//!
//! **A frame is not one shape.** OpenGL reads pixels back bottom row first;
//! Direct3D and Vulkan top row first. A driver pads rows to suit itself, so
//! the distance from one row to the next is a fact the caller knows and this
//! library does not guess. Both are fields of `Image`, and a program that
//! knows which GPU it is talking to fills them in once.
//!
//! **Nothing here decodes.** Reading a PNG means reading every PNG - sixteen
//! bit channels, palettes, interlacing, gamma - which is a different amount of
//! code for a different reason. Writing one is a hundred lines, and it is the
//! hundred lines every renderer's test suite ends up wanting.
//!
//! Nothing here allocates except through the allocator it is handed, and
//! only for as long as one call.

const std = @import("std");

pub const png = @import("png.zig");

/// A rectangle of pixels somebody else owns. See `png`.
pub const Image = png.Image;

/// Which corner row zero is. See `png`.
pub const Origin = png.Origin;

/// How the bytes of a pixel are laid out. See `png`.
pub const Format = png.Format;

test {
    _ = png;
}
