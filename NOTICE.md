# Provenance and license

**English** · [Русский](NOTICE.ru.md)

ARGUS is a derivative work of **[NIDAS](https://github.com/S4mpsa/NIDAS)** (Networked
Information Display & Automation Software), by S4mpsa and contributors.

NIDAS is distributed under the **GNU General Public License v3.0**. GPL-3.0 is a copyleft
license, so ARGUS as a derivative work must be distributed under the same terms. The full
license text is in [LICENSE.md](LICENSE.md).

## What was taken from NIDAS

Ideas and code from the graphics layer were reused; everything else was written from scratch:

| ARGUS file | Origin |
|---|---|
| `lib/graphics/ar.lua` | Based on `lib/graphics/ar.lua` from NIDAS. Removed the implicit global `legacyScaling`, dropped the palette dependency, moved color conversion into `lib/utils/screen.lua`, removed unused primitives. |
| `lib/graphics/graphics.lua` | Based on `lib/graphics/graphics.lua` from NIDAS (half-block rendering). Rewritten: fixed odd-rectangle-boundary handling; made double buffering optional, so on a tier-2 GPU the app runs (with flicker) instead of refusing to start. |
| `lib/graphics/colors.lua` | The idea of a bidirectional color table is from NIDAS; the palette is our own. Fixed table mutation during a `pairs()` traversal. |
| `lib/utils/parser.lua` | Based on `lib/utils/parser.lua` from NIDAS. Fixed: sign loss in `getInteger`, `nan` at zero in `splitNumber`, the skipped 1000–1000.9 range in `metricNumber`. Added formatting from an exact decimal string. |
| `lib/utils/screen.lua` | Based on `lib/utils/screen.lua` from NIDAS. Bitwise operations replaced with arithmetic (Lua 5.2 compatibility), added `blend`. |
| `lib/utils/time.lua` | The `time.format` function from NIDAS; the NIDAS-specific real-time-clock hack was removed. |
| `.shrc`, autostart approach | The NIDAS autostart scheme via `/home/.shrc`. |

The LSC-reading logic in `core/sources/lsc.lua` was inspired by
`server/usecases/get-lsc-status.lua` from NIDAS but rewritten entirely: NIDAS parses the
sensor strings by hardcoded indices, ARGUS matches by label. See the "Accuracy and internals"
section in [README.md](README.md).

## What was removed from NIDAS

Multiblock monitoring, the maintenance overlay, automatic infusions (Thaumcraft), fluid
displays, the toolbar and clock, notifications, the robot locator, tablet support,
microcontrollers, auto-stocking, ore processing, the taskboard, the "master/local server"
network protocol over modems, and the replacement of `/lib/core/boot.lua` and
`/etc/profile.lua`.
