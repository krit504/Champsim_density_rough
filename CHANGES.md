# Write Hammer — ChampSim STT-RAM Implementation Changes

## Overview

Two-phase implementation on top of the base ChampSim STT-RAM simulator (`master` branch).

- **Phase 1 (branch: `Writehammer`)** — Section-based write bypassing (static + dynamic). Confirmed dead end per Prof. Sinha — kept for paper analysis.
- **Phase 2 (branch: `core-throttle`)** — Per-core write counter + attacker starvation/throttling. Current active work.

---

## Phase 1 — Section-Based Write Bypassing (`Writehammer` branch)

### What it does

The LLC sets are divided into N sections (default 10, max 64). Each epoch (100K instructions), one section is "blocked". Writes targeting the blocked section are redirected to DRAM instead of STT-RAM — reducing wear on that section's cells.

Two strategies implemented:

- **Static bypass**: Blocked section rotates round-robin each epoch (0 → 1 → 2 → ... → 9 → 0).
- **Dynamic bypass**: Each epoch, the section with the highest write count this epoch is blocked next — chases the hottest writer.

### Files changed

**`inc/champsim.h`**
- Added `#define LLC_BYPASS` — compile-time gate for all bypass logic
- Added `#define NUM_SECTIONS 10` — active section count
- Added `#define MAX_SECTIONS 64` — array bound (allows reconfiguration without recompile)
- Added `#define EPOCH_INSTRUCTIONS 100000` — 100K instructions per epoch

**`inc/cache.h`** — new CACHE members:
```cpp
uint64_t section_write_count[MAX_SECTIONS];  // per-epoch writes per section
uint64_t section_write_total[MAX_SECTIONS];  // cumulative writes per section (all epochs)
uint32_t current_blocked_section;            // section currently bypassed
uint32_t num_sections;                       // active section count
uint32_t current_epoch;                      // epoch index (0-based)
uint64_t bypassed_writes;                    // total writes successfully redirected to DRAM
```

**`src/cache.cc`** — `handle_writeback()`:
- **HIT path**: detects if write targets blocked section → sends to DRAM WQ, invalidates LLC block, counts bypass. Non-blocked writes counted and proceed normally.
- **MISS path**: same detection before `find_victim`. Non-blocked MISS count deferred until after `do_fill` succeeds to avoid double-counting on dirty-victim stall retries.
- Section tracking (`section_write_count`, `section_write_total`) always active regardless of `LLC_BYPASS` — needed for baseline comparison.

**`src/main.cc`** — epoch boundary handler:
- Fires every `EPOCH_INSTRUCTIONS` sim instructions after warmup
- Prints per-section write counts (epoch + cumulative), `[BLOCKED]` and `[NEXT]` tags
- **Static**: increments `current_blocked_section = (current + 1) % num_sections`
- **Dynamic**: scans `section_write_count[]`, picks max, sets that as next blocked section
- Resets `section_write_count[]` each epoch
- Final stats: per-section `total_writes`, `bypassed_writes`, LIFETIME METRIC (`max_writes`, `avg_writes`, `interV_coeff`, `lifetime_norm`)

**`Makefile`**:
- Added `.DEFAULT_GOAL := all` — prevents `-include` dep files from hijacking the default goal
- Added `-include $(objects:.o=.d)` — proper dependency tracking so header changes trigger recompilation (fixes the stale-build segfault)

### Key bugs fixed

| Bug | Symptom | Fix |
|-----|---------|-----|
| Stale build (missing dep tracking) | Segfault (exit 139) after header-only changes | Added `-include $(objects:.o=.d)` to Makefile |
| Default goal hijack | `make` built `obj/src/uncore.o` instead of `champsim` | Added `.DEFAULT_GOAL := all` |
| Double-counting on MISS stall retry | Section counts inflated on dirty-victim stalls | Deferred count to after `do_fill` succeeds |
| All-zero baseline section totals | Section tracking was entirely inside `#ifdef LLC_BYPASS` | Moved section computation outside `#ifdef`; only actual bypass routing (add_wq, invalidate, stall, return) inside |

### Experimental results

4-core runs (warmup=10M, sim=250M) across four trace combinations: `v2×4`, `v3×4`, `v4×4`, `v4×3+bc12`.

Key finding: dynamic bypass intercepts more writes than static on traces with stable hot sections (v2, v4) but performs worse on v3 (shifting hot sections — dynamic chases a moving target, static spreads evenly). Results stored in `results/`.

**Conclusion (per Prof. Sinha):** Bypassing is a dead end — redirected writes still cause RWQ congestion and endurance issues elsewhere. Approach documented for the paper's "why bypassing fails" section.

---

## Phase 2 — Per-Core Write Counter + Attacker Starvation (`core-throttle` branch)

### What it does

Instead of bypassing writes by section, identify the attacking core using per-core write counters and **starve** it — throttle its writes at the LLC so the STT-RAM RWQ is no longer flooded with bogus writes. Benign cores' IPC rises because RWQ contention drops.

**Detection**: after 1M sim instructions, the core with the highest cumulative LLC writeback count is locked as `attacker_core`.

**Throttle**: 1-in-`THROTTLE_RATIO` (default 10) writes from the attacker core are allowed through. The other 9-in-10 are either stalled or dropped (two experiment modes, switched via `#define THROTTLE_DROP`).

### Files changed

**`inc/champsim.h`**:
- `#define LLC_BYPASS` commented out — bypass disabled on this branch (code kept for paper)
- Added:
```cpp
#define CORE_THROTTLE          // gate for throttle logic
#define THROTTLE_RATIO 10      // 1-in-N writes allowed from attacker
#define DETECTION_INSTR 1000000 // lock attacker after this many sim instructions
//#define THROTTLE_DROP          // comment in for drop mode; comment out for stall mode
```

**`inc/cache.h`** — new CACHE members:
```cpp
uint64_t core_write_count[NUM_CPUS];  // per-epoch LLC writebacks per core
uint64_t core_write_total[NUM_CPUS];  // cumulative LLC writebacks per core
int      attacker_core;               // detected attacker core index (-1 = not yet detected)
uint64_t core_writes_seen[NUM_CPUS];  // per-core counter for 1-in-N throttle gating
```

**`src/cache.cc`** — `handle_writeback()`:

*Counter* (both HIT and MISS paths, always active):
```cpp
core_write_count[writeback_cpu]++;
core_write_total[writeback_cpu]++;
```
Placed at the same points as `section_write_count` increments. MISS path uses the same deferred placement (after `do_fill`) to avoid double-counting.

*Throttle* (`#ifdef CORE_THROTTLE`, HIT and MISS paths):
```cpp
if ((int)writeback_cpu == attacker_core) {
    if ((core_writes_seen[writeback_cpu]++ % THROTTLE_RATIO) != 0) {
#ifdef THROTTLE_DROP
        WQ.remove_queue(&WQ.entry[index]);  // drop: never reaches DRAM RWQ
        return;
#else
        STALL[WQ.entry[index].type]++;      // stall: backs up attacker pipeline
        return;
#endif
    }
}
```

**`src/main.cc`** — epoch boundary handler additions:

*Detection* (one-time, fires when `sim_instr >= DETECTION_INSTR` and `attacker_core == -1`):
```cpp
// picks core with max core_write_total[], sets attacker_core, prints detection banner
```

*Per-core epoch print*: each epoch prints `core_write_count[c]` (epoch) and `core_write_total[c]` (cumulative) per core, with `[ATTACKER-THROTTLED]` tag on the detected core. Resets `core_write_count[c] = 0`.

*Final stats*: prints `core_write_total[c]` per core at end of simulation.

### Running the two throttle experiments

**Stall mode** (default — `THROTTLE_DROP` commented out):
```bash
make clean && make -j$(nproc)
./bin/champsim -warmup_instructions 10000000 -simulation_instructions 250000000 \
  -traces <attack> <attack> <attack> <benign>
```

**Drop mode** (uncomment `#define THROTTLE_DROP` in `inc/champsim.h`):
```bash
# edit inc/champsim.h: uncomment //#define THROTTLE_DROP
make clean && make -j$(nproc)
./bin/champsim ...same traces...
```

### Expected output signature

At epoch 9 (~1M sim instructions):
```
*** ATTACKER DETECTED: Core N (total writes=XXXXX) — throttle ACTIVE ***
```
Every subsequent epoch:
```
Core N  epoch=XXXX  total=XXXXXXX  [ATTACKER-THROTTLED]
```

### What's pending (needs Prof. Sinha input)

- **Threshold policy**: currently locks the max-write core unconditionally. Prof to provide threshold (absolute count or relative to other cores) to avoid false positives on legitimate high-write workloads.
- **Detection policy**: currently detect-once-and-lock. Prof may want per-epoch re-evaluation (adaptive).

---

## Branch summary

| Branch | Purpose | Status |
|--------|---------|--------|
| `master` | Base simulator (unmodified) | Unchanged |
| `Writehammer` | Phase 1: section bypass (static + dynamic) | Complete — kept for paper |
| `core-throttle` | Phase 2: per-core counter + starvation | Active development |
