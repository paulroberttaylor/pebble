# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Pebble is a native macOS voxel survival game (an open-source re-creation of Minecraft: Java Edition 1.20) written in ~45,000 lines of Swift + Metal with **zero external dependencies** (Apple frameworks only). There is no `.xcodeproj` and never will be — the entire workflow is SwiftPM plus the `./pebble` CLI.

## Commands

```bash
swift build                      # debug build (~35s clean)
swift build -c release           # release build — MUST be zero warnings before any PR
swift run -c release pebsmoke    # the golden test suite — MUST print "456 passed, 0 failed"
./pebble test                    # same suite via the CLI (runs from repo root)
./pebble install                 # build + bundle + install ~/Applications/Pebble.app, link `pebble` on PATH
swift run -c release Pebble      # run the app straight from the checkout
```

There is no per-test runner — `pebsmoke` runs all 456 checks across 16 suites every time. Goldens are loaded relative to the current working directory, so always run from the repo root.

### Runtime env vars for testing/automation (no manual clicking needed)

- `PEBBLE_AUTOLOAD=1` — skip menus, load most recent world; `PEBBLE_NEWWORLD=<seed>` — fresh world with that seed
- `PEBBLE_CMD="/tp 0 120 0;/time set 1000"` — run chat commands once world is up
- `PEBBLE_SHOT="/tmp/x.png@300"` — capture a frame N frames after load
- `PEBBLE_BOT=1` — run the physics-validation bot through the real input path (asserts walk/sprint/jump/fall numbers)
- `PEBBLE_PHOTOBOOTH=1` (`PEBBLE_BOOTH_MOBS=cow,sheep` / `PEBBLE_BOOTH_BLOCKS=-`) — render every mob/block to PNGs
- `PEBBLE_PROF=1` — per-stage load/tick timings
- `PEBBLE_REGOLD=1` — **rewrites golden baselines**; see the golden workflow below before using

## Architecture

Three SwiftPM targets with a strict one-way boundary (see `ARCHITECTURE.md` for the full tour):

- **`PebbleCore`** (`Sources/PebbleCore/`) — the headless, fully deterministic game engine. **No AppKit/Metal imports anywhere.** It never draws, plays audio, or reads input directly.
- **`Pebble`** (`Sources/Pebble/`) — the macOS app shell: NSWindow + MTKView, the hand-written Metal renderer, the runtime audio synthesizer, the UI stack, input.
- **`pebsmoke`** (`Sources/pebsmoke/`) — the regression harness that pins the engine to `goldens/*.json`.

The app talks to the engine **only** through the `GameHost` protocol (openScreen, playSound, addParticles, mesh upload, chunk requests). Engine subdirs: `Core/` (determinism layer), `World/`, `Gen/`, `Entity/`, `Items/`, `Systems/`, `Render/` (mesh + atlas data, no Metal), `Game/` (GameCore tick orchestrator + SQLite saves).

`GameCore` ticks at a fixed 20 Hz. Worldgen runs off-main on a concurrent queue; chunks are published to the world only via `adoptChunk` on the main thread. Renderer MSL is compiled at runtime (SPM doesn't build `.metal` files). All persistence is one SQLite database at `~/Library/Application Support/Pebble/pebble.db`.

## Load-bearing conventions (these break worlds or determinism, not just style)

The test suite enforces a hard determinism contract: same seed → bit-identical world on any machine, across releases. The following are not optional:

- **Registration order is ABI.** Blocks, items, biomes, and enchantments get their numeric ids from registration order, and those ids live in every saved world. Never insert, remove, or reorder registrations — **append new entries at the end**, after the frozen baseline range (`BASE_ITEM_COUNT` in pebsmoke covers only the prefix).
- **Sim code uses the deterministic layer only.** `detSin/detCos/detAtan2` (never `Foundation.sin` in sim paths — fdlibm port in `Core/DetMath.swift`), `RandomX`/`hash2`/`hash3` (never `Double.random`; cosmetic-only exceptions exist in app-side render/audio), `detRound` for half-step rounding.
- **No unordered iteration in sim decisions.** Swift `Dictionary`/`Set` iteration order is hash-seeded per process. Use insertion-ordered arrays (see `tickingBEList`) or `.sorted()` if order can affect world state.
- **Structure-piece RNG: draw, then check.** Builder RNG must be a pure function of (structure, piece). Draw every random value *before* any chunk-relative `b.get()` test — every chunk within range re-runs the plan, so short-circuiting on local contents desyncs the stream. Note `b.get()` returns **−1 outside the building chunk**; guard before casting.
- **Threading.** AppKit/renderer state is main-thread-only. Saves go through the serial save queue. The audio render thread owns the voice list (talk to it via the inbox). One-time registration uses `let`-initialized globals, not boolean guards. GPU buffers the CPU rewrites per frame are ring-buffered 3-deep (UICanvas, particles) or staged through blit encoders (atlas animation) — the renderer has no semaphore, relying on the 3-drawable limit.
- **Version string** lives in `PEBBLE_VERSION` (`PebbleCore/Game/Saves.swift`) plus `packaging/Info.plist` — bump both.

## Golden workflow

`goldens/*.json` pin engine behavior. Two categories:

- **Frozen reference goldens** (`atlas`, `fmath`, `items`) — immutable, no generator. If your change breaks one, **your change is wrong.**
- **Native baselines** (`biome`, `terrain`, `feature`, `mesh`, `worldsim`, `entity`, `systems`) — regenerable with `PEBBLE_REGOLD=1 swift run -c release pebsmoke`, but **only for deliberate behavior changes**.

Procedure for an intentional behavior change: make the change, run the suite, read *every* failure and explain why your change moved that value, then regold and confirm green. `PEBBLE_REGOLD` rewrites whole files and JSON key order shuffles, so byte diffs lie — compare semantically (`python3 -c 'import json; print(json.load(open("a"))==json.load(open("b")))'`) and confirm only expected files changed. Never blanket-regold red→green.
