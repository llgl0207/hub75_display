?# Design Report Material

## Project Status

This is a living report scaffold for a competition project. Project title and application-specific problem statement remain **TBD by the team**. The selected repository license is MIT (`LICENSE`). The **board-tested** increment is still a PL-only closed-loop scan: HUB75 slice timing is derived from the measured revolution period and restarts at slice 0 on every infrared trigger. Board observations exist for the static pattern (T001), the multiple-edges-per-illumination defect (T003) and the 1 ms debounce fix (T004); angular lock on a spinning rig is still TBD.

A **separate PS+DDR build** now exists (`build/build_ps_system.tcl`, `src/hub75_ddr_reader.v`, `src/hub75_slice_ram.v`, `system_top`): Zynq PS7 with UART0/DDR3/FCLK, AXI GPIO control/status, S_AXI_HP0 AXI3 reader, packed 6-bit slice RAM ping-pong, and a Vitis bare-metal renderer source under `sw/`. It compiles (WNS +6.401 ns, WHS +0.035 ns, DRC 0 errors, 2240 LUT, 2 BRAM36) and passes seven RTL testbenches, but the Vitis platform/application build and the DDR-image board test are **not yet executed**. It is not a complete volumetric display: frame format is 64 slices first, and the 400-slice capacity, 76-slot geometry and second-half mirroring remain future work.

## Background and Innovation

**Application background (TBD):** document the target users, mechanical setup, use case and problem being solved after the team supplies the final statement.

**Current engineering contribution:** use a 128x64 1/32 HUB75 panel as the output plane of a rotating volumetric display. A single revolution-reference IR sensor aligns angular scheduling. The PL owns all real-time scan timing and DDR fetches; PS/Linux produces the next volume frame and submits it outside the real-time scan path. The first PS+DDR implementation uses 64 independent slices per revolution and A/B DDR buffers; the intended 400-slice half-revolution storage and mirrored second-half readout remain future work.

The PL+DDR RTL and a bare-metal Vitis renderer now exist and compile/simulate, but they are not proof that DDR-backed volumetric scanning has been demonstrated on hardware. The board-tested evidence is still the PL-only scan.

**PS/PL contract (first version):** PS writes `frame_base` (AXI GPIO ctrl ch1) and `frame_ctrl` (ch2: submit toggle, enable, slice count), then reads `status` (frame_ack, reader_busy, buf_ready, frame_done, active slice, frame_id) and `period`. The PL latches a new base only at `revolution_start`; the PS waits for the frame-done toggle before rewriting a buffer. The PL reader prefetches one 3072-byte slice per slot over 16-beat AXI3 bursts through S_AXI_HP0, unpacks 6-bit pixels and writes the inactive 4096x6 BRAM.

## Design Principle and Block Diagram

```text
IR digital input (JP1-33/U13)
          |
          v
2-FF synchronizer -> debounce 1 ms -> hold-off 1 ms -> 5-interval rolling mean
                                                       |      (period_ticks)
                                                       +--> diagnostic LEDs/UART
                                                       |
                                                       v
                                          hub75_sched: revolution period -> 64
                                          slots/revolution and 32 row budgets,
                                          slice 0 restart on every trigger
                                                       |
                                                       v
                                          hub75_scan: one slot at a time,
                                          128 pixel clocks x 32 addresses
                                                       |
                                                       v
                                                  HUB75 panel

PS+DDR build (implemented and simulated, not board-verified):
PS bare-metal renderer -> DDR frame A/B -> PL AXI3 reader on S_AXI_HP0
                                         -> 2 x 4096x6 slice RAM ping-pong -> hub75_scan
PL-only board-tested build: display pattern generated inside PL from the slice index.
```

Current outputs: HUB75 RGB1/RGB2, CLK, LAT, OE and 5-bit row address. Diagnostic paths: four active-low board LEDs, 115200 8N1 TX on JP1-35/V12, and the PS UART1 console on MIO48/49 (the onboard CP2102 is wired to UART1 on this board; UART0/MIO14/15 is silent). The PS-facing frame-submit interface exists only in the separate PS+DDR build; the PL-only board-tested image still generates its pattern from the slice index so the rotational time base can be checked first.

## Hardware/Software Partition Rationale

The display scan and IR timing are tied to mechanical angle, so Linux scheduling must not generate HUB75 pixel clocks or per-slice events. The eventual PS role is to render into a non-active DDR buffer, make CPU writes visible to PL DMA/AXI, then submit a completed buffer. The eventual PL role is to select the submitted base atomically at the chosen revolution boundary and preserve scan operation independently of PS scheduling.

The PL-only board-test image has no PS7 block; it is loaded via JTAG to volatile PL configuration, and its ZPS7-1 DRC warning is expected. The separate PS+DDR build contains the PS7, AXI GPIO control/status and S_AXI_HP0 reader; it is also JTAG-loaded (bitstream + ELF), with the PS UART1 console on MIO48/49. Its DRC has zero errors and no ZPS7-1 warning.

## Current Interface Decisions

| Interface | Current definition | Status |
|---|---|---|
| PL clock | 50 MHz from board clock pin H16 | Constraint present; board variant still to confirm |
| IR input | GPIO1_14P, JP1-33, U13, LVCMOS33 | Provisional until exact board revision is checked |
| Trigger | Rising edge default; synthesis parameter allows falling edge | RTL simulation verified both |
| IR conditioning | Fixed 1 ms debounce window plus 1 ms hold-off window (`IR_DEBOUNCE_US`, `IR_HOLDOFF_US`) | RTL simulation verified; the 1 ms values are a team requirement after a board observation of multiple edges per illumination, not yet re-verified on hardware |
| Period estimate | Mean of most recent five complete intervals; timestamp taken at the accepted edge, so the debounce delay does not enter the estimate | RTL simulation verified; period valid after six triggers |
| Diagnostic UART | 115200, 8N1, 10-byte snapshot packet | RTL simulation verified; physical adapter test TBD |
| Slice scheduling | `hub75_sched` converts the averaged period into 64 slots per revolution (`SLOT_LOG2=6`) and 32 row budgets per slot, restarts slice 0 on every trigger, and falls back to a 1800 RPM equivalent until five intervals exist. All divisions are shifts. | RTL simulation verified; on-board angular lock TBD |
| HUB75 timing | 128 clocks x 32 addresses per slot; the slot and row budgets follow the measured period instead of a fixed field rate (1920 full-panel scans/s at 1800 RPM) | RTL and implementation checks done; panel waveforms/brightness and actual scan rate TBD |
| DDR/AXI | PS7 DDR3 1 GB 32-bit; S_AXI_HP0 AXI3, 64-bit data, 6-bit ID, 16-beat bursts; PS GP0 -> AXI interconnect -> two AXI GPIOs | BD built; RTL reader simulated; DDR memtest and board readback TBD |
| PS console | UART1 on MIO48/49, 115200 8N1, onboard CP2102 (the vendor table's UART0/MIO14/15 is silent on this board) | Verified on board: banner, `DDR PASS`, advancing `frame` log |
| PS clock / PL clock | 33.333 MHz PS crystal; FCLK_CLK0 50 MHz feeds the PS+DDR PL logic; H16 50 MHz is used only by the PL-only build | Built; board clock check TBD |
| PS control/status | AXI GPIO ctrl @0x41200000 (frame_base, submit/enable/slice count), status @0x41210000 (ack/busy/buf_ready/frame_done/slice/frame_id, period) | Built; board handshake verified: `frame_done`/`frame_id` advance and `status` slice changes |
| Display pattern | PL-only: generated from slice index (`PATTERN_MODE=0/1/2`). PS+DDR: `PATTERN_MODE=3` reads 6-bit words from slice RAM; the PS renderer draws slice 0 white and a moving red/blue bar on the two halves. | PL-only board-verified; PS frame content verified in DDR (slice 0 white, slice 1 bar); panel photo pending |
| Frame submit | PS writes frame_base, reads it back, then toggles submit; PL latches the base only at `revolution_start`; PS waits for frame_done before reusing a buffer | RTL simulation verified in `tb_hub75_ddr_reader`; board TBD |
| Frame format | 64 slices x 3072 B; 32 row addresses x 128 columns x 6-bit word; `[2:0]=rgb1`, `[5:3]=rgb2`; LSB-first packing; A/B at 0x10000000/0x10200000 | Frozen for the first PS version; 400-slice/76-slot/mirroring TBD |

## Optimization and Resource Comparison

There is not yet a controlled before/after comparison on identical constraints. Report available data without presenting it as a comparative optimization claim.

| Build | Tool/target | LUT | FF | BRAM | DSP | Setup WNS | Hold WHS | Status |
|---|---|---:|---:|---:|---:|---:|---:|---|
| Standalone IR capture module | Vivado 2026.1, XC7Z020CLG400-2, 50 MHz | 657 | 339 | 0 | 0 | +9.207 ns estimated pre-route | +0.037 ns estimated pre-route | Synth/opt only |
| Static scan + IR + UART board-test top | Vivado 2026.1, XC7Z020CLG400-2, 50 MHz | 809 | 531 | 0 | 0 | +6.359 ns routed | +0.129 ns routed | Bitstream generated; board measurements TBD |
| Same top with the 1 ms debounce plus 1 ms hold-off | Vivado 2026.1, XC7Z020CLG400-2, 50 MHz | 856 | 600 | 0 | 0 | +6.210 ns routed | +0.105 ns routed | Superseded; debounce board-verified (T004) |
| Closed loop: `hub75_sched` + slot-driven `hub75_scan` | Vivado 2026.1, XC7Z020CLG400-2, 50 MHz | 970 | 688 | 0 | 0 | +6.008 ns routed | +0.130 ns routed | PL-only build; angular-lock board test TBD |
| PS Stage 0: PS7 only (UART0 + DDR3 + FCLK) | Vivado 2026.1, XC7Z020CLG400-2, PS 33.333 MHz / FCLK 50 MHz | 0 | 0 | 0 | 0 | no user paths | no user paths | Bitstream/XSA generated; UART/DDR board test TBD |
| PS Stage 1: PS7 + AXI GPIO + HP0 + DDR reader + slice RAM + HUB75 | Vivado 2026.1, XC7Z020CLG400-2, PS 33.333 MHz / FCLK 50 MHz | 2240 | 2723 | 2 | 0 | +6.401 ns routed | +0.035 ns routed | Bitstream/XSA generated; RTL 7/7 PASS; board test TBD |

The board-test report has 19 output ports without output-delay models. WNS/WHS cover internal constraints and are not full HUB75 panel-interface timing signoff; the PS Stage 1 HUB75 outputs have the same limitation. ILA insertion was not possible under the local BASIC license. The PL-only DRC has no errors and reports the ZPS7-1 warning because that top contains no PS7; the PS Stage 1 DRC has zero errors. The Stage 1 worst hold path is inside the AXI GPIO input synchronizer (+0.035 ns MET), not user logic.

The `PATTERN_MODE=2` diagnostic build (same logic, simpler pixel generator) measured 959 LUT, 678 FF, WNS +6.722 ns, WHS +0.138 ns. It exists to answer one hardware question, not as a performance point.

A meaningful optimization comparison requires a baseline and candidate build with matching target part, constraints, tool version and reporting commands. Such an experiment is TBD.

## Performance Metrics

| Metric | Current status |
|---|---|
| Full-panel scan rate | Derived from the measured revolution period: 64 slots/revolution, i.e. 1920 scans/s at 1800 RPM. Configured, not physically measured |
| HUB75 pixel CLK waveform frequency | TBD; 10 MHz by divider setting, not measured at the connector under load |
| IR period accuracy / jitter | RTL ideal-stimulus test only; physical measurement TBD |
| Target volume refresh | 30 fps / 1800 RPM design target, not achieved |
| Active slices at 30 fps under 2280 full scans/s | Budget predicts 38 stored slices per half revolution when DDR arrives; the current PL-generated pattern uses 64 independent slots |
| Angular lock against the mechanical rotor | TBD; acceptance criterion is a drift of at most one slot (5.6 degrees) between 60 and 300 RPM |
| Display brightness/ghosting/thermal behavior | TBD on powered panel; OE duty is about 2.6 percent of the row budget at 1800 RPM because the 643-cycle shift overhead is fixed |
| DDR read bandwidth, service latency and buffering margin | TBD; no DDR reader yet |

## Repository Structure and Naming Compliance

### Required layout (competition brief)

```text
<project_name>/
  README.md      project intro + from-scratch reproduction steps
  src/           RTL / HLS / PS source
  sim/           simulation or verification scripts and results
  build/         reproducible build scripts, synthesis and implementation reports
  board/         board bring-up project, run scripts, measured output
  data/          test data and reference results
  skill/         skill package, including README.md
  report/        design report + LLM collaboration record
```

Naming rule: directory names and file names must use **only ASCII lowercase letters, digits, underscore or hyphen** — no Chinese, spaces or special characters. Chinese text is allowed **only inside file content**.

### Actual mapping in this repository

| Required | Present | Contents |
|---|---|---|
| `<project_name>/` | `hub75_display/` | repository root; also holds the Vivado entry project `hub75_display.xpr` |
| `README.md` | yes | project summary, tool version, reproduction commands, status/TBD statements |
| `src/` | yes | `hub75_top.v`, `hub75_scan.v`, `ir_revolution_sync.v`, `ir_debug_uart.v` |
| `sim/` | yes | 3 testbenches, `run_regression.tcl`, `simulate_*.tcl`, generated work area under `sim/output/` (git-ignored) |
| `build/` | yes | `add_sources.tcl`, `build_board_test.tcl`, `check_ir_synthesis.tcl`, `check_project.tcl`, `check_scripts.tcl`, `probe_hw.tcl`, `program_board.tcl`, `verify_bitstream.tcl`, `inspect_hw_props.tcl`, `capture_uart.ps1`; reports under `build/reports/` |
| `board/` | yes | `board_test_procedure.md`, `constraints/*.xdc`, `output/hub75_ir_test.bit` |
| `data/` | yes | `board_test_log.csv` (measured observations), `README.md`; UART capture outputs are written here |
| `skill/` | yes | `README.md`; extraction intentionally deferred per team decision |
| `report/` | yes | `design_report.md`, `ai_collaboration.md`, `ir_development_and_test.md`, `hub75_panel_reference_cn.md`, `handover.md` |

**Deliberate deviation:** the Vivado `.xpr` stays at the repository root instead of inside `build/` or `board/`, because a Vivado project embeds relative paths to its sources; keeping it at the root avoids duplicated copies of RTL and keeps `src/` the single source of truth. `build/build_board_test.tcl` is the reproducible, GUI-independent path and does not read the `.xpr` at all.

Generated artefacts are excluded from version control: `hub75_display.runs/`, `.sim/`, `.cache/`, `.hw/`, `.ip_user_files/`, `build/work/`, `sim/output/`, `*.dcp`, `*.jou`, `*.log`. The delivered bitstream `board/output/hub75_ir_test.bit` is kept so the board test can be reproduced without a rebuild.

## Reproduction and Test Evidence

From the organized English-only layout, Vivado 2026.1 was run from the repository root:

- `vivado -mode batch -source sim/run_regression.tcl`: PASS for static scan (32 rows x 128 clocks and RGB setup guard), slice scheduling (64 slots per revolution, trigger anchor to slice 0, period latching, clamps, fallback), IR estimator (five-interval warmup/window eviction/wrap/reset/both polarities), IR input conditioning (chatter rejection, in-pulse dropout, under-width rejection, period accuracy, hold-off, reset seeding) and UART byte packet decode. The runner now reads each simulation transcript and fails the run when a testbench prints no PASS line or trips a `$fatal`/`$error`; a quiet `run all` is not treated as success. Run products and log are under `sim/output/regression/`.
- `vivado -mode batch -source build/build_board_test.tcl`: PASS. The script recreated the board-test top from `src/` and `board/constraints/`, completed place/route and generated `board/output/hub75_ir_test.bit`. Reports are under `build/reports/`.
- Current regenerated implementation report: 50 MHz clock, setup WNS +6.008 ns, hold WHS +0.130 ns, zero internal failing endpoints. DRC has zero errors and the expected ZPS7-1 warning (PS7 absent in this PL-only JTAG image). Utilization is 970 LUT, 688 FF, 0 BRAM and 0 DSP; the scheduler plus the slot-driven scanner added 114 LUT and 88 FF over the debounce-only 856/600 build.
- The final report identifies 19 ports without external output-delay constraints. CDC reporting skips the asynchronous external sensor port. These results do not sign off board/panel IO timing.

`data/board_test_log.csv` holds the hardware observations: T001 static panel evidence, T003 the multiple-edges-per-illumination defect, T004 the accepted debounce/hold-off result (sixth occlusion lights D8, earlier ones must stay dark). Angular lock is still TBD. Do not infer board behaviour from RTL simulation or implementation reports.

## Remaining Work

1. Confirm exact board revision, package speed grade, panel adapter mapping, IR sensor output levels and whether the physical input really goes to JP1-33/U13.
2. Verify angular lock on the rig: the slice-0 white anchor must hold a fixed mechanical azimuth between 60 and 300 RPM, drift at most one slot.
3. Measure HUB75 CLK/LAT/OE/address timing and actual full-panel scan rate at the connector with a logic analyzer or oscilloscope. Check brightness (about 2.6 percent OE duty at 1800 RPM) and ghosting on the panel.
4. Framebuffer bit order/stride is now frozen for the first PS version (64 slices, 3072 B/slice, 6-bit words, A/B at 0x10000000/0x10200000); the PL AXI read master and slice-BRAM ping-pong exist and pass RTL simulation. Still TBD: board DDR memtest, frame handoff on hardware, and the 400-slice/76-slot/mirroring extension.
5. `tb_hub75_scan_mem` and `tb_hub75_ddr_reader` cover the memory-mode pixel order and the DDR burst/unpack writes. Still TBD: second-half column reversal, frame switching under AXI backpressure, and an AXI VIP-based stress test.
6. The bare-metal Vitis renderer source and GUI steps are in `sw/`; the platform/application build and board run are TBD. A Linux/driver flow is deferred.
7. Rebuild and test the complete PL+PS system on the board; replace TBD with measured, reproducible values (UART log, DDR memtest, panel photos, frame rate, status words).
8. Review the MIT copyright-holder line with the team, and audit third-party dependencies/licenses before submission.

## Competition Submission Material To Complete

- Final title/problem statement and application scenario: TBD by team.
- Innovation statement backed by comparison or measurement: TBD.
- Full PL/PS block diagram and interface table: first-version contracts are in this report and `report/ps_development.md`; board verification still TBD.
- Optimization results using identical baseline/candidate constraints: TBD.
- Photos/video, instrument setup and raw results: TBD.
- Reproduction validation by a clean checkout or a second machine: TBD.
- Team-selected license: MIT (`LICENSE`); confirm copyright-holder attribution before submission.
