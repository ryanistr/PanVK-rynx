# PanVK-rynx Iteration Report (`8316212`)

## 1. Summary of Changes (`main` @ `8316212`)
All new patches apply cleanly with `patch -p1` against `apexspan-svg/mesa-panvk-mali-g57` tag `v1.2.0` and are documented in [`docs/PATCHES.md`](docs/PATCHES.md):

| File | Root-Cause Fix |
|---|---|
| [`patches/0019-push-descriptor-hw-storage.patch`](patches/0019-push-descriptor-hw-storage.patch) | Sizes `panvk_push_set` and meta save/restore push storage for worst-case combined image sampler stride (`MAX_PUSH_DESCS * (PANVK_MAX_PLANES + PANVK_MAX_DESCS_PER_SAMPLER)`), fixing heap/stack overflow in `push.max_combined_image_samplers`. |
| [`patches/0020-jm-reuse-compute-scratch.patch`](patches/0020-jm-reuse-compute-scratch.patch) | Reuses the largest per-command-buffer TLS/WLS scratch allocation across sequential compute-only batches on JM instead of allocating a fresh 92 MiB BO per dispatch (`stress.scratch_per_batch`). |
| [`patches/0021-v9-spill-helper-lanes.patch`](patches/0021-v9-spill-helper-lanes.patch) | Emits `VA_MEMORY_ACCESS_FORCE` (`.force`) on Valhall register-spiller TLS loads/stores (`bi_load_tl`/`bi_store_tl`) so helper lanes preserve spilled values for derivatives, and applies the 4 KiB v9 TLS floor to graphics batches in `cmd_close_batch` (`stress.spill_helper_lanes`). |
| [`patches/0022-v9-fb-local-barrier-and-spill.patch`](patches/0022-v9-fb-local-barrier-and-spill.patch) | Enables `needs_load`/`needs_store` spill tracking on `PAN_ARCH >= 9` JM so mid-pass batch splits spill/reload instead of re-clearing. |
| [`patches/0023-v9-indirect-draw-and-first-instance.patch`](patches/0023-v9-indirect-draw-and-first-instance.patch) | Implements `firstInstance` vertex attribute offset shifting, `panlib_draw_indirect_v9` indirect/indexed-indirect draw patching with `PANLIB_BARRIER_JM_SUPPRESS_PREFETCH` and `global_dep` chaining, and `multiDrawIndirect` (`maxDrawIndirectCount = UINT32_MAX`) on v9 JM (`core.indirect_first_instance`, `core.multi_draw_indirect_instances`, `stress.multi_draw_indirect_large`). |
| [`patches/0024-jm-reject-gs-tess-and-guard-xfb.patch`](patches/0024-jm-reject-gs-tess-and-guard-xfb.patch) | Returns `VK_ERROR_FEATURE_NOT_PRESENT` for unsupported GS/TCS/TES stages on `PAN_ARCH < 10` (unless `PANVK_ADHOC_DXVK=1`), adds JM `Cmd*TransformFeedback*2EXT` entrypoints so unadvertised XFB calls do not jump to `NULL`, and guards `NULL` `fs.shader` in `panvk_v9_prepare_fs_desc` (`xfb.capture`, `xfb.geometry_shader_capture`, `stage.geometry_point_to_quad`). |
| [`tools/vkvalidate-harness.sh`](tools/vkvalidate-harness.sh) | Clears `/data/local/tmp/vk_$LABEL` before each run and removes per-check `.json`/`.log` before execution so crashes cannot be masked by stale outputs. |

---

## 2. CI Build & On-Device `com.faux.vktest` Results (`8316212`)
- **glibc build (`release.yml`)**: Run `44322607554` — `completed` / `success`
- **bionic build (`build-bionic.yml`)**: Run `44322607558` — `completed` / `success`
- **On-device test (`test-after-build.yml` on `x6739-test`, testing `44322607558`)**: Run `44323855768` — `completed` / `success`

### Verdict Comparison (`100` checks total)
| Metric | Stock (`tests/baseline.json`) | `previous_build` (`tests/baseline.json`) | Initial State | Latest (`8316212`, Run `44323855768`) |
|---|---|---|---|---|
| `pass` | 54 | 71 | 74 | **80** |
| `unsupported` | 39 | 12 | 12 | **12** |
| `fail` | 2 | 13 | 8 | **8** |
| `warn` | 0 | 1 | 0 | **0** |
| `crashes` | 0 | 3 | 3 | **0** |

### Performance Timings (`summary.json`, Run `44323855768`)
| Check | Stock | `previous_build` | Latest (`8316212`) | Speedup vs Stock |
|---|---|---|---|---|
| `perf.occlusion_query_in_pass_cost` | 1.06 ms | 20.43 ms | **1.19 ms** (0.90–1.05 ms in adjacent runs) | 0.89x (17.17x vs `previous_build`) |
| `perf.fb_local_barrier_overdraw` | 1.66 ms | 1.44 ms | **1.43 ms** | **1.16x** |
| `perf.fb_local_barrier_large_draws` | 13.35 ms | `null` | `null` (`fail`, 1247 wrong pixels) | — |

### Newly Fixed Checks
- `push.max_combined_image_samplers`: `fail` → **`pass`**
- `stress.scratch_per_batch`: `fail` → **`pass`**
- `stress.spill_helper_lanes`: `fail` → **`pass`**
- `core.indirect_first_instance`: `fail` → **`pass`**
- `core.multi_draw_indirect_instances`: `fail` → **`pass`**
- `stress.multi_draw_indirect_large`: `fail` → **`pass`**
- `xfb.capture`: `CRASH(rc=139)` → `fail` (no crash)
- `xfb.geometry_shader_capture`: `CRASH(rc=139)` → `fail` (no crash)
- `stage.geometry_point_to_quad`: `CRASH(rc=139)` → `fail` (no crash)

### Remaining Non-Pass Checks (`verdicts.txt`, Run `44323855768`)
- **Failing (8):**
  - `xfb.capture`, `xfb.geometry_shader_capture`, `stage.geometry_point_to_quad`, `stage.tessellation_mirror`, `stress.tess_mixed_levels`, `perf.tess_small_draw_cost` — GS/Tess/XFB are not implemented on Valhall v9 JM (`panvk_has_gs_tess_xfb()` is `false` by default).
  - `compat.texel_buffer_type_punning` — also fails on stock Mali (`LD_CVT` converts `R32_UINT` to float when read via `samplerBuffer`).
  - `perf.fb_local_barrier_large_draws` — `1247` sampled pixels differ after 64 blended draws (observed both with batch splitting and `primitive_barrier`).
- **Unsupported (12):** `eds3.polygon_mode`, `depth.bias_float`, `robust.buffer_access2`, `robust.storage_buffer_access2`, `robust.image_access2`, `robust.image_access2_kinds`, `limit.viewports`, `stage.geometry_point_size`, `stage.geometry_max_output`, `compat.sync_fd_export`, `compat.ahb_import`, `wsi.present_wait`.

---

## 3. `AIO-Graphics-Test-64bit` Benchmark Status
- Downloaded `AIO-Graphics-Test-64bit.exe` (`v2.2.0`, 4.1 MiB) from `The412Banner/AIO-Graphics-Test` and pushed it to `/sdcard/Download/AIO-Graphics-Test-64bit.exe` on `102562537K104189`.
- **Blocked from running on device:** `AIO-Graphics-Test-64bit.exe` is a Windows 64-bit executable, and no Wine / Winlator / DroidDeck (`com.droiddeck.launcher`) APK or container is currently installed on `102562537K104189` (`pm list packages -3` shows no Windows compatibility runner). Because the benchmark could not be executed, no `AIO-Graphics-Test-64bit` FPS numbers are claimed for `8316212` here; once DroidDeck/Winlator is installed on the device, it can launch `/sdcard/Download/AIO-Graphics-Test-64bit.exe` directly against the installed `panvk-ci` driver.
