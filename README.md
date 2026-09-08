# Fluxion Image

Pixels, and the files they travel in. For Zig 0.16.

| Module | What it is |
| --- | --- |
| `png` | A PNG, read and written: a frame saved so it can be looked at, and a texture loaded so it can be drawn. |

```zig
// Out, to be looked at.
try image.png.writeFile(gpa, io, "frame.png", .{
    .width = 960,
    .height = 540,
    .pixels = pixels,          // RGBA, eight bits a channel
    .row_pitch = 960 * 4,
    .origin = .bottom_left,    // what glReadPixels hands back
}, .{});

// In, to be drawn.
var atlas = try image.png.readFile(gpa, io, "atlas.png", .{});
defer atlas.deinit(gpa);
const texture = try device.createTexture(.{
    .width = atlas.width,
    .height = atlas.height,
    .data = atlas.pixels,
});
```

**A frame is not one shape.** OpenGL reads pixels back bottom row first;
Direct3D and Vulkan top row first. A driver pads its rows to suit itself, so
the distance from one row to the next is a fact the caller knows and this
library does not guess. Both are fields of `Image`, checked before a byte is
read, and a program that knows which GPU it is talking to fills them in once.

**What comes back from a file is one shape.** RGBA, eight bits a channel, top
row first, tightly packed, whatever the file held. A caller that had to branch
on whether a picture happened to be greyscale or palettised would be doing the
decoder's job, and that one shape is what `createTexture` takes.

**The alpha is dropped on the way out unless asked for.** A frame is opaque,
and three channels is a quarter less to compress. `keep_alpha` writes four.

**The two halves are not the same size, and should not be.** Writing one is
the minimum the format needs: one `IHDR`, one `IDAT`, one `IEND`, a CRC on
each, and every row prefixed with a zero to say it was not predicted from the
one above. Reading one is reading what somebody else's exporter produced, and
there is no choosing not to:

| Read | Written |
| --- | --- |
| Greyscale, palette, RGB, greyscale with alpha, RGBA | RGB and RGBA |
| One, two, four, eight and sixteen bits a sample | Eight |
| All five row filters | None, which is filter zero |
| `tRNS`, as a palette's alphas or as one transparent colour | Nothing to say |
| Image data split across any number of `IDAT` chunks | One |
| Everything else walked past: gamma, text, timestamps | Not written |

Nothing here allocates except through the allocator it is handed. What
`encode` takes it borrows; what `decode` returns it owns, until `deinit`.

## Install

```bash
zig fetch --save git+https://github.com/kisstp2006/fluxion-image
```

Or, for a checkout next to your project, add to `build.zig.zon`:

```zig
.dependencies = .{
    .fluxion_image = .{ .path = "../fluxion-image" },
},
```

Either way, wire it up in `build.zig`:

```zig
const fluxion = b.dependency("fluxion_image", .{
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("fluxion_image", fluxion.module("fluxion_image"));
```

```zig
const image = @import("fluxion_image");
```

One dependency comes with it, fetched the same way and needing nothing from
you: [Fluxion Hash](https://github.com/kisstp2006/fluxion-hash), whose CRC-32
is the one at the end of every chunk.

## Where it sits

This is the first library on the third tier of the Fluxion licence ladder:
`BSD-2-Clause`, built on a tier-one library. That tier asks one thing a
binary built from it did not before - the copyright notice reproduced in the
documentation or about-box of what you ship. The examples of `fluxion-gl` and
`fluxion-d3d` use it to save a frame; the libraries themselves do not, and a
program that depends on either never fetches this.

## The tests read files this library did not write

Three of them decode PNGs another program produced: Python's `zlib` did the
compressing, and the row filters were applied a second time from the
specification rather than from the code being tested. What they check is
therefore the decoder against the format, not the decoder against the encoder
sitting next to it - which is the only way a round trip proves anything.

Between them they cover a different filter on every row, a four-bit palette
with a transparency table, and sixteen bits a channel. The rest of the suite
builds PNGs by hand for the cases no encoder would produce: a damaged CRC, a
chunk that overruns the file, an interlaced picture, a filter number the
format does not have, an index past the end of a palette, and a header
claiming ten gigapixels.

## Build

```bash
zig build test        # run the test suite
zig build example     # write zig-out/gradient.png, and read it back
zig build docs        # generate API docs into zig-out/docs
```

## Licence

`BSD-2-Clause`. See [LICENSE](LICENSE).
