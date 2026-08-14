# ARGUS — energy monitoring for OpenComputers

**English** · [Русский](README.ru.md)

A Lua app for the **OpenComputers** mod on **GregTech: New Horizons 2.8.3**. Shows the state
of your energy buffers on the computer screen and in AR glasses at the same time.

The data layer and energy panel are written against the mod sources that actually ship in
2.8.3 — so it reads what GregTech really returns, not what a generic monitor assumes.

[Changelog](CHANGELOG.md) · [Technical details](DETAILS.md) · [License & provenance](NOTICE.md)

![ARGUS dashboard — charge, rates, energy moved and the charge graph](docs/dashboard.png)

*…and the same buffer, crafting queue and ME stock mirrored into AR glasses:*

![ARGUS in AR glasses — ME stock, main buffer and crafting cards](docs/glasses-hud.png)

## Features

- **Every kind of EU buffer**: Lapotronic Supercapacitor, Battery Buffer, the wireless EU
  network, IC2 storage (BatBox / CESU / MFE / MFSU / AFSU), and any GregTech block with an
  EU store (energy hatches, transformers) through a universal adapter.
- **Two outputs at once**: the screen and AR glasses run together and independently. Each
  shows a specific buffer, the sum of all of them, or cycles through them.
- **Metrics that mean something**: in/out in EU/t, **how much energy total** moved in the
  last 5 min and last hour (received and sent separately), time to full or empty, passive
  loss, maintenance status.
- **More accurate than a naïve monitor**: LSC charge is read from the sensor strings, not
  from `getEUStored()` (which lies above 2⁶³); `NET` is measured from the charge delta and
  catches drain into the wireless network past the hatches (see [Accuracy and
  internals](#accuracy-and-internals)).
- **Applied Energistics crafting**: what was ordered, what's in the machines, what's queued,
  and stalled-job highlighting — on the monitor and as a card in the glasses.
- **ME stock tracking**: the count of selected items and fluids in the network, as a card in
  the glasses.
- **Charge graph** with a window from 30 s to a full day; the point step follows the window
  (always 120 columns).
- **Multiple bases**: server/client mode — remote bases hand over their buffers via a
  wireless or Linked card, and a network key separates you from other players.

## Requirements

**Modpack:** GTNH 2.8.3 — GT5-Unofficial `5.09.51.482`, OpenComputers `1.11.20-GTNH`,
Computronics `1.9.3-GTNH`.

| Component | Why |
|---|---|
| Computer (T2+), Screen, Keyboard | The base machine. Keyboard is for typing names and coordinates. |
| GPU **T3** | Recommended: double buffering, without it the UI flickers. Works on T2, but the frame is drawn straight to screen. |
| **Adapter** | Required: placed touching the machine's controller block. Or an MFU in an Adapter — up to 16 blocks. |
| Internet Card | Install only. |
| Terminal Glasses Bridge + Glasses | Optional, for the AR output. |

## Install

In the OpenOS shell:

```shell
cd /home
wget -f https://cdn.jsdelivr.net/gh/happyCat-dev/ARGUS@v2.5.5/setup.lua && setup
```

The installer walks the mirrors, downloads the files into `/home/ARGUS`, and offers to enable
autostart. The installed version is shown in the bottom-right corner of the app. Run manually
with `cd /home/ARGUS && init`.

> **Install from a tag, not a branch.** jsDelivr caches `@main` per-file for hours and can
> hand you files from different commits — with every request reporting success.

If it won't download, or it updated but nothing changed — the causes (TLS handshake abort,
the OpenOS `require` cache) are broken down in [DETAILS.md](DETAILS.md).

Later updates are done in-app from the **Settings** page:

![Settings page — graph window and in-app updates](docs/settings.png)

## Usage

Control is by mouse over the screen (right-click the monitor in-game). Settings are **not**
saved automatically — press `Save`. Quit with `Quit` or `Ctrl+C`.

| Page | What it does |
|---|---|
| **Dashboard** | Energy panel for the selected source. |
| **Buffers** | Click — show that buffer. `rename` — custom name. `on/off` — polling. `Rescan components` — re-read components. |
| **Glasses** | AR-panel settings for the glasses: source, position, size, crafting and stock cards. |
| **Crafting** | ME network crafts: CPUs, chain of the selected one, stalled jobs. |
| **Network** | Server/client mode, network key, port, list of connected bases. |
| **Settings** | Graph window (30 s … a full day, preset or exact seconds) and app updates: auto-check and “Check for updates”. |
| **Save** | Saves settings to `/home/ARGUS/settings/config`. |

**Buffer states:** `ONLINE` — energy flowing · `IDLE` — available but not moving ·
`OFF` — work disabled · `PROBLEM` — needs maintenance · `MISSING` — component unavailable.

On **Buffers** you also pick which ME items and fluids to watch beside a buffer:

![Buffers page — buffer list and the ME item/fluid picker](docs/buffers.png)

From the glasses the source can be switched without walking to the computer: `←`/`→` —
neighbour, `1`…`9` — by number, `C` — cycle. Requires a bound Free Cursor key in
`Controls → OC Glasses` (unbound by default — otherwise the app looks broken). The **Glasses**
page configures each pair — source, position, size, and the crafting and stock cards:

![Glasses page — per-pair AR configuration](docs/glasses.png)

## Multiple bases: server and clients

OpenComputers networks **do not merge** — a component is only visible inside its own
`Network`, and wireless and Linked cards carry messages only. So each remote base runs its
own ARGUS in `client` mode: it reads its buffers locally and sends **finished numbers** to
the server, which shows them alongside its own, aggregate included.

- **Wireless Network Card (T2)** — same dimension, up to ~400 blocks.
- **Linked Card** — another dimension or unlimited range, strictly 1:1.
- A **network key** separates your bases from everyone else's on a shared server
  (`modem.broadcast` reaches every modem on the same port). It's an SSID, not a password —
  for privacy use a Linked Card.

Set it up on the **Network** page of both bases: role, shared key, shared port, base name.
Full breakdown of the transports and protection is in [DETAILS.md](DETAILS.md).

![Network page — role, port, network key and node name](docs/network.png)

## Applied Energistics crafting and stock

The **Crafting** page and the glasses cards show what your autocraft is doing right now, and
highlight stalled jobs (two idle thresholds). Stock tracking shows the count of selected
items and fluids.

Needs an **Adapter** to the **ME Controller** and a **Crafting Monitor** in each CPU (without
it the final output isn't visible). Works **only on the GTNH build** of OpenComputers —
upstream reports nothing about a running craft ([issue #3786](https://github.com/MightyPirates/OpenComputers/issues/3786)).
If the page is empty, `tools/medump.lua` says why.

![Crafting page — CPU list and the selected job's chain](docs/crafting.png)

## Accuracy and internals

The data layer is built against the GT5-Unofficial `5.09.51.482` and Computronics
`1.9.3-GTNH` sources.

- **Parsed by label, not by index** — an addon inserts a sensor line and index-based parsing
  yields silently wrong numbers; ARGUS matches on the label and returns `nil` when it's absent.
- **LSC accuracy** — `getEUStored()` truncates the BigInteger via `longValue()` and lies
  above 2⁶³ (not fixed in 2.8.3). ARGUS stores the charge as the exact decimal string from
  the sensor and prints it.
- **Rate from the charge delta**, not "IN minus OUT" — works even for IC2 storage that
  reports no throughput, and accounts for passive loss.
- **String width in characters, not bytes** — `gpu.set` advances by character, so non-ASCII
  (`●`, `…`) never shifts the layout.
- **Runs on a GPU T2** — the frame is drawn directly rather than through video-memory
  buffers, so a T3 is recommended but not required.

## Development

Everything below the renderers is pure Lua and tested outside Minecraft:

```shell
lua tests/run.lua        # checks: sensor parsing, metrics, crafts, stock, formatting
lua tests/preview.lua [dashboard|buffers|glasses|crafting|network|stock]   # UI to text
```

```
init.lua              entry point and main loop
setup.lua             installer
config/               loading and saving settings
core/
  sensor.lua          parse getSensorInformation() by label
  sources/            buffer adapters (lsc, batterybuffer, ic2, energycontainer)
  monitor.lua         polling, aggregation, virtual wireless views
  craft.lua           ME network CPU polling, chain and stall output
  stock.lua           tracking item and fluid counts in the ME network
  metrics.lua         rates, averages, time forecast
  states.lua          buffer statuses (ONLINE / IDLE / OFF / …)
  ring.lua            ring buffer for history
  update.lua          check and install a new version via jsDelivr → setup.lua
lib/graphics/         ar.lua (glasses), graphics.lua (GPU), colors.lua
lib/utils/            parser, screen, text, time
ui/                   screen interface: panel, graph, widgets, app, format
ar/                   AR interface: panel (energy), craft, stock, glasses manager
net/                  distributed mode: transport, server, client
tools/sensordump.lua  energy-component diagnostics
tools/medump.lua      ME-network diagnostics
```

New buffer type: a module in `core/sources/` with fields `kind`, `label`, `componentTypes`,
functions `detect(proxy, lines, componentType)` (returns confidence, 0 = "not mine") and
`read(proxy, lines)`; register it in `adapters` in `core/sources/init.lua`.

## License

**GPL-3.0**. See [LICENSE.md](LICENSE.md) and [NOTICE.md](NOTICE.md) for full terms and provenance.
