# CoreMark project port

This directory contains the project-owned bare-metal port. The upstream CoreMark algorithm sources are not copied into this repository; the build script verifies and snapshots the pinned upstream source before compiling it.

## Pinned source and build

- Upstream: EEMBC CoreMark commit `1f483d5b8316753a742cbf5590caf5bd0a4e4777` (Apache-2.0).
- Builder: [`scripts/build_coremark_candidate.py`](../../scripts/build_coremark_candidate.py).
- The fixed acceptance profile is `-O2`; the seed mode, iteration count, ISA, timer frequency, compiler, flags, ELF, HEX, and hashes are recorded in the output `manifest.json`.
- The port reads the implemented machine `mcycle/mcycleh` CSRs using a high-low-high retry sequence. `CORE_TICKS` is 64-bit so long board runs do not wrap at 2^32 cycles.
- Since the timer uses CSR instructions, newly built images must enable Zicsr. For the dual M-mode core use `--march rv32im_zicsr`; the builder accepts the old `rv32im` spelling as an alias but records the effective ISA with Zicsr enabled. The ELF attributes are checked after compilation.
- `ee_printf` supports the upstream format strings plus `%llu` for full-width raw timer evidence. The upstream algorithm sources and validation CRCs remain unchanged.

## Timing output and score checks

CoreMark's pinned upstream reporter casts `Total ticks` to `unsigned long`, which is 32-bit on RV32. The port therefore emits a separate `PORT-RAW` line with 64-bit start, stop, and elapsed cycle counts. Candidate parsers cross-check the low 32-bit upstream display, the raw counter delta, configured frequency, iteration count, and expected validation CRCs. A run is a formal performance result only when it passes the upstream validation and lasts at least 10 seconds.

The port does not itself establish physical clock frequency, PDS timing, or board success. Those require the exact-source PDS reports and board-run evidence.
