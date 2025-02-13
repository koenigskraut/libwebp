# WebP Codec

```
      __   __  ____  ____  ____
     /  \\/  \/  _ \/  _ )/  _ \
     \       /   __/  _  \   __/
      \__\__/\____/\_____/__/ ____  ___
            / _/ /    \    \ /  _ \/ _/
           /  \_/   / /   \ \   __/  \__
           \____/____/\_____/_____/____/v1.3.2
```

WebP codec is a library to encode and decode images in WebP format. This package
contains the library that can be used in other programs to add WebP support, as
well as the command line tools 'cwebp' and 'dwebp' to compress and decompress
images respectively.

See https://developers.google.com/speed/webp for details on the image format.

The latest source tree is available at
https://chromium.googlesource.com/webm/libwebp

It is released under the same license as the WebM project. See
https://www.webmproject.org/license/software/ or the "COPYING" file for details.
An additional intellectual property rights grant can be found in the file
PATENTS.

## Building

Zig version required is at least `0.12.0-dev.1808+69195d0cd`. Build process for native target is just
```console
zig build -Doptimize=ReleaseSmall
```
Consider specifying generic target for maximum compatibility, for example:
```console
zig build -Dtarget=x86_64-linux
```
Pass option `zig-decoder` in order to use Zig port. If decoder is the only thing you'll need, you can use `only-decoder` option to deal only with Zig:
```console
zig build -Dzig-decoder -Donly-decoder
```

Also see the general [building documentation](doc/building.md).

## Encoding and Decoding Tools

The examples/ directory contains tools to encode and decode images and
animations, view information about WebP images, and more. See the
[tools documentation](doc/tools.md).

## APIs

See the [APIs documentation](doc/api.md), and API usage examples in the
`examples/` directory.

## Bugs

Please report all bugs to the issue tracker: https://bugs.chromium.org/p/webp

Patches welcome! See [how to contribute](CONTRIBUTING.md).

## Discuss

Email: webp-discuss@webmproject.org

Web: https://groups.google.com/a/webmproject.org/group/webp-discuss
