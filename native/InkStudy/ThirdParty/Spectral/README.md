# Spectral.js Reference

Unmodified source obtained on 2026-09-11 from:
https://raw.githubusercontent.com/rvanwijnen/spectral.js/master/spectral.js

Source SHA-256: `dbaa1a8b44d2c734b48b6d44777b1f182c9740e9220d2cbded02002c8e6d271a`.
The source file includes the full MIT license and Ronald van Wijnen's copyright notice.

`scripts/generate-pigment-lut.mjs` uses this source offline to generate the
three-pigment lookup table and its compiled Swift byte array. The compiled
bytes exactly match the RGB resource; drawing does not require runtime file I/O.
JavaScript and full spectral calculations are not
executed while drawing. The table uses the library's `mix` and `toGamut` methods.
The native wet-brush transport and incremental presentation cache are InkStudy
code. No Mixbox code or assets are included.

The mixing exercise has a dedicated cool-red / yellow / blue pigment palette.
The other exercises and pre-existing artwork retain their original palette.
