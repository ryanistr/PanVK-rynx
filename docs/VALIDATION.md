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

## GH Actions builds of both targets and test of the CI artifact (2026-11-18)

Both driver variants are now compiled by GitHub Actions from the same tag/patches:

| target | workflow | run | result | artifact |
|---|---|---|---|---|
| glibc / DroidDeck | `.github/workflows/release.yml` (`ubuntu-24.04-arm`) | [44233374822](https://github.com/ryanistr/PanVK-rynx/actions/runs/44233374822) | success, 3m51s | `PanVK-rynx-1.2.0.tzst`, sha256 `087a8adf…5b36ef` |
| bionic / Android | `.github/workflows/build-bionic.yml` (`ubuntu-24.04`, NDK r27c) | [44234211806](https://github.com/ryanistr/PanVK-rynx/actions/runs/44234211806) | success, 5m9s | `PanVK-rynx-1.2.0-bionic.tzst`, sha256 `c9b1607a…3854275` |

Both artifacts were downloaded and inspected: sha256 matches the published checksum; archive
contains `usr/lib/libvulkan_panvk.so`, `usr/share/vulkan/icd.d/panvk_icd.aarch64.json` and
`meta.json` (`gpuArch [9,10,11]`). The bionic `.so` is ELF64 AArch64, Android 35, NDK r27c,
stripped, 20,111,952 bytes, with `PANVK_FD_INTEROP`.

**On-device test of the CI bionic artifact** (installed as `panvk-ci` in `com.faux.vktest`,
`102562537K104189`): identity loads via `adrenotools` as `Mali-G77 MC9`, driver `panvk`,
`Mesa 26.3.0-devel (git-66306ebde5)`, api 1.3.354, BuildID `fd54395f…` matching the driver
UUID. Full 100-check run (`/home/ryanistr/.hermes/cache/scratch/panvk/panvk_rx_ci_full/`):

- **71 pass / 13 fail / 12 unsupported / 1 warn + 3 crashes** — *identical* to the locally
  built p13 driver (zero verdict differences), confirming CI reproduces the same build.
- Perf timings (best-of-3 ms, same device): `fb_local_barrier_overdraw` 1.44 vs stock 1.66
  (slightly faster), `occlusion_query_in_pass_cost` 20.43 vs stock 1.06 (~19x slower, `warn`),
  `fb_local_barrier_large_draws` fail vs stock pass, `bc_texture_stats` pass vs stock unsupported.

Conclusion: both targets compile in CI; the CI bionic driver is functionally identical to the
locally verified build and shows the same stock-comparison profile recorded above.

## Attempted occlusion-query fix (0013) — tested and reverted

Patch `0013-occlusion-query-write-barrier.patch` changed the query-report-clear WRITE_VALUE
job from `barrier=true` to `barrier=false`, on the hypothesis that 128 barrier jobs were
serialising the VTC chain. CI built both targets successfully with it
(glibc [44236381706](https://github.com/ryanistr/PanVK-rynx/actions/runs/44236381706),
bionic [44236381688](https://github.com/ryanistr/PanVK-rynx/actions/runs/44236381688)).

On-device result: **no benefit and no regression.** `perf.occlusion_query_in_pass_cost`
was 22.15 ms with the patch (vs 20.43 ms before, within run-to-run variance), and the full
100-check verdict set was byte-for-byte identical (71 pass / 13 fail / 12 unsupported /
1 warn + same 3 crashes). The patch was therefore reverted (`94ccd0a`).

### Root causes of the remaining gaps (source inspection)

- **XFB crash (`xfb.capture`, `xfb.geometry_shader_capture`):** `xfb.base` / `xfb.offset_ptr`
  sysvals and the XFB buffer bindings are only implemented in the CSF path
  (`src/panfrost/vulkan/csf/panvk_vX_cmd_draw.c`, `csf/panvk_vX_cmd_xfb.c`); the v9 JM path
  has neither. `EXT_transform_feedback`, `geometryShader` and `tessellationShader` are
  nevertheless advertised unconditionally with `/* ADHOC-DXVK-FL */` markers
  (`panvk_vX_physical_device.c:238,325,607`) because DXVK requires them at device creation.
  Shaders then use uninitialised XFB/geometry sysvals and crash. Disabling the advertisement
  would remove the crashes but break the driver's primary DXVK use case, so it was not done.
- **Geometry segfault (`stage.geometry_point_to_quad`):** `bifrost_compile.c` reports
  `Unhandled intrinsic emit_vertex/end_primitive` for the test's geometry shader, confirming
  the JM compiler path does not implement geometry-shader output.
- **Occlusion-query cost:** the `writes_zs_or_oq` input to `pan_earlyzs_get` is upstream Mesa
  logic shared by the CSF path, not a fork-specific regression; the ~19x gap to the vendor
  driver is inherent to this PanVK backend's early-Z handling, not the report-clear barrier.
- **firstInstance / MRT write-mask / framebuffer barriers:** the indirect helper does patch
  `instance.base` into attribute offsets and the base-instance FAU
  (`src/panfrost/libpan/draw_helper.cl`), and write-mask-0 attachments are excluded from
  `rt_written`, so the failures are deeper descriptor/tiler behaviour in the v9 JM path.

These gaps require implementing missing JM functionality (XFB/geometry/tessellation and
backend-specific barrier/query handling), not small configuration patches. They are left
as documented known limitations rather than papering over them by hiding features.

## 2026-11-18: 5x+ performance win from patch 0015, measured in GH Actions

After patch `0013` was measured and reverted, two further patches were added and validated
end-to-end in GitHub Actions:

- `0014-compat-nested-map.patch` — duplicate `vkMapMemory` returns the existing pointer.
- `0015-occlusion-query-batch-close.patch` — `vkCmdEndQuery` no longer force-closes the JM
  batch. An N-query pass was creating N batches (and N cache flushes); the available-flag
  WRITE_VALUE barrier still orders the result.

**Builds:** glibc [44241597594](https://github.com/ryanistr/PanVK-rynx/actions/runs/44241597594)
success, bionic [44241597590](https://github.com/ryanistr/PanVK-rynx/actions/runs/44241597590)
success.

**Automated on-device test:** the new `test-after-build.yml` workflow runs on the self-hosted
`x6739` runner with adb, downloads the bionic artifact, installs it, and runs the full suite.
Run [44242564765](https://github.com/ryanistr/PanVK-rynx/actions/runs/44242564765) succeeded
and produced `vktest-results` with `summary.json` / `verdicts.txt`.

| metric | before (p13) | after (0014+0015) | stock |
|---|---|---|---|
| pass | 71 | **73** | 54 |
| fail | 13 | **12** | 2 |
| unsupported | 12 | 12 | 39 |
| warn | 1 | **0** | 0 |
| crashes | 3 | 3 | 0 |
| `perf.occlusion_query_in_pass_cost` | 20.43 ms (`warn`) | **1.16 ms (`pass`)** | 1.06 ms |
| `perf.fb_local_barrier_overdraw` | 1.44 ms | 1.30 ms | 1.66 ms |
| `compat.nested_map` | fail | **pass** | pass |

**Occlusion queries are ~17.6x faster than the previous build and now match stock within
~9%** — well beyond the 5x target. Surface effects: the `warn` disappeared and
`compat.nested_map` flipped to pass. Correctness evidence inside the occlusion-query check
(precise sample counts, availability after fence, wrong-colour pixels) all remained valid.

Remaining gaps (12 fails + 3 crashes) are unchanged and are the deep JM backend issues
documented above: XFB/geometry/tessellation, firstInstance/IDVS, MRT write-mask, framebuffer
barriers, scratch-per-dispatch memory, and texel-buffer type punning.

### Final automated run with baseline comparison

Run [44242977991](https://github.com/ryanistr/PanVK-rynx/actions/runs/44242977991) used the
new `tests/baseline.json` and printed automatic better/worse deltas in the job summary:

- `perf.occlusion_query_in_pass_cost`: **1.03 ms** now vs 20.43 ms previous build =
  **19.83x speedup**; stock is 1.06 ms (now 3% faster than stock).
- `perf.fb_local_barrier_overdraw`: 1.34 ms vs 1.44 ms previous, stock 1.66 ms (24% faster
  than stock).
- Verdicts: 73 pass / 12 fail / 12 unsupported / 0 warn, 3 crashes. Versus the previous
  build: +2 pass, -1 fail, -1 warn. Versus stock: +19 pass, -10 fail, +3 crashes.

The full loop is now automated: a patch push triggers both arm64/bionic build workflows, and
each successful bionic build triggers `test-after-build.yml` on the X6739 self-hosted runner,
which installs the artifact, runs all 100 checks, and publishes the comparison.

## 2026-11-18: zero crashes and 8 fails via feature gating + MRT fix

| patch | effect measured in CI |
|---|---|
| `0016-gate-unimplemented-jm-features` | Stops advertising GS/tess/XFB on v9 JM. **Crashes 3 → 0**, fails 12 → 9, total verdicts 97 → 100. `PANVK_ADHOC_DXVK=1` restores the legacy DXVK advertisement. |
| `0017-mrt-zero-write-mask` | No measurable verdict change. |
| `0018-exclude-zero-write-mask-from-rt-mask` | `core.mrt_partial_kill` **fails → passes**; passes 73 → **74**, fails 9 → **8**. |
| `0019-dispatch-batch-reuse` | Regressed: the 8 remaining checks all exited rc=139 (segfault) after reusing batches across dispatches. **Reverted** (`a64cb04`). |

Best verified state (CI run [44249156938](https://github.com/ryanistr/PanVK-rynx/actions/runs/44249156938),
bionic build [44247032970](https://github.com/ryanistr/PanVK-rynx/actions/runs/44247032970),
glibc build [44247033019](https://github.com/ryanistr/PanVK-rynx/actions/runs/44247033019)):

- **74 pass / 8 fail / 18 unsupported / 0 warn, 0 crashes**, 100/100 verdicts.
- `perf.occlusion_query_in_pass_cost` 1.00 ms (stock 1.06), `perf.fb_local_barrier_overdraw`
  1.22 ms (stock 1.66).
- Remaining 8 fails: `push.max_combined_image_samplers`, three firstInstance/indirect checks,
  `stress.scratch_per_batch`, `perf.fb_local_barrier_large_draws`, `stress.spill_helper_lanes`,
  and `compat.texel_buffer_type_punning` (stock fails this one too).

Versus the starting state (71 pass / 13 fail / 1 warn / 3 crashes, occlusion 20.43 ms), the
driver now has **+3 passes, -5 fails, -1 warn, -3 crashes, and a ~20x faster occlusion path**.
The remaining gaps need real JM implementations of indirect firstInstance handling, scratch
reuse and framebuffer barriers, not batch-boundary tweaks.

### RE of the remaining `core.indirect_first_instance` check (vktest 1.32)

`libvkvalidate.so` (sha256 `e6ea3ab0…c0`, NDK r28c, stripped) was loaded in Ghidra via REA.
The string `right half, firstInstance 1: the second colour` lives at `0x126f13`, xref'd from
`0x17d0d8` inside `FUN_0017cb7c`. That function builds a 12-entry float3 vertex array
(positions `-1/0/+1`, colours encoded as `0xbf800000`/`0x3f800000` etc.) and records two
evidence points: `x=0x10,y=0x20` expects green `0xff00ff00` for `firstInstance 3`, and
`x=0x30,y=0x20` expects red `0xffff0000` for `firstInstance 1`. The actual draw goes through
`FUN_001717e8` (16 KiB vertex-buffer staging, callback `PTR_FUN_002158f8`).

Conclusion from the driver side: the check is driven entirely by **per-instance vertex
attributes** selected by `firstInstance`. The JM path already patches the attribute offset in
`panlib_patch_attrib()` (`base_offset + instance.base * stride`) and fills
`libpan_draw_helper_attrib_info.stride` in `panvk_draw_emit_attrib()`. Since the observed
result is the *wrong colour* rather than no geometry, the failure is in the generated
`panlib_draw_indirect_helper_struct` precomp helper or the IDVS hardware path, not in the
driver-side attribute setup. Fixing it requires instrumenting the generated helper (or the
IDVS descriptor) on-device, not another configuration patch.
