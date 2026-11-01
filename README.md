# Rotating Volumetric HUB75 Display

> Competition submission status: **in progress**. The verified PL-only closed-loop HUB75 scan is still the board-tested baseline. A separate PS+DDR build (Zynq PS7 + AXI GPIO + S_AXI_HP0 + slice RAM + AXI reader) now compiles, passes RTL simulation and runs on board: UART1 console, `DDR PASS`, advancing frame handshake and `buf_ready=1` are recorded. Panel photograph of the PS-rendered image is still TBD.

## Competition Metadata

| Field | Value |
|---|---|
| Competition | National College Student Embedded Chip and System Design Competition 2026, FPGA Innovation Design, Open Topic, Beginner Group |
| Project title | TBD by team |
| Application scenario | TBD by team; rotating volumetric HUB75 display is the current engineering direction |
| Board and exact device | Reported board: MIZAR R7; current Vivado target: XC7Z020CLG400-2. Exact board revision/silkscreen confirmation: TBD |
| Tool version | AMD Vivado 2026.1 (Windows), confirmed from local build logs |
| Implementation | Verilog RTL in PL plus a bare-metal Vitis renderer source under `sw/`. The PL-only board-test image (`build_board_test.tcl`) and the PS+DDR build (`build_ps_system.tcl`) are separate; the PS build runs on board (UART1 console, DDR memtest, frame handshake and `buf_ready` verified). |
| Software/hardware split | Intended: PL owns complete real-time display, DDR reads, scan and buffer handoff; PS/Linux renders DDR frames and submits completed buffers |
| License | MIT (`LICENSE`) |

## Current Verified Increment

The current bitstream is a **bring-up image**, not the competition-final function:

- 128x64 HUB75 1/32 scan driven one slot at a time: `hub75_sched` turns the averaged revolution period into 64 slots per revolution and 32 row budgets per slot, and restarts slice 0 on every infrared trigger.
- Synchronized IR edge capture with a fixed 1 ms debounce window and 1 ms hold-off window, selectable rising/falling edge, and rolling average of the last five complete revolution intervals.
- A PL-generated bring-up pattern (slice 0 full white as the angular anchor, other slices a moving red bar) so the rotational time base can be checked before any DDR path exists.
- Fixed 1800 RPM equivalent fallback until five intervals have been measured, so the panel scans while stationary.
- Active-low diagnostic LEDs and optional 115200 8N1 UART interval reporting.
- No ILA core: the local Vivado BASIC license rejected `create_debug_core`.
- The `hub75_ir_test.bit` image itself has no DDR reader, volumetric slice storage or frame-submit protocol. Those exist only in the separate PS+DDR build described next.

### PS+DDR increment (board-verified at the control/DDR level; panel photo TBD)

This is a separate build; it does not change `hub75_ir_test.bit`:

- `build/build_ps_system.tcl` creates the Zynq PS7 block design (UART0 on MIO14/15 and UART1 on MIO48/49, DDR3 1 GB, FCLK_CLK0 50 MHz, AXI GP0 control/status GPIOs, S_AXI_HP0), plus `hub75_ddr_reader`, `hub75_slice_ram`, `hub75_ps_top` and `system_top`. The onboard CP2102 is wired to UART1, not UART0.
- The reader prefetches one 3072-byte slice per display slot over 16-beat AXI3 bursts, unpacks the packed 6-bit pixels into two 4096x6 BRAM36 buffers, and switches buffers only at slot boundaries when the requested slice and frame epoch match.
- The PS frame base is accepted as pending and latched only at `revolution_start`; the PS waits for a frame-done toggle before reusing a buffer.
- First-version geometry is 64 slices/frame, frame A at `0x10000000` and frame B at `0x10200000`; 400-slice storage, 76 slots/revolution and second-half mirroring remain future work.
- Vitis renderer source is under `sw/`; `build/build_ps_system.tcl -tclargs 1` builds the hardware. The renderer now runs on board: `HUB75 PS renderer`, `DDR PASS`, one `frame ...` line per second, `status` bit2 (`buf_ready`) asserts after the first revolution, and `frame_id`/`frame_done` advance. The ping-pong handoff prefetches `slice_index+1` every slot; the earlier conditional prefetch deadlocked start-up and left the scan reading an empty BRAM (black panel). The panel photograph of the PS image is still TBD.

The 1 ms windows exist because the board showed several edges from one illumination. They are synthesis parameters (`IR_DEBOUNCE_US`, `IR_HOLDOFF_US` in `src/hub75_top.v`); changing them requires a rebuild. A pulse narrower than the debounce window is discarded, so the illuminated pulse at full speed must stay wider than 1 ms.

Scan geometry is set by `SLOT_LOG2=6` (64 slots per revolution), `ROW_LOG2=5` and `FALLBACK_RPM=1800`; `PATTERN_MODE=1` selects the bring-up pattern and `PATTERN_MODE=0` restores the verified colour bars. At 1800 RPM this gives 1920 full-panel scans per second, below the reported 2280 ceiling. See the status ledger in `report/design_report.md` and the live-board checklist in `board/board_test_procedure.md`.

## Repository Layout

```text
hub75_display/
  hub75_display.xpr       Vivado project entry point
  src/                    synthesizable RTL (PL-only top and PS+DDR top)
  sim/                    testbenches and regression scripts
  build/                  reproducible Tcl, PS7 BD builder, generated reports/work
  board/                  constraints, bitstreams, XSAs and board-test procedure
  sw/                     Vitis bare-metal renderer/hello sources and README
  data/                   measured data and reference captures; currently TBD
  report/                 design report, PS development log and AI collaboration log
  skill/                  skill package extraction; intentionally deferred until project completion
```

Generated Vivado cache/run outputs are not source. See `.gitignore`.

## Reproduce

### Prerequisites

- Windows host with Vivado 2026.1 and XC7Z020 device support installed.
- Confirm exact MIZAR board revision and I/O-bank voltage before connecting signals.
- The current project targets `xc7z020clg400-2`; change only after verifying the actual device speed grade.

### Run RTL regression

If `vivado` is not on `PATH`, use the wrapper, which finds the installation itself:

```powershell
.\build\vivado.ps1 sim\run_regression.tcl
```

Otherwise, from the repository root in a Vivado 2026.1 Tcl shell:

```powershell
vivado -mode batch -source sim/run_regression.tcl
```

Expected terminal markers include `PASS: tb_hub75_scan`, `PASS: tb_hub75_scan_mem`, `PASS: tb_hub75_ddr_reader`, `PASS: tb_hub75_sched`, `PASS: tb_ir_revolution_sync`, `PASS: tb_ir_debounce`, `PASS: tb_ir_debug_uart` and finally `REGRESSION_COMPLETE`. The runner calls `xvlog`/`xelab`/`xsim` by absolute path and reads each simulation transcript; it fails with a non-zero exit when a testbench prints no PASS line or trips a `$fatal`/`$error`. A quiet `run all` is not success.

### Validate the Vivado GUI project file list

```powershell
vivado -mode batch -source build/check_project.tcl
```

Expected marker: `PROJECT_PATHS_VALIDATED`. The check sources `build/add_sources.tcl` first, so any source added to `src/` is picked up before validation; run the same script from the Tcl Console after opening `hub75_display.xpr` if you work in the GUI, and save the project so the file list persists.

### Build a board-test bitstream and reports

```powershell
vivado -mode batch -source build/build_board_test.tcl
```

Expected marker: `BOARD_TEST_BUILD_COMPLETE`. Output locations:

- `board/output/hub75_ir_test.bit`
- `build/reports/timing.rpt`
- `build/reports/utilization.rpt`
- `build/reports/drc.rpt`
- `build/reports/cdc.rpt`
- `build/reports/io.rpt`

A successful internal timing report does not sign off HUB75 cable/panel timing. The PL-only project can retain a `ZPS7-1` DRC warning because it intentionally has no PS7 block; no PS boot image is generated.

### Build the PS+DDR system

Stage 0 proves PS boot, UART0 and DDR without any PL logic:

```powershell
.\build\vivado.ps1 build\build_ps_system.tcl
```

Stage 1 adds the AXI GPIO control/status, S_AXI_HP0 reader, slice RAM and HUB75 top:

```powershell
.\build\vivado.ps1 build\build_ps_system.tcl -TclArgs 1
```

Expected marker: `PS_SYSTEM_BUILD_COMPLETE stage=0|1`. Outputs:

- `board/output/hub75_ps_stage0.bit` / `.xsa` (PS only)
- `board/output/hub75_ps_stage1.bit` / `.xsa` (PS + DDR reader + HUB75)
- `build/reports/ps_stage0/` and `build/reports/ps_stage1/` (timing, utilization, DRC, CDC, IO)

The XSA is exported without a bitstream because the script uses the explicit
opt/place/route flow; select the matching `.bit` in the Vitis Run Configuration.
Stage 1 timing is WNS +6.401 ns / WHS +0.035 ns at 50 MHz, DRC 0 errors, and the
slice RAM maps to 2 BRAM36. See `report/ps_development.md` for the PS7 config,
frame format, AXI GPIO contract and the remaining board checks.

Vitis 2026.1 has XSCT disabled; create the platform/application in the GUI using
`board/output/hub75_ps_stage1.xsa`, add `sw/renderer/main.c` and `sw/common/*`,
and run with Program FPGA + Reset entire system. Full steps and troubleshooting
are in `sw/README.md`.

### Program and test the board (scripted)

There is no on-chip debug core: the local Vivado BASIC license rejects `create_debug_core`, so no ILA/VIO and no `.ltx` exist. Observation uses four board LEDs plus a small RTL UART. Programming and capture are scripted so the run is reproducible:

```powershell
.\build\vivado.ps1 build\probe_hw.tcl          # read-only JTAG target check
.\build\vivado.ps1 build\program_board.tcl     # program PL, read back DONE/EOS
.\build\vivado.ps1 build\verify_bitstream.tcl  # read back USERCODE 0x48554237
.\build\capture_uart.ps1 -Port COM7 -Seconds 8  # decode UART frames into RPM/CSV
```

`build/vivado.ps1` resolves `vivado.bat` from `-VivadoBin`, `$env:VIVADO_BIN`, `PATH`, then the usual `AMD`/`AMDDesignTools`/`Xilinx` install roots, so no PATH setup is required. This machine's install is `E:\AMD\2026.1\Vivado\bin`; the wrapper matches `AMD\*\Vivado\bin` and also puts that directory on the child PATH for XSim.

With the GUI already open, the same download can be run from the Tcl Console without a shell: `source <repo>/board/tcl/gui_program.tcl`. Rebuilds still belong in a separate shell, because `build_board_test.tcl` creates its own project.

`capture_uart.ps1` writes `data/uart_measurements.csv` and `data/uart_raw.log`. These must come from a real capture; never replace missing readings with estimates. `build/check_scripts.tcl` syntax-checks every Tcl driver without touching hardware.

Manual GUI procedure and the LED/UART expectations are in `board/board_test_procedure.md`. The image is loaded through JTAG into volatile PL configuration; do not program QSPI/SD boot media with it.

## Key Architecture Decisions

- One IR reference trigger per mechanical revolution; default rising edge is a synthesis parameter.
- Use the latest five complete trigger intervals, with no outlier filtering or missed-trigger recovery; the only input conditioning is the fixed 1 ms debounce plus 1 ms hold-off window.
- Interval timestamps are taken at the accepted edge, so the debounce window does not bias the measured period; the 1 ms acceptance delay is a constant phase offset left for later calibration.
- PL owns the rotational time base: the measured period becomes 64 slots per revolution by shifting, the scan engine only renders one slot at a time, and every trigger restarts slice 0 on the next safe clock edge.
- Intended volume data: at most 400 complete 128x64 packed RGB slices for a half revolution; the second half reuses slices with mirrored BRAM-column readout.
- The 30 fps target and user-reported 2280 full-panel scans/s are design inputs, not achieved hardware results.
- PS+DDR split: PS renders only; PL owns IR capture, scheduling, DDR reads, slice BRAM ping-pong and every HUB75 waveform. The PS never originates a pixel clock or a per-slice event.
- PS console is UART1 on MIO48/49: on this board the onboard CP2102 is wired there, while UART0 on MIO14/15 (the vendor table's pins) is silent in both directions. Both UARTs are enabled in the PS7; the renderer initializes UART1 itself so it works even with an XSA that predates the BD change. DDR3 is two 4 Gb x16 Hynix parts; the PS7 uses the equivalent MT41K256M16 timing at 400 MHz first, 1066 MT/s later.
- First PS+DDR frame format: 64 slices, 3072 B/slice, 6-bit words packed LSB-first, A/B buffers at `0x10000000`/`0x10200000`; the PS base is latched only at a revolution boundary and the old buffer is reused only after the frame-done toggle.
- PS control/status uses AXI GPIO (not a custom AXI-Lite block); the DDR reader is a PL AXI3 master on S_AXI_HP0 with 16-beat bursts, because AXI3 HP ports cap bursts at 16 beats.
- Bare-metal Vitis first; Linux/PetaLinux is deferred. Vitis 2026.1 disables XSCT, so the supported path is the GUI platform/application flow in `sw/README.md`.
- Catch-up playback near angular zero is a future feature; it is not implemented in the current image.

See `report/design_report.md` for design rationale and `report/ai_collaboration.md` for prompts, assistant summaries, tool failures and corrections.
