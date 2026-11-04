# KWS audio frontend

`kws_frontend.cpp` exposes a frame-at-a-time, no-heap TFLM micro_speech frontend for the SoC firmware. It accepts a signed PCM16 frame of 480 samples and returns one 40-byte int8 feature row. The application assembles the 480-sample frame and advances it by 320 samples (20 ms at 16 kHz); the frontend keeps spectral-subtraction state across consecutive frames. Call `kws_frontend_reset()` after a detected audio gap or FIFO overrun.

The implementation uses the pinned TFLM Signal integer operations under `references/kws-signal-port-230c9/`, with the K2 fix that skips filter-bank scratch element zero. Its parameters are emitted from `verification/kws/k2/frontend/params.bin` by `tools/kws/emit_frontend_params.py`. The expected model input remains 49 rows × 40 channels = 1,960 bytes and is assembled by the application.

The historical K3 parity run executed the pinned pipeline under QEMU RV32I; that is target-ISA evidence, not Pangu hardware or microphone evidence. This change separately cross-compiles the SoC-callable library for RV32IM and checks host output against four fixed 49-frame vectors. The W3 live application and frontend now link together into one RV32IM/Zicsr image with the project 64 KiB ROM/RAM linker layout. This proves compile/link compatibility only; CPU-driven audio-to-inference operation remains a separate full-system simulation gate.

## W3 live application image

From the repository root, run:

```powershell
python verification/kws/audio/build_live_app_rv32.py --out-dir build/w3-kws-live
```

The command writes `w3_kws_live.elf`, its map and binary, `kws_live.hex` in little-endian 32-bit `$readmemh` word format, and a manifest with artifact sizes and SHA-256 hashes. The ROM image is checked against the linker's declared 64 KiB capacity. Pass `build/w3-kws-live/kws_live.hex` as the system ROM initialization file for simulation. Generated outputs are local build artifacts and are not committed.
