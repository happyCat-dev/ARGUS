# Changelog

**English** · [Русский](CHANGELOG.ru.md)

Versions before 2.4.0 were released 2026-07-16; 2.5.0 — 2026-07-24; 2.5.1 — 2026-07-25;
2.5.2–2.5.5 — 2026-07-25. Install only from a tag — see [DETAILS.md](DETAILS.md).

---

## 2.5.5 — updating from Settings without extra keystrokes

Previously "Update now" dropped into the installer, which asked `Y/n` about autostart and
at the end told you to run `cd /home/ARGUS && init` by hand. Now the update is seamless:

- The installer **does not re-ask about autostart** if it is already set up (or `--yes`
  is passed) — the choice is remembered. It only asks on a genuinely clean first install.
- Auto-update calls `setup --yes`, and on successful completion the installer **reboots the
  computer itself** — autostart brings up the new version. No `y`, no manual
  `cd`+`init`. A reboot (rather than another `init`) guarantees that no stale module is
  left in the shared Lua state. A broken load does not reboot (on error the installer exits
  earlier).

---

## 2.5.4 — glasses hotkeys on scan codes (the real fix)

In 2.5.3 I was fixing the character hotkeys from the wrong side. A live signal dump revealed
the truth: `hud_keyboard` carries `char` as a **number**, but it is **not** ASCII (`[`→27,
`]`→29 — control codes), whereas the **scan code `key` is correct**: `[`=26, `]`=27, `-`=12,
`=`=13, `f`=33, `c`=46, `1`..`9`=2..10, arrows 203/205. Now all glasses keys are bound to the
scan code `key`, and the unreliable `char` is ignored. `[ ] F - =` and `1-9`/`C` now work.
The test fixtures send the real signal shape (scan code + garbage char + leading glasses
address) so the bug cannot slip through again.

---

## 2.5.3 — auto-update no longer rolls back, character hotkeys work

Two important fixes.

- **Auto-update could install a version LOWER than the current one.** jsDelivr caches
  `@latest` for hours, and the updater assumed "differs ⇒ can update" — without comparing
  versions, so it offered and installed an old tag. Now the latest version is taken from
  the jsDelivr data API (the list is sorted, the cache is fresher), and versions are
  compared by SemVer: "Update now" appears **only if the version is strictly newer**. A
  rollback is impossible.
- **Character glasses hotkeys did not work in-game** (`[ ] F - =`, as well as `1-9`/`C`).
  OCGlasses sends the key character as a Java `char`, and OpenComputers hands it to Lua
  **as a single-character string** (`"["`), not the number `91` — a comparison against a
  number never matched. Only the arrows worked (they come as a whole scan code). Now the
  character is recognized both as a string and as a number. The test fixtures were switched
  to the real string form so the bug no longer slips past.

---

## 2.5.2 — CPU numbering from 1 and busy diagnostics

- **Unnamed CPUs are numbered from 1**, the way a player counts them in the AE2 GUI (it
  was from 0 — "5th and 6th" showed up as "4 and 5"). The internal id stays 0-based so it
  matches the script over `getCpus()`.
- **`tools/medump.lua` prints live `isBusy()` and `isActive()`** per CPU alongside
  `entry.busy`. This is for investigating a known discrepancy: our "busy" counter is
  `entry.busy` (== `CraftingCPUCluster.isBusy`), and on some builds it undercounts CPUs
  that have a job but aren't pushing an item right now. The dump will show which of the
  signals matches the real number — by which the counter will be corrected in the next
  patch (and along with it card paging will start working: right now there are few busy
  ones, and they fit on a single page).

---

## 2.5.1 — collapsing AR cards

A small improvement on top of 2.5.0: the crafting and ME-stock cards in the glasses can now
be collapsed to a title strip so they don't take up your view.

- **A collapse button in the header** of each card. A collapsed card shows only the title
  (for crafts — the `busy/total` counter, for stock — the buffer name); a click on the strip
  expands it back. The state is saved per-glasses and survives a restart.
- **Hotkeys** in the Free Cursor overlay: `-` collapses the crafting card, `=` the stock
  card. Two different keys, because with both cards worn one wouldn't know which to collapse,
  and OCGlasses does not pass modifiers.
- **A hint right on the card**: the glyph in the header is its key (`-` or `=`), so the
  different hotkeys are visible from the HUD. On the **Glasses** page the control hint moved
  under each block separately.

---

## 2.5.0 — ME stock tracking and a settings page

The second block of functionality from the ME network: not what is being crafted, but how
much of what is on hand. Each buffer has its own list of up to five items/fluids, shown next
to it.

- **Shows the quantity** of selected items and fluids from the Applied Energistics network
  in a column next to the buffer on the dashboard and, optionally, as a third card in the
  glasses. The quantity is the main field; what has run out glows as a red zero rather than
  disappearing.
- **The list is per-buffer**, because items come from a single network and the binding to a
  buffer is organizational — you decide what to watch "in the background" of this LSC. The
  choice is on the **Buffers** page: Items/Fluids tabs, a name filter, a network snapshot
  with Refresh.
- **Polling is cheap**: one `getItemInNetwork` per item and one `getFluidsInNetwork` for all
  fluids — a fixed handful of calls regardless of network size; the same item on two buffers
  is one request. The heavy `getItemsInNetwork` (the whole inventory) is pulled only when the
  picker is opened, not in the loop. Lists are walked with `pairs` against `convert()` holes
  — the same pitfall as with crafts. Diagnostics — the ME stock section in `tools/medump.lua`.
- **Only on the GTNH build of OpenComputers**, like crafts: the getters from
  `NetworkControl.scala` of the `1.11.20-GTNH` fork.

Plus a new **Settings** page and auto-update:

- **Graph settings** moved out of the cramped footer onto a separate page.
- **Updating from the app**: it checks `cdn.jsdelivr.net` for a fresh release and, at the
  press of a button, pins to a tag and hands the install off to `setup.lua` — which already
  owns the file list, the settings backup, and the check that the version actually landed.
  Download and install happen after exiting the app, so a large fetch doesn't hang behind a
  static frame. The check at startup is optional, off by default.

---

## 2.4.0 — Applied Energistics crafts

A new block of functionality: what autocrafting is doing right now. A **Crafting** page on
the monitor and a separate card in the glasses next to the energy one.

- **Shows**: the final ordered item, what is in the machines now, what is waiting, what is
  already done, and highlighting of stalled jobs with a note on what was supposed to go next.
- **Only on the GTNH build of OpenComputers.** Upstream reports nothing about a running
  craft (open [issue #3786](https://github.com/MightyPirates/OpenComputers/issues/3786)) —
  everything rests on `Cpu` from `NetworkControl.scala` of the `1.11.20-GTNH` fork:
  `activeItems`, `pendingItems`, `storedItems`, `finalOutput`. `tools/medump.lua` will say
  outright if the driver is the wrong one.
- **Requires a Crafting Monitor in each CPU.** `finalOutput()` is read from
  `TileCraftingMonitorTile` inside the cluster — without the block the final output is
  unknown, and there is no programmatic workaround. The chain is read fine regardless; the
  UI writes which block to add instead of `?`.
- **Order and stalling are inferred, not read.** AE2 has neither a queue (a job is a tree of
  parallel subtasks, `pendingItems` returns a set) nor `isStalled()`. "Waiting" is sorted by
  quantity, and the page says so honestly. Stalling is caught by the readings going still:
  120 sec as the general threshold — because a GregTech recipe runs for minutes — and a
  separate 15 sec for the "busy, there's work, but the machines are empty" case, which means
  not "slow" but "stuck".
- **Polling is cheaper than it looks**: its own interval (2 sec), idle CPUs aren't read at all.
- **The controls don't break habits**: `←` `→` `1-9` `C` are still about energy, the
  crafting card has its own `[` `]` `F`. The card is independent of the energy one — you can
  wear either.

---

## 2.3.2 — tests on the real sensor

A live dump from an in-game LSC exposed three things the fixture reconstructed from the Java
sources didn't show. The fixture was replaced with real output — now the tests check what is
there, not what I assumed.

- **Fixed: `EU IN`/`EU OUT` are instantaneous and almost always zero.** The LSC transfers
  energy in bursts, and polling almost always lands in a pause. In the dump both are zero,
  even though the 5-minute averages are 77.3M and 85.9M EU/t. Hence the perpetual IDLE. Now
  a short moving average is used (`Avg EU IN (last 5 seconds)`), the instantaneous string is
  the fallback, the getters are the last resort (in the dump they too are zero on a working
  machine).
- **Fixed: `2.64x10^11`, not `2.64E11`.** The scientific-notation check looked for `E` and
  didn't see this format — the number turned into garbage `2641011`. Only the fact that the
  string with separators comes first saved it. Both spellings are now parsed.
- **Fixed: `multimachine.supercapacitor` instead of a name.** `getName()` returns a
  localization key. If the name looks like a key (dots, no spaces), the adapter's name is
  substituted — `Lapotronic Supercapacitor`. A custom name via `rename` still takes
  precedence.
- **The IDLE threshold was refined.** Passive loss is subtracted before assessing activity:
  the LSC always leaks, and a comparison against zero would declare any accumulator `ONLINE`
  forever.

## 2.3.1 — source of truth: charge, not GregTech counters

- **Fixed: `NET` showed −1.9k while the buffer lost 700 million.** In 2.3.0 I made
  `EU IN`/`EU OUT` the basis of the calculation — they are faster and more accurate. But
  they count only what passed **through the hatches**: an LSC in wireless mode gives energy
  away past them, and `NET` turned into exactly the passive loss. Fast and wrong is worse
  than slow and right — the basis is once again the **change in charge**, which accounts for
  everything, wherever the energy went. The lag was compensated by shrinking the window from
  5 to 2 seconds, not by swapping the source.
- **Fixed: a buffer was listed as IDLE while losing hundreds of millions.** The state was
  inferred from the same blind counters. Now, if the charge moves noticeably, the buffer is
  considered `ONLINE`, whatever the counters say. The comparison is against a **noise
  threshold**, not zero: above 2^53 adjacent doubles are ~2048 EU apart, and without this the
  state would flicker from a single rounding.
- The same rule was extended to the 5-minute and hour totals.

The divergence of `NET` from `IN − OUT − LOSS` is now **not an error but information**:
energy is moving where GregTech doesn't count it. This is described in the README.

## 2.3.0 — energy totals instead of averages, and fixed IDLE and NET

- **"How much passed", not "at what rate".** The 5-minute and hour lines now show **how much
  energy in total** came in and went out, in separate columns, plus a total. An average rate
  can't answer "how much did I spend in an hour": an hour of frenetic work where input and
  output balanced out looks like an hour of idle. `net` always equals `received − sent` —
  the columns are read side by side, and if they didn't add up, the panel couldn't be
  trusted.
- **Fixed: a buffer hung in IDLE forever.** In `core/sources/lsc.lua` there was
  `util.callNumber(proxy, "getEUInputAverage") or sensor.value(lines, "^%s*EU IN")`, and
  **zero in Lua is truthy**: a getter answering `0` short-circuited the `or`, and the sensor
  string with a real `EU IN: 32,768` was never read. Input and output zero → IDLE state. Now
  the sensor strings come first (GregTech shows them in the machine's own GUI), the getters
  are the fallback.
- **Fixed: `NET` lagged behind the graph.** The rate was always measured by the change in
  charge — a 5-second sliding window, and it lags. Worse, on a large LSC it is also
  imprecise: above 2^53 the double step is about 1000 EU, and a small current drowns in
  rounding noise. GregTech averages `EU IN`/`EU OUT` over 20 ticks itself — faster and more
  accurate. Measurement by charge stayed where the source doesn't report throughput: IC2
  storages and the wireless network.

## 2.2.1 — fixed the crash on the Network page

- **Fixed: `attempt to call a nil value (method 'key')`** right after updating to 2.2.0. The
  culprit wasn't the network key but the `require` cache: `init.lua` clears only the listed
  namespaces from `package.loaded`, and `net` didn't make the list — the modules were added
  in 2.1.0, the list wasn't updated. As a result `require("net")` handed back the version
  loaded at computer boot, without the new method.
- The namespace list is now **checked by a test**: it compares the list declared in
  `init.lua` against what actually loads, and at the same time makes sure the list doesn't
  drop OpenOS's own libraries. Forgetting a namespace again won't be possible.

On 2.2.0 the same thing is cured by rebooting the computer (`reboot`).

## 2.2.0 — network key: separating bases on a shared server

- **Network key.** On a shared server ARGUS may not be yours alone, and `modem.broadcast` is
  received by **any** modem in range that opened the same port — and the default port is the
  same for everyone. Without a key, a neighbor's server would poll your clients, and your
  server would gather other people's bases into its list and aggregate. Now every message
  carries a key, and everything foreign is discarded in both directions.
- The default key is derived from the computer's address: unique, stable across reboots,
  cannot collide by chance. On clients the server's key is entered — on the **Network** page.

Honest about the limits: the key is an **SSID, not a password**. It prevents crossovers but
not eavesdropping: messages go in the clear, there is no encryption in OpenComputers, and
anyone in range who knows the key can connect. For real isolation — a **Linked Card**: a
point-to-point link with no one else to receive it.

## 2.1.0 — distributed mode: server and clients

- **Several bases on one screen.** On the **Network** page a role is chosen: `standalone`,
  `server`, or `client`. The server polls the clients, their buffers appear in the list, on
  the panel, in the glasses, and **in the aggregate** — "all buffers" stopped meaning "all
  buffers of this network".
- **The server sees connected clients**: name, address, buffer count, status, distance, when
  it last answered. A `forget` button removes a vanished one.
- **Two transports, one protocol.** A wireless card (400 blocks on T2, one dimension) and a
  Linked Card (unlimited, cross-world, strictly 1:1) deliver the same way — through the
  `modem_message` signal. The reply goes out on the same card the request arrived on, so as
  not to wake the other bases. The protocol tag cuts off foreign traffic on the same port.
- **Watchdog.** Wireless has no disconnect signal — silence is the only symptom. A client
  that hasn't answered for longer than the timeout is marked `OFFLINE`, its buffers are read
  as `MISSING` and drop out of the aggregate: showing the last known numbers as current would
  be a lie.

Why this way, and not "merge the networks": OpenComputers networks **cannot** be joined
without wires, and this is a design of the mod, not an obstacle. A component's visibility
exists only within a single `Network` object, networks are joined through `Node.connect()` —
physical contact — and even a wired Relay keeps each of its sides in a separate network. Its
documentation says outright: *"without exposing components to computers in other networks"*.
So the client reads its own buffers itself and sends **ready-made numbers**. Polling is
pull-model: the server asks on its own schedule, which keeps the frequency under control,
rules out a storm when bases start simultaneously, and requires no subscription state that
survives a reboot.

How to connect networks — [README section](README.md#multiple-bases-server-and-clients).

## 2.0.0 — renamed to ARGUS

**Breaking:** the install directory `/home/EMON` → `/home/ARGUS`.

- The project was renamed from **EMON** (Energy MONitor) to **ARGUS** — the app will grow
  functionality beyond energy, and the old name would become a lie. Repository:
  `monitoring-app` → `ARGUS`.
- The installer migrates itself: it finds `/home/EMON`, moves the settings, reconfigures
  autostart to the new path, deletes the old directory.
- **Fixed: `setup --clean` destroyed the settings** starting from 1.2.1. Settings were saved
  via `filesystem.copy(".../settings", backup)`, but OpenOS implements `copy` as
  `filesystem.open(from, "rb")` — on a directory this silently returns `false`. The copy
  didn't happen, the wipe that followed carried the settings off, and the installer wrote
  "settings kept" the whole time. Now the config file itself is copied, and success is
  reported only after the fact.
- Fixed: the source name in the header sat at a hardcoded offset `x+5`, tuned for a
  four-letter name — on the five-letter ARGUS it ran together. The width is now measured.

## 1.4.0 — end of flicker, a configurable graph

- **The screen no longer flickers.** The frame is assembled in an off-screen GPU buffer and
  output with a single `bitblt`. Previously each frame was drawn directly to the screen:
  `clear()` blanked everything, and a hundred `gpu.set` calls filled it back in — a
  half-drawn frame was visible. Requires GPU T3; without it, it works as before.
- **The graph window is configurable**, the point step is derived from it. The graph is 120
  columns, so **step = window / 120**: a 2-minute window gives exactly **one point per
  second**. Presets via the `Graph` button (30 s … 1 hour), numeric entry via the `set`
  button. The step is labeled above the graph (`1s/pt`) — the same curve at 1 s and 30 s per
  point means different things.
- Less memory is needed: one ring following the window, instead of a ring per scale.

## 1.3.0 — custom names, precise coordinates, a smooth bar

- **Custom buffer names** — the `rename` button. The name is used everywhere: header, list,
  AR panel, wireless-network label. **Survives `Rescan`**: the machine name is stored
  separately in `detectedName` and doesn't overwrite the user's.
- **Precise AR-panel positioning**: the `manual` anchor makes `X`/`Y` absolute coordinates in
  the glasses' system. The values can be **entered from the keyboard** (an input field
  appeared — before, there was none in the app at all), not just nudged by arrows 4 pixels at
  a time.
- **The charge bar moves smoothly.** Previously `setBar` set the tips straight to the target,
  and the render rate was tied to the component-poll rate — 4 frames per second. Polling now
  runs on its own schedule, the loop ticks at 10 Hz and animates.
- Fixed: the bar had a minimum width, so at 0% a one-pixel stub always stuck out. An empty
  buffer is drawn empty; a bright notch appeared on the leading edge.

## 1.2.2 — updating no longer requires a reboot

- **Fixed: an update might not take effect.** The install went through correctly, the files
  on disk were new, and the app crashed with `attempt to call a nil value` on a function that
  is in the file. The cause is OpenOS's `require` cache: the computer runs in a single Lua
  state, `package.loaded` lives until reboot. Scripts (`init.lua`, `sensordump.lua`) are read
  from disk, but `require` modules are not, hence a mix of new and old code. Both entry points
  now clear their modules from `package.loaded`.

## 1.2.1 — clean reinstall and result verification

- **The installer verifies what actually landed on disk**, rather than trusting the download:
  a successful request ≠ the right bytes, the CDN serves the cache of an old commit and
  honestly returns 200. It reads `version.lua` from disk and checks it against the expected
  version.
- **`--clean`** — wipe the directory and install fresh (settings are preserved; it actually
  worked only in 2.0.0, see above).
- In update commands `&&` is mandatory: on a failed `wget` the **old** `/home/setup.lua` ran
  and silently installed the wrong thing.

## 1.2.0 — installing from an immutable tag

- **A tag by default, not a branch.** jsDelivr caches a branch link **per file separately**
  for hours, so `@main` assembled the install from different commits, and all requests were
  successful at that. Tags and SHAs are immutable.
- **The installed version is visible** — `v2.0.0 @ref` in the bottom-right corner.
  Previously `version.lua` never changed, and there was no way to tell an updated install
  from a stuck one.

## Before 1.2.0 (no tags)

- **Fixed: buffers weren't detected at all.** The method check went through
  `type(x) == "function"`, but OpenComputers returns proxy methods as **callable tables** —
  every method of every component was rejected, a healthy LSC looked empty. The test fixtures
  used flat functions and so missed the bug; now they reproduce the real shape.
- **Switching the source right from the glasses** — `hud_click` / `hud_keyboard` from
  OCGlasses. The mod gives no interactive widgets, so the `‹ ›` buttons are drawn by hand with
  their own hit-test; plus hotkeys `← →`, `1`…`9`, `C`. The panel size is taken from
  `glasses_on` — without matching the scale, clicks wouldn't land on the buttons.
- **The AR-panel position is configurable** — six corners + offset. The default is
  `top-left`: bottom-left is chat, bottom-center the hotbar, top-right potions.
- **The installer iterates over mirrors.** `raw.githubusercontent.com` is unreachable from
  the user's server — the TLS handshake breaks. Redirect-based mirrors are excluded
  deliberately: OC doesn't follow a redirect that changes host and would save the HTML.
- `tools/sensordump.lua` prints **all** components, not just `gt_*` — otherwise the two most
  important cases (a machine not exposed to the network / an unknown type) looked the same:
  an empty screen.
- Fixed: a disabled buffer disappeared from the list forever and couldn't be re-enabled.

## 1.0.0 — first release

The graphics layer was taken from the predecessor project (provenance — in
[NOTICE.md](NOTICE.md)); everything else (multiblocks, infusions, fluids, the server network)
was cut, the data layer and the panel were written anew.

- **All types of energy buffers**: LSC, Battery Buffer, wireless EU network, IC2 storages,
  and any GregTech block with an EU reserve via a universal adapter. The type is determined
  by **scoring**, not by component type: an LSC and an energy hatch are both `gt_machine` and
  differ only by the sensor strings.
- **Two outputs at once** — the monitor and the AR glasses, independently of each other.
- **Switching and aggregation**: a specific buffer, the sum of all, or a cyclic rotation.
- Metrics: EU/t, 5-minute and hour averages, time to full/empty, passive loss, maintenance
  status. A charge graph.
- Component auto-detection, `Rescan`.

Key decisions found while digging through the GT5U `5.09.51.482` sources:

- **Parsing by labels, not by indices.** A naive parse takes `[2]`, `[5]`, `[23]` — an addon
  inserts a string, and instead of an error you get silently wrong numbers.
- **Precision.** On an LSC the charge is a BigInteger, but `getEUVar()` does `longValue()`,
  which **truncates**: above 2^63 `getEUStored()` lies (fixed only in 2.9). Plus Lua numbers
  are doubles, above 2^53 the value is not representable. The charge is stored both as a
  number and as an exact string.
- **The rate is measured by the change in charge**, not "IN minus OUT": it works even for IC2
  storages, which don't report energy throughput, and it accounts for passive loss.
- The typical bugs of a naive implementation are avoided: otherwise a Battery Buffer wouldn't
  be detected (`component.list()` is keyed by the full UUID, not the shortened address);
  table-states would break after serialization; the sign is preserved in `getInteger`.
- **Hardware requirements are lower**: instead of rendering through video-memory buffers
  (GPU T3), ARGUS draws directly (double buffering came back optionally in 1.4.0).
