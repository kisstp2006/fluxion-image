# Fluxion Image

Pixels, and the files they travel in. For Zig 0.16.

| Module | What it is |
| --- | --- |
| `png` | Writing a PNG: the minimum the format needs - one `IHDR`, one `IDAT`, one `IEND`, a CRC on each - so a frame read back from a GPU can be looked at by anybody. |

```zig
try image.png.writeFile(gpa, io, "frame.png", .{
    .width = 960,
    .height = 540,
    .pixels = pixels,          // RGBA, eight bits a channel
    .row_pitch = 960 * 4,
    .origin = .bottom_left,    // what glReadPixels hands back
}, .{});
```

**A frame is not one shape.** OpenGL reads pixels back bottom row first;
Direct3D and Vulkan top row first. A driver pads its rows to suit itself, so
the distance from one row to the next is a fact the caller knows and this
library does not guess. Both are fields of `Image`, checked before a byte is
read, and a program that knows which GPU it is talking to fills them in once.

**The alpha is dropped unless asked for.** A frame is opaque, and three
channels is a quarter less to compress. `keep_alpha` writes four.

**Nothing here decodes.** Reading a PNG means reading every PNG - sixteen-bit
channels, palettes, interlacing, gamma - which is a different amount of code
for a different reason. Writing one is a hundred lines, and it is the hundred
lines every renderer's test suite ends up wanting.

Nothing here allocates except through the allocator it is handed, and only
for as long as one call.

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

## Build

```bash
zig build test        # run the test suite
zig build example     # write zig-out/gradient.png
zig build docs        # generate API docs into zig-out/docs
```

## Licence

`BSD-2-Clause`. See [LICENSE](LICENSE).
