// SPDX-License-Identifier: BSD-2-Clause

//! A picture made of arithmetic, written out twice: once the way a file holds
//! it, once the way OpenGL reads a frame back, so that the two files come out
//! identical.

const std = @import("std");
const Io = std.Io;

const image = @import("fluxion_image");

const width = 256;
const height = 128;

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;

    // A gradient: red across, green down, and a blue square in the corner
    // that says which corner is which.
    var pixels: [width * height * 4]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const p = pixels[(y * width + x) * 4 ..][0..4];
            const in_square = x < 32 and y < 32;
            p[0] = if (in_square) 0 else @intCast(x);
            p[1] = if (in_square) 0 else @intCast(y * 2);
            p[2] = if (in_square) 255 else 64;
            p[3] = 255;
        }
    }

    try image.png.writeFile(init.gpa, init.io, "zig-out/gradient.png", .{
        .width = width,
        .height = height,
        .pixels = &pixels,
        .row_pitch = width * 4,
    }, .{});
    try out.writeAll("wrote zig-out/gradient.png - blue square top left\n");

    // The same picture, bottom row first, which is what glReadPixels would
    // have handed back. `origin` puts it the right way up.
    var flipped: [width * height * 4]u8 = undefined;
    for (0..height) |y| {
        @memcpy(flipped[y * width * 4 ..][0 .. width * 4], pixels[(height - 1 - y) * width * 4 ..][0 .. width * 4]);
    }
    const a = try image.png.encodeAlloc(init.gpa, .{
        .width = width,
        .height = height,
        .pixels = &pixels,
        .row_pitch = width * 4,
    }, .{});
    defer init.gpa.free(a);
    const b = try image.png.encodeAlloc(init.gpa, .{
        .width = width,
        .height = height,
        .pixels = &flipped,
        .row_pitch = width * 4,
        .origin = .bottom_left,
    }, .{});
    defer init.gpa.free(b);

    try out.print("{d} bytes each way, identical: {}\n", .{ a.len, std.mem.eql(u8, a, b) });
    try out.flush();
}
