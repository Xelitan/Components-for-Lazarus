# Font converter

Reads: TTF, OTF, WOFF, WOFF2, SVG fonts
Writes: OTF, WOFF, WOFF2, SVG fonts

To read WOFF2 fonts needs Brotli unpacker - included. To write WOFF2 files uses Brotli STORE packer.

# Usage:
```
   fontconv <input.ttf>  <output.otf>
   fontconv <input.otf>  <output.woff>
   fontconv <input.woff> <output.otf>
   etc.
```

# Compiling

```
fpc fontconv.lpr -FuBrotli
```

Requires no external programs, no DLLs, all font parsing is done in pure Pascal.
