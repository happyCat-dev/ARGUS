# ARGUS — technical details

**English** · [Русский](DETAILS.ru.md)

How everything works below the renderers, and the gotchas that each cost a debugging session:
OpenComputers, GregTech/GTNH, OCGlasses, Applied Energistics, networking, and file delivery.
The stuff that is expensive to figure out twice.

## What it is

A Lua app for the **OpenComputers** mod on **GregTech: New Horizons 2.8.3**. It monitors
energy buffers and shows them on the computer screen and in AR glasses at the same time.

Distributed under **GPL-3.0**; provenance and borrowings are in [NOTICE.md](NOTICE.md). The
graphics layer was kept, everything else was stripped out, and the data layer and energy
panel were rewritten from scratch.

The name is meant to grow past energy — hence ARGUS (the hundred-eyed guard), not the old
EMON (Energy MONitor).

- Repository: `github.com/happyCat-dev/ARGUS` (formerly `sblndn20/ARGUS`, earlier `monitoring-app`)
- Install path: `/home/ARGUS`, autostart via `/home/.shrc`

## Target versions — verify against these, not master

GTNH `master` on GitHub is already 2.9-dev, with **different formats**. Everything was checked
against the tags from the
[DreamAssemblerXXL 2.8.3 manifest](https://github.com/GTNewHorizons/DreamAssemblerXXL/blob/master/releases/manifests/2.8.3.json):

| Mod | Version in 2.8.3 |
|---|---|
| GT5-Unofficial | `5.09.51.482` |
| OpenComputers | `1.11.20-GTNH` |
| Computronics | `1.9.3-GTNH` |
| OCGlasses | `1.6.1-GTNH` |

## OpenComputers gotchas — each cost a debugging session

**Proxy methods are callable TABLES, not functions.** `machine.lua:1366`:
`proxy[method] = setmetatable({address=..., name=...}, componentCallback)`. So
`type(proxy.getSensorInformation) == "function"` is **false**, and such a check rejects
every method of every component (symptom: a healthy LSC looks empty, buffers aren't found).
Use `core.util.callable`. Test fixtures must reproduce this shape — with plain functions the
bug slips past the tests.

**`package.loaded` lives for the whole session until the computer reboots.** The entire
computer is one Lua state; OpenOS keeps a single `package` table (`boot/01_process.lua`),
there is no per-program sandbox. `lib/package.lua:76` returns the module from memory. Scripts
(`init.lua`, `tools/sensordump.lua`) are read from disk on every run, but `require` modules
are not — hence a mix of new and old code after an update. Both entry points clear their own
namespaces from `package.loaded` — when adding new namespaces, **update the lists there**.

**`filesystem.copy` handles files only.** It is implemented as `filesystem.open(from, "rb")`
— on a directory it silently returns `false`. Copying `settings/` as a directory = losing the
settings without a single error.

**Lua numbers are doubles.** Above 2^53 (~9·10¹⁵) the exact value isn't representable. Charge
is stored both as a number (for math) and as an **exact decimal string** from the sensor (for
display).

**`gpu.set` advances the cursor by characters, `#` counts bytes.** Any non-ASCII (`●`, `…`,
`▏`) breaks the layout. Use `lib.utils.text` (`len`/`sub`/`fit`/`upper`/`char`).

**`component.list()` is keyed by the full UUID.** Indexing it with a short address is always
`nil` (this is exactly why Battery Buffer used not to be detected). Resolve via `component.get`.

**GPU buffers require T3.** Check `allocateBuffer` via `pcall`, not `type(...)` (see the first
gotcha). Without T3 — direct drawing, which flickers.

**Lua 5.2 compatibility**: no bitwise operators (`>>`, `&`).

## GregTech / GTNH gotchas

**The LSC lies in `getEUStored()` above 2^63.** `MTELapotronicSuperCapacitor.getEUVar()` calls
`stored.longValue()` on a BigInteger — which **truncates**, it doesn't clamp. Fixed only in
2.9 with a dedicated `LSC` component that doesn't exist in 2.8.3. So the LSC's charge and
capacity are taken from the **sensor strings** (rendered from the BigInteger), and the rates
from the structural getters.

**Parse sensor strings by LABEL, not by index.** A naïve parse grabs `[2]`, `[5]`, `[23]` —
an addon inserts a line, and instead of an error you get silently wrong numbers.

**LSC sensor format in 2.8.3** — 24 lines, localized, with §-codes. Values are duplicated:
with separators and in scientific notation (`1,234` and `1.234E9`) — the scientific twin must
not be parsed as exact digits. Averages carry a `(last 5 minutes)` tail — those digits will
spoil a naïve parse. GTNH computes the 5-min / 1-hour averages itself — use them, don't
recompute.

**Wireless EU in 2.8.3 is only readable from lines 23/24 of the LSC sensor** — there is no API.

**The `gt_machine` component comes from Computronics**, not GregTech and not OC.
`getSensorInformation()` == `getInfoData()`. The Computronics + OC drivers are merged onto one
proxy, so both `getEUStored()` and `getStoredEUString()` are available.

**An Adapter is mandatory** and must touch the multiblock's **controller** block. An MFU in an
Adapter — up to 16 blocks.

## OCGlasses gotchas

The mod is **OCGlasses `1.6.1-GTNH`** ([sources](https://github.com/GTNewHorizons/OCGlasses)),
not OpenGlasses2 and not OpenPeripheral.

- **No interactive widgets** — only drawing primitives. Buttons are drawn by hand, and hits
  are checked with a custom hit-test.
- Signals: `glasses_on(user, w, h)`, `glasses_off(user)`, `hud_click(user, x, y, button)`,
  `hud_keyboard(user, char, key)`, `block_interact`, `overlay_opened/closed`. **In practice
  the signal carries the leading glasses address**: a live dump showed
  `hud_keyboard(<UUID>, user, char, key)` — the first argument is stripped in
  `hud:handleSignal` by a UUID pattern.
- **`char` in `hud_keyboard` is garbage; bind keys to the SCAN CODE `key`.** OCGlasses sends a
  Java `char`, but in the dump `[`→27, `]`→29 (control codes, not ASCII `91/93`). The scan
  code, however, is correct and stable: `[`=26, `]`=27, `-`=12, `=`=13, `←`=203, `→`=205,
  `1`..`9`=2..10, `f`=33, `c`=46. An early version compared `char` to a number — **all
  character hotkeys silently didn't work**, and the arrows survived only because they were on
  `key`. Test fixtures must send the real shape (scan code + garbage char), or the bug slips
  past.
- **Input only exists while the Free Cursor overlay is open**, and both keys
  (`Free Cursor (Hold)` / `(Toggle)`) are **UNBOUND by default** — `new KeyBinding(..., 0, ...)`.
  Without a binding the user thinks the app is broken. The in-game section is labelled
  **"OC Glasses"** (`openGlasses` — a lang key only).
- `hud_click` sends coordinates in **ScaledResolution**, and `glasses_on` reports the same one
  — so the panel size is taken automatically, otherwise clicks won't land on the buttons.

## Applied Energistics gotchas (crafting)

**The crafting API exists ONLY in the GTNH fork.** Upstream OC gives nothing about a running
job except `isDone()` on the object from its own `request()` — open
[issue #3786](https://github.com/MightyPirates/OpenComputers/issues/3786). Everything rests on
`NetworkControl.scala` from `1.11.20-GTNH`: `getCpus()` → `{name, storage, coprocessors,
busy, cpu}`, and the `cpu` value can do `activeItems`, `pendingItems`, `storedItems`,
`finalOutput`, `isBusy`, `isActive`, `cancel`. Verify against the tag, not ocdoc.cil.li —
that describes upstream, and these methods aren't in the docs at all.

**`finalOutput()` requires a Crafting Monitor block in the CPU cluster.** The driver looks for
`TileCraftingMonitorTile` in `getCpu.getTiles` and reads `getJobProgress()`; without it —
`(null, "No crafting monitor")`. There is no software workaround: the driver has nowhere else
to get the job's output. The chain still reads fine — only the final output is unknown, so the
UI writes which block to place rather than a `?`.

**There is no order in the chain.** A job is a tree of parallel subtasks;
`getListOfItem(PENDING)` returns a **set**. "Next" can only ever be a heuristic (the biggest
stack is taken). Presenting it as a queue would be lying to the user; the page says so
plainly.

**There is no stall flag.** `isStalled()` doesn't exist; the state is derived from the
readings not changing — hence the history in `core/craft.lua`. Key point: **a plain timeout is
no good**, one GT recipe runs for minutes (threshold 120 s). A stronger sign is different —
busy, `pendingItems` non-empty, but `activeItems` empty: there is work, but nothing went into
the machines. A healthy reading of that shape almost never happens, threshold 15 s.

**Item lists can have HOLES.** The driver's `convert()` returns `null` for a stack it couldn't
describe, and in Lua that's a hole in the array. `ipairs` stops at the first one and silently
undercounts the work — iterate with `pairs`. Fixtures must reproduce the hole.

**Clear the idle history when a CPU frees up.** `readCpu` returns early for an idle CPU (to
save calls) — if the record isn't reset there, the next job with the same signature (the same
recipe ordered twice) inherits a foreign timer and instantly goes STALLED. There is a test for
this; the bug was real.

**Polling is expensive**: `getCpus()` + up to 4 calls per **busy** CPU. Its own interval
(2 s), idle CPUs aren't read.

## Networking: you CANNOT merge networks wirelessly

A component's visibility exists only inside one `Network` object; networks join only through
`Node.connect()` (physical contact). Wireless carries **messages only**.

Even a wired **Relay does not merge networks** — in `Hub.scala` each side is a separate node
in a separate network (`plugsInOtherNetworks`). The mod's docs say it directly: *"without
exposing components to computers in other networks"*. A Server Rack is the same `Hub`.

| Method | What it carries | Range | Cross-world |
|---|---|---|---|
| MFU in an Adapter | **the component** | 16 blocks | no |
| Wireless T1 / T2 | messages | 16 / 400, blocked by blocks | no |
| Linked Card (`tunnel`) | messages | ∞ | **yes** |

**A shared server means bases must be separated.** `modem.broadcast` is received by any modem
in range that opened the same port, and the default port is the same for everyone. Without a
key, a neighbour's server would poll our clients, and our server would collect their bases.
Every message carries `net.PROTOCOL` and a **network key**; `net:accepts()` is the single
check point. The default key is derived from `computer.address()` (unique, stable). It's an
**SSID, not a password**: the traffic is in the clear, OC has no encryption. Real isolation is
only a Linked Card (point-to-point).

**Hence the distributed mode** (`net/`, implemented in 2.1.0): a client on each base reads its
own buffers locally and sends finished numbers to the server, which mixes them into `monitor`
via `setRemote` — after that they're ordinary views. Pull model + a `lastSeen` watchdog →
`OFFLINE`. Both transports deliver via `modem_message`, so the protocol is one; with `tunnel`
(Linked Card) `send` is **address-less** — there is exactly one peer. Messages are tagged with
`net.PROTOCOL`, otherwise foreign traffic on the same port would reach the parser.

## Delivering files into the game

**`raw.githubusercontent.com` is unreachable from the user's server** — the TLS handshake
breaks (`Remote host terminated the handshake`, i.e. `SSLSocketImpl.handleEOF()` from JDK 11+,
meaning the server dropped TCP after the ClientHello). This is **not** the OC config (its
filter would give `address is not allowed`), **not** certificates (they would give
`PKIX path building failed`), **not** the Java version. `cdn.jsdelivr.net` works — the
installer tries it first.

**Install from a tag only.** jsDelivr caches a branch link **per file separately** for hours,
so `@main` can serve files from different commits — with every request succeeding.

**Redirect mirrors (githack, statically) are useless**: they answer 301 to another host, and
OC uses a bare `HttpURLConnection` that doesn't follow a cross-host redirect — `wget` will
save HTML. For the same reason `http://` instead of `https://` is not a workaround.

**`&&` is mandatory in update commands**: if `wget` failed, `setup` would run the **old**
`/home/setup.lua` and silently install the wrong thing.

**In-app auto-update** (`core/update.lua`, Settings page): the check pulls
`@latest/version.lua` via jsDelivr (raw is unreachable), the install is **pinned to a tag**
`@vX.Y.Z` (a moving ref is cached by the CDN per file) and delegated to a fresh `setup.lua` —
the module does NOT hold its own file manifest / mirrors / version check; the installer is the
single source of truth. Download and run happen **after leaving the app** (a `pendingUpdate`
flag → init.lua), so a large fetch doesn't hang behind a static frame. The networking branches
aren't tested on desktop — only the pure `parseVersion`/`tagFor` are covered.

## Structure

```
init.lua              entry point, main loop, package.loaded cleanup
setup.lua             installer: mirrors, migration, version check
version.lua           version (checked by the installer, shown in the footer)
config/               loading/saving settings, defaults
core/
  sensor.lua          parse getSensorInformation() by label
  sources/            buffer adapters (lsc, batterybuffer, ic2, energycontainer)
  monitor.lua         polling, aggregate, virtual wireless views
  craft.lua           ME-network CPU polling, chain and stall output
  stock.lua           tracking item/fluid counts in the ME network (per-buffer)
  metrics.lua         rates, averages, forecast, graph step
  ring.lua            ring buffer (flat arrays — RAM saving)
  update.lua          check/install a new version via jsDelivr → setup.lua
  util.lua            util.callable — see gotchas
lib/graphics/         ar.lua (glasses), graphics.lua (GPU + double buffering), colors.lua
lib/utils/            parser, screen, text, time
ui/                   panel, graph, widgets, app, format
ar/                   panel (energy), craft (crafts), stock (items), init (manager, input, cycle)
net/                  init (modem/tunnel transport), server (poll+watchdog), client (replies)
tools/sensordump.lua  diagnostics: all components, getters, raw strings, parse
tools/medump.lua      ME diagnostics: CPUs, method presence, raw lists, parse
tests/run.lua         419 tests, desktop Lua
tests/preview.lua     render the UI to text through a fake GPU
```

New buffer type: a module in `core/sources/` with `kind`, `label`, `componentTypes`,
`detect(proxy, lines, componentType)` → confidence (0 = not mine), `read(proxy, lines)`;
register it in `adapters` in `core/sources/init.lua`. Adapters are chosen by **scoring**:
LSC and an energy hatch are both `gt_machine`, told apart only by the sensor.

## Development

Everything below the renderers is pure Lua and tested outside Minecraft:

```shell
lua tests/run.lua        # 419 checks
lua tests/preview.lua [dashboard|buffers|glasses|crafting|network|stock]  # UI to text
```

A Lua interpreter may not be installed — get it with `winget install --id=DEVCOM.Lua`, the
binary is at `%LOCALAPPDATA%\Programs\Lua\bin\lua.exe`. Syntax check every file with `luac -p`.

**Not yet tested in-game** — the sensor fixtures were reconstructed from the Java sources. If
the numbers diverge, capture `tools/sensordump.lua` and open an issue.

### Release

1. `version.lua` → new version
2. `setup.lua`: `BRANCH` and `EXPECTED_VERSION` → the same version
3. README: install links
4. Tests + `luac -p`
5. Commit, `git tag -a vX.Y.Z`, push the branch and the tag
6. Verify the mirror: every manifest file against the tag's contents, not just HTTP 200

## Links

**Modpack and mods**
- [GTNH Wiki](https://wiki.gtnewhorizons.com/wiki/) · [OpenComputers in GTNH](https://wiki.gtnewhorizons.com/wiki/Open_Computers)
- [2.8.3 manifest](https://github.com/GTNewHorizons/DreamAssemblerXXL/blob/master/releases/manifests/2.8.3.json) — exact mod versions
- [GT5-Unofficial @5.09.51.482](https://github.com/GTNewHorizons/GT5-Unofficial/tree/5.09.51.482) — `MTELapotronicSuperCapacitor.java`, `MTEBasicBatteryBuffer.java`
- [OpenComputers 1.11.20-GTNH](https://github.com/GTNewHorizons/OpenComputers) — `machine.lua` (proxy), `lib/package.lua` (require), `Hub.scala`, `WirelessNetwork.scala`
- [Computronics 1.9.3-GTNH](https://github.com/GTNewHorizons/Computronics) — `gt_machine`, `chat_box` drivers
- [OpenComputers @1.11.20-GTNH: `NetworkControl.scala`](https://github.com/GTNewHorizons/OpenComputers/blob/1.11.20-GTNH/src/main/scala/li/cil/oc/integration/appeng/NetworkControl.scala) — the whole AE2 crafting API: `getCpus`, `Cpu`, `convert`
- [OCGlasses 1.6.1-GTNH](https://github.com/GTNewHorizons/OCGlasses) — `ClientKeyboardEvents.java`, `OpenGlassesTerminalTileEntity.java`

**APIs**
- [OpenComputers Docs](https://ocdoc.cil.li/) · [component API](https://ocdoc.cil.li/api:component) · [modem](https://ocdoc.cil.li/component:modem) · [Relay](https://ocdoc.cil.li/block:switch)
- [OC-GTNH-docs: gt_machine](https://github.com/guid118/OC-GTNH-docs/blob/main/docs/components/gt_machine.lua) — typed reference for the getters

## Open questions

- AE2 crafting isn't verified in-game: fixtures reconstructed from `NetworkControl.scala`. If
  the page is empty or the numbers look odd — capture `tools/medump.lua` and open an issue.
- Item/fluid tracking (`core/stock.lua`) isn't verified in-game: the same `NetworkControl.scala`
  getters (`getItemInNetwork`, `getFluidsInNetwork`, `getItemsInNetwork`). `getItemsInNetwork`
  is heavy (the whole network inventory) — pulled only when the picker opens and on Refresh,
  not in the loop. Diagnostics — the ME stock section in `tools/medump.lua`.
- Cancelling a stalled job from the glasses: `cancel()` is in the API, deliberately not wired
  up — the decision was to stay monitoring-only, so a stray click can't kill a multi-hour order.
- Computronics' Chat Box as an alternative to glasses input (40-block radius, configurable).
- Distributed mode isn't verified in-game: the tests run the protocol on fake cards, but nobody
  has seen a live modem between two bases.
