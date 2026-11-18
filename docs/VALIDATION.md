# PanVK-rynx validation — performance & quality vs stock, dual-target builds

Device: Infinix GT 10 Pro / X6739 (MT6893, Mali-G77 MC9, `gpu_id 0x90800011`), serial
`102562537K104189`, Android 15, adb root. Harness: `com.faux.vktest` 1.32
(`libvkvalidate.so`, commit `6097b470a5bd`). Drivers compared:

- **stock**: `Mali-G77 MC9 / v1.r32p1-01eac0…`, `loaded_via: system`, api 1.1.177.
- **PanVK p13**: bionic build of this tree (tag `v1.2.0` + patches 0001–0012),
  `loaded_via: adrenotools`, `Mesa 26.3.0-devel`, api 1.3.354, kbase JM 11.38.

## Build matrix

| target | config | status | artifact |
|---|---|---|---|
| glibc / DroidDeck (aarch64) | `build.sh` as shipped (`-Dplatforms=wayland,x11 -Dpanvk-use-kbase=true -Dpanfrost-kmds=kbase,panthor`) | **CI success 2026-11-18** ([run 44233374822](https://github.com/ryanistr/PanVK-rynx/actions/runs/44233374822), `ubuntu-24.04-arm`, 3m46s) | `PanVK-rynx-1.2.0.tzst`, sha256 `087a8adf…5b36ef` |
| Android / bionic (AArch64) | `meson` cross, NDK r27c, `-Dplatforms=android -Dandroid-stub=true -Dpanvk-use-kbase=true`, system host codegen tools | built and verified 2026-11-18 (local verification already complete; no further local builds) | `libvulkan_panvk_p13.so` (20,112,208 B, ELF64 AArch64, Android 35, NDK r27c, stripped) + `meta-p13.json` |

The bionic build was verified with fresh evidence: native host codegen tools
(`mesa_clc`, `vtn_bindgen2`, `panfrost_compile`, built with `-Dplatforms=` to avoid WSI deps),
Android libdrm 2.4.125 cross-built and installed, then the driver cross-built with 1114/1114
targets linked. Verified 724 `panvk_v9_*` symbols, v10/v11, `PANVK_FD_INTEROP`, and ELF headers
(`Class ELF64 / Machine AArch64 / OS ABI UNIX-System V`). Build-only source fixes for the
Android stub (`buffer_handle_t` guards, ANB handle casts, duplicate `panvk_android_hal_bridge`
removed) live in the temp tree only, not in this repo.

Both builds use the same patched source tree (all 12 patches apply cleanly to
`apexspan-svg/mesa-panvk-mali-g57` tag `v1.2.0`, HEAD `66306eb`; re-verified 2026-11-18,
with `build.sh` applying each of them successfully in the arm64 CI job). The CI artifact
contains `usr/lib/libvulkan_panvk.so`, `usr/share/vulkan/icd.d/panvk_icd.aarch64.json` and
`meta.json` (`gpuArch [9,10,11]`). Because this was a push build it has no `-p<n>` suffix —
releases are created only by `workflow_dispatch` with an explicit tag, and p7 was not rebuilt.

## Quality comparison (`libvkvalidate --check`, all 100 listed IDs)

| driver | pass | fail | unsupported | warn | crashes |
|---|---|---|---|---|---|
| stock (95 verdicts in baseline report) | 54 | 2 | 39 | 0 | 0 |
| PanVK p13 (97 verdicts + 3 crashes) | 71 | 13 | 12 | 1 | 3 |

PanVK passes checks the stock driver reports unsupported (BC decode, EDS1/2/3 dynamic state,
64-bit atomics, host image copy, etc.) and fixes one stock failure (`timeline.semaphore`),
but has real quality gaps relative to stock:

- **Crashes (stock passes):** `xfb.capture`, `xfb.geometry_shader_capture`,
  `stage.geometry_point_to_quad` (segfault, RC=139).
- **`VK_ERROR_DEVICE_LOST` on submit (stock passes):** `perf.tess_small_draw_cost`,
  `stage.tessellation_mirror`, `stress.spill_helper_lanes`, `stress.tess_mixed_levels`.
- **Correctness (stock passes):** `core.indirect_first_instance`,
  `core.multi_draw_indirect_instances`, `stress.multi_draw_indirect_large` (firstInstance
  ignored), `core.mrt_partial_kill` (write-mask 0 not honoured), `compat.nested_map`
  (second `vkMapMemory` → `VK_ERROR_OUT_OF_HOST_MEMORY`),
  `push.max_combined_image_samplers` (~5432 bytes written outside driver allocations),
  `perf.fb_local_barrier_large_draws` (1247 wrong pixels).
- **Unchanged:** `compat.texel_buffer_type_punning` fails on both.
- **Resource footprint:** `stress.scratch_per_batch` fails the 8 MiB/dispatch limit with
  ~94.5 MiB/dispatch (kbase per-dispatch allocation issue; all correctness sums pass).

## Performance comparison (same device, headless perf checks, best-of-3 ms)

| check | stock | PanVK p13 | ratio | note |
|---|---|---|---|---|
| `perf.fb_local_barrier_overdraw` | 1.66 | 1.29 | **0.78x (faster)** | both pass |
| `perf.occlusion_query_in_pass_cost` | 1.06 | 18.80 | **17.7x slower** | stock pass, p13 warn (limit 6.66 ms) |
| `perf.fb_local_barrier_large_draws` | 13.35 | n/a | n/a | stock pass, p13 correctness fail |
| `perf.bc_texture_stats` | unsupported | pass | n/a | PanVK adds hardware BC decode |

Raw evidence: `/tmp/opencode/sysperf/sysperf/*.json` (stock),
`/tmp/opencode/results-prior/vktest-p13/*.json` (p13), pulled from device.

## Attribution (A/B) results — 0011 (`PANVK_MERGE_SUBMIT`)

Same p13 binary, same device, targeted set of all 20 failing/crashing/warning checks plus
controls, run twice: once with the 0011 default (merged one-bag submit) and once with
`PANVK_MERGE_SUBMIT=0` (legacy per-batch submit+wait). Raw evidence:
`/tmp/opencode/ab_nomerge/ab_nomerge/*.json` vs `/tmp/opencode/results-prior/vktest-p13/*.json`.

**Correctness: no verdict change — confirmed across the full 100-check set.** Running every
listed ID with `PANVK_MERGE_SUBMIT=0` produced **zero verdict differences** vs the p13 default
(97 verdicts identical: 71 pass / 13 fail / 12 unsupported / 1 warn, plus the same 3 crashes
in both modes). On the targeted subset, `push.max_combined_image_samplers` still fails in
both modes (segfaulting with merge off vs reporting out-of-bounds bytes with merge on). So
**none of the quality gaps above are caused by 0011** — they are baseline behavior of this
fork's JM/kbase backend. Raw evidence: `/tmp/opencode/ab_full_nomerge/` (197 files).

**Performance: 0011 is a clear win on submit-bound work.**

| check | 0011 off (per-batch) | 0011 on (merged) | stock |
|---|---|---|---|
| `perf.occlusion_query_in_pass_cost` | 34.39 ms | **18.80 ms (1.8x faster)** | 1.06 ms |
| `perf.fb_local_barrier_overdraw` | 1.41 ms | **1.29 ms (1.09x faster)** | 1.66 ms |

So 0011 nearly halves the submit-heavy occlusion-query cost and slightly improves the simple
barrier case, with no correctness regression. The remaining ~17x gap to stock on occlusion
queries is a backend issue, not a submit-batching issue.

Still to isolate: 0012 (build with it reverted, esp. for `stress.scratch_per_batch`) and a
bionic build without 0011/0012 to separate patch effects from the fork baseline. Overall:
**PanVK p13 is competitive on a simple barrier case, adds features, and 0011 measurably
improves submit-bound work; it remains materially behind stock in occlusion-query cost and
has several correctness/crash gaps, none attributable to 0011 so far.**
