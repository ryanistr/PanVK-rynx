# faux123's PanVK driver: what it does, and what applies to the X6739

Static analysis of the closed-source `panvk_faux123` package, and why its Mali-G77 gains do
not reproduce on the Infinix GT 10 Pro. Written 2026-11-17.

## Target

| | |
|---|---|
| Package | `panvk_faux123_v1.1.8.adpkg.zip`, sha256 `1898e89be6256e67762876fe249e9017717f8643cc5fb6194cf11195fe6da6c8` |
| Library | `libvulkan_panfrost.so`, sha256 `499e3eae32a27340777cb890aac92468c2519d57223bfad93a2e2a8f71029728` |
| Build | aarch64 ELF, NDK r27d, min API 29, `26.3.0-devel (git-b50c318cbc)`, not stripped, partial DWARF |
| Sources named by its own `meta.json` | Mesa `5a07217f034b`, zenithblue `5b87b74d3e25` (RC4), `panvk-faux123 a101612bb957`, series `7a9fa7460afa`, tree `fa1865d93116` |
| Published scope | one universal library for G57, G77, G610, G710; measured on RP4 Pro (G77), RG556 (G57), Ace (G610), Pixel 7 (G710) |

Method: `reverse-engineer-anything` static analysis — `symtab` (33,257 symbols, so function
names survive), string tables, DWARF only covers vendored `libdrm`, and targeted aarch64
disassembly of the functions that carry the performance code. Nothing here is recovered
source, and nothing was executed on a Retroid Pocket 4 Pro. Every claim below is either an
**observed** symbol/string/disassembly fact or marked **inference**.

The README's "49 patches" line is stale; the package identifies its own patch series by
commit ids, so the exact private patch set is not available and was not reconstructed.

## What is actually in it

Grouped by area, with the evidence that each group exists. The knobs are `getenv` names
recovered from the string table (`PANVK_*`, 145 of them).

### kbase UAPI adaptation

- Atom-layout probing instead of a fixed struct: `kbase_try_atom_stride`,
  `kbase_check_bifrost_atom_stride`, `kbase_atom_alloc`, `kbase_kmod_atom_release`.
  Strings: `"kbase: Bifrost JM atom stride 56 (base_jd_atom_v2)"`,
  `"kbase: stock JM atom layout (stride 72 refused), stride 56"`,
  `"kbase: MediaTek JM atom layout (frame_nr), stride 64, probe event 0x%x"`.
- MediaTek's variant memory-import layout, retried after the Arm one fails:
  `"kbase: KBASE_IOCTL_MEM_IMPORT failed: %s; trying the MTK SLC layout"`,
  `"kbase: mem_import via MTK SLC layout (40 bytes)"`.
- Import cache attributes: `PANVK_KBASE_IMPORT_INNER_SHAREABLE`,
  `PANVK_KBASE_IMPORT_CLEAR`, `PANVK_KBASE_IMPORT_SYNC`, `PANVK_KBASE_IMPORT_SYSTEM`,
  `PANVK_KBASE_IMPORT_SET`, `PANVK_KBASE_DMA_HEAP(_UNCACHED)`,
  `PANVK_KBASE_USER_CACHE_SYNC`, `kbase_kmod_bo_no_cpu_clean`.

**Inference:** they had to make one binary work on Arm's and MediaTek's `mali_kbase`
variants, and the MTK paths are the reason the same package runs on both.

### Clock and queue behaviour (the "2x" claim)

- `kbase_set_frequency_range`, `kbase_sysfs_read`, `kbase_sysfs_write`,
  `kbase_sysfs_has_value`, governed by `PANVK_KBASE_DVFS`
  (`auto|default|max|none|<kHz>`), logging `"kbase: GPU DVFS governor %s, range %u-%u kHz"`.
- Paths are hardcoded: `/sys/class/misc/mali0/device/devfreq/23140000.gpu/cur_freq`,
  `/sys/class/devfreq/23140000.gpu/cur_freq`, plus `governor`, `available_frequencies`,
  `available_governors`, `scaling_min_freq`, `scaling_max_freq`.
- `kbase_keepalive_thread` / `kbase_keepalive_finish` (`PANVK_KBASE_KEEPALIVE_MS`,
  `PANVK_KBASE_KEEPALIVE_WINDOW_MS`, thread name `panvk-keepalive`). Disassembly shows it
  calling `kbase_kmod_csf_queue_kick`, so it is a **CSF** mechanism, not v9 JM.
- Submit-path knobs: `PANVK_KBASE_NO_FENCE`, `PANVK_KBASE_ONE_GROUP`,
  `PANVK_KBASE_GPU_SEMAPHORE_WAITS`, `PANVK_KBASE_KCPU_SYNC`, `PANVK_LAB_SKIP_FENCE_WAIT`,
  `PANVK_PACE`, `PANVK_LAB_SUBMITSTAT`, `PANVK_LAB_ATOMSTAT`, `PANVK_LAB_WAITSTAT`.

Their README states the intent plainly: *"The GPU clock stayed low, which made frames take
more than twice as long. The driver now queues work the way the clock governor expects."*
That is a queueing change plus an optional direct sysfs frequency setting, not a rendering
change.

### Tiler heap and TLS

- `kbase_renew_tiler_heap` with `PANVK_KBASE_HEAP_RENEW_INTERVAL`,
  `PANVK_KBASE_HEAP_RENEW_WORK`, `PANVK_KBASE_HEAP_PERCENT`,
  `PANVK_KBASE_TILER_OOM_HANDLER`, `kbase_spare_heap_job`.
- `PANVK_TLS_DEVICE`, `PANVK_TLS_PER_BATCH` for thread-local storage allocation policy.
- Their README's "some games closed by themselves after a minute or two: a storage area for
  textures handed over at draw time was too small" is this area.

### Shader compiler and the v9 draw path

- `pan_nir_opt_push_ubo` with `PANVK_UBO_PUSH`, `PANVK_UBO_PUSH_SPARE`,
  `PANVK_UBO_RANGE_1M`; `pan_nir_lower_vs_inputs(+_poly)`,
  `PANVK_LAB_VS_PARAM_HOIST`, `PANVK_LAB_KEEP_VARYINGS`, `PANVK_LAB_VARY_POW2`,
  `PANVK_LAB_VARY_SLOTS`. Their README's "a shader with many lights ran about six times
  slower... loaded every light's data up front, ran out of registers, and wrote the values
  to memory and read them back for every pixel" is the register-pressure side of this.
- Valhall v9 toggles: `PANVK_V9_FP16` (+ `panvk_lab_fp16_widen`), `PANVK_V9_RT128`,
  `PANVK_V9_NO_GEOM_LIMITS`, `PANVK_V9_NO_GEOM_PSIZE`, `PANVK_V9_NO_LINEAR_BC`,
  `PANVK_V9_NO_KHR_EXTS`.
- v9 JM draw machinery: `PANVK_JM_IDVS_CHAIN`, `PANVK_JM_FBBAR_PRIM`,
  `PANVK_JM_FBBAR_MAX_VERTS`, `PANVK_JM_NO_FBBAR`, `PANVK_JM_WLS_ONE_DESC`,
  `PANVK_FORCE_EARLYZS`, `PANVK_ZS_PRELOAD_ALWAYS`, `PANVK_MSAA_2X_AS_4X`,
  `PANVK_META_RECTS`, `PANVK_SKIP_FS`.
- Scratch handling for spilling compute shaders: `build_scratch_addr`,
  `pan_nir_lower_divergent_scratch`, `PANVK_LAB_FORCE_EARLY_KILL`.

### Android WSI (not our path)

Their package vendors an Android swapchain: `panvk_android_swapchain_*`,
`panvk_CreateAndroidSurfaceKHR`, `panvk_QueuePresentKHR`,
`panvk_GetAndroidHardwareBufferPropertiesANDROID`,
`vk_android_request_linear_swapchain_buffers_on_mediatek`,
`vk_android_faux_swapchain_quirks`, and the knob set `PANVK_ANB_AFBC`,
`PANVK_ANB_LINEAR`, `PANVK_ANB_NO_LINEAR_FIX`, `PANVK_ANB_DUMP`.
One data symbol is worth noting: `vk_android_anb_is_rp4_afbc.mt6893` — their AFBC
detection is keyed to **mt6893**, which is our SoC too, not just the RP4 Pro.

This whole group is Android-`AHardwareBuffer` code. This repository ships a glibc driver for
gamescope, so none of it applies.

### Diagnostics

`panvk_faux_get_fingerprint`, `panvk_faux_test_report`, `vk_android_faux_diag*`,
`PANVK_DISPLAY_DIAG`, `PANVK_STATS_LOGCAT`, `panvk_faux123 v1.1.8 (Mesa ...)` version
string. Vendor instrumentation, no performance value for us.

## Why the X6739 sees no gain

The Retroid Pocket 4 Pro is **not** a different GPU from this phone. Both are MT6893 with a
Mali-G77 MC9: `gpu_id 0x90800011`, `Mali-G77 9 cores r0p1` here. So "it is fast there and
not here" is not a G77-vs-G77 difference, and the listed causes are ordered by evidence.

Clock pinning is ruled out: the GPU ramps to its 886 MHz maximum on its own under load
(measured, see cause 1). What remains is the submit-path serialization (cause 2, fixed in
0011) and the shader/bandwidth work (cause 3), neither of which is a frequency problem.

### 1. Its clock machinery cannot reach this device's GPU node (observed), and the GPU ramps anyway (measured)

| | RP4 Pro (their target) | X6739 (this device) |
|---|---|---|
| devfreq node | `23140000.gpu` (hardcoded in the binary) | `13000000.mali` |
| governor | — | `dummy` |
| `cur_freq` / `min_freq` / `max_freq` | — | `350000000` / `350000000` / `886000000` |
| extra sysfs | — | `/sys/class/misc/mali0/device/dvfs_period=100`, `power_policy=[coarse_demand] always_on` |
| real DVFS interface | — | `/proc/gpufreqv2/gpufreq_status` (`GPU-OPP`, `GPU-REALOPP`, `GPU-LimitC/F`), `gpu_working_opp_table` (41 OPPs: idx 0 = 886000 kHz … idx 40 = 350000 kHz), `limit_table`; `/sys/module/ged/parameters/{gpu_loading,gpu_idle,gpu_dvfs_enable,…}` |
| kernel | 4.19.191, kbase r32p1 | 5.10.270-StargazerKernel, MTK kbase |

`PANVK_KBASE_DVFS` therefore resolves paths that do not exist here, and the `dummy`
governor means the `13000000.mali` `cur_freq` never changes: it reads `350000000` at
idle *and* under full load. That node is cosmetic on this platform; the actual clock is
driven by MediaTek's GED/`mtk_gpufreq` path and is visible only through
`/proc/gpufreqv2`.

**Measured 2026-11-17** with a scratch offscreen GLES2 load generator
(`gpuload`, 1024x1024 pbuffer, dependent-chain fragment shader; the screen stays locked):

- Idle: OPP 40, `FmeterFreq` 349984, `gpu_loading 0`, `gpu_idle 100`.
- Load starts: OPP 26 (634 MHz) on the first sample (t≈0), then OPP 0
  (`Con1Freq 886000`) within ~500 ms; holds OPP 0 / `FmeterFreq ≈ 867–886 MHz` for the
  full run; `gpu_loading` 91–95.
- No limiter engaged: `GPU-LimitC index 0` (ceiling = top OPP), `GPU-LimitF index 40`
  (floor = idle OPP), `Limiter 0`, no thermal ceiling (temperature 41000 m°C).
- After the load ends, the top OPP lingers briefly, then decays (OPP 1, 879 MHz, ~2 s later).

So the GPU leaves the 350 MHz floor on its own as soon as a real GPU-bound client runs.
faux123's DVFS sysfs writes would be doubly wrong here: the paths do not exist, and the
MTK power path does not need a third-party poke — it already reaches the maximum OPP
within half a second of load. This removes "clock pinned at the floor" as an explanation
for missing performance on this device.

Note: `gpuload` renders through the Android system GLES driver, not PanVK. The frequency
conclusion follows from the kbase utilization path, which is the same one PanVK drives,
not from our driver's specific code.

Access is also denied to the component that would do the writing: as `shell`, every one of
`cur_freq`, `min_freq`, `max_freq`, `governor`, `available_governors` returns
`Permission denied` (SELinux), and they are readable only through `su`. Our driver runs as
the app uid inside the proot guest, so no in-driver DVFS code can work here regardless of
which path it names.

**Observed side effect:** writing `performance` to
`/sys/class/devfreq/13000000.mali/governor` on 2026-11-17 21:34 immediately dropped `adb`
and the device left the USB bus. Do not write that node as a casual experiment; if the clock
is to be pinned, it needs a root helper with a recovery path, outside the driver.

### 2. Our JM path was serialized per batch (observed in source, fixed in 0011)

Before 0011 this tree had two submit paths, and the default one submitted **and waited** for
each `panvk_batch` in turn. That is a submit ioctl, a wait ioctl and a wake-up round trip
per batch, and the CPU blocks behind the GPU each time. The merged path (one job bag per
submit, same ordering, still waited before returning) was
already implemented but only reachable with `PANVK_MERGE_SUBMIT=1`. 0011 makes it the
default. The gain here is fewer submit/wait round trips and less CPU blocking per frame;
it is not a clock effect (the clock ramps without it, see cause 1).

### 3. The remaining G77-only gains are shader and bandwidth work, not clock work

`PANVK_UBO_PUSH`, varying packing/hoisting, `PANVK_JM_IDVS_CHAIN`, tiler-horizontal selection
and the v9 format/compute fixes are independent of the runtime environment and are the
portable part of their work. 0012 ports the one with a documented correctness symptom.

Note also that faux123's own README says the driver is only tested on the RP4 Pro and RG556,
that "every fix I ship was written for the hardware I have", and that on another device it
"may be unnecessary, and it may not be harmless".

## What we changed here

- `0011-jm-merged-submit-by-default.patch` — one job bag per submit instead of submit+wait
  per batch (`PANVK_MERGE_SUBMIT=0` restores the old path).
- `0012-v9-compute-scratch-floor.patch` — 4 KiB of scratch per thread once a v9 compute
  shader spills, which is the fix behind their v0.16.0 "0.2 frames a second" report.

## Deliberately not ported

- `PANVK_KBASE_*` sysfs/DVFS writes: wrong node, wrong clock owner, no permission in the
  guest (see 1 above).
- `kbase_keepalive_*`: CSF only (`kbase_kmod_csf_queue_kick`), and the G77 has no CSF.
- The vendored Android swapchain and `PANVK_ANB_*`: this driver is glibc + gamescope; the
  bionic asset is a different build in DroidDeck-Mali.
- `panvk_faux_get_fingerprint` / `panvk_faux_test_report` / diag knobs: vendor
  instrumentation.

## Open questions, with the check for each

1. **Does this GPU leave 350 MHz under load?** **Answered 2026-11-17: yes.** Under a
   GPU-bound offscreen GLES2 load the OPP goes to 26 (634 MHz) immediately and then to 0
   (886 MHz) within ~500 ms, with no ceiling limiter engaged. The `dummy` governor on the
   cosmetic `13000000.mali` devfreq node is not representative of the real clock; the MTK
   `gpufreqv2`/GED path drives it. No in-driver DVFS patch is warranted.
2. **Does 0011 move a GPU-bound workload?** A/B with `PANVK_MERGE_SUBMIT=0` versus default
   in the same session, frame time only. No change means the workload is not submit-bound.
   This needs a PanVK guest on the device (DroidDeck/proot) or a glibc host; it cannot be
   done from `adb shell` against the Android system driver.
3. **Do we hit the scratch case?** `0012` only fires for shaders that already use scratch;
   confirming it on the device needs a `cs->info.tls_size` print under `PANVK_DEBUG`, which
   is not added here because it would be unrequested instrumentation in a shipping driver.

Hardware status: the device is on `adb` and the GPU behaves as above. Patches 0011/0012
have not been built into a published `.tzst` or installed on the device, so neither has
been validated on hardware.

## 2026-11-18 PanVK-rynx p13 (0011+0012) bionic/vktest results (X6739, `102562537K104189`)

**Driver/artifacts.** Bionic Android build of patched Mesa v1.2.0 (+0011 JM merged-submit default, +0012 v9 compute TLS floor) produced `/tmp/opencode/bionic-build/out/libvulkan_panvk.so` (aarch64, Android 35, NDK r27c, stripped, ~19.2 MiB) + `meta.json` as `PanVK-rynx-1.2.0-p13` (`minApi 29`). Host codegen (`mesa_clc`, `vtn_bindgen2`, `panfrost_compile`) then cross-meson with `-Dplatforms=android -Dandroid-stub=true -Dandroid-strict=false -Dvulkan-drivers=panfrost -Dgallium-drivers= -Dpanfrost-kmds=kbase,panthor -Dpanvk-use-kbase=true -Dmesa-clc=system -Dprecomp-compiler=system -Dcpp_link_args=-static-libstdc++`. Verified panvk_v6-v14 (v9/v10/v11) symbols and `PANVK_FD_INTEROP`. Installed to `com.faux.vktest` as `/data/data/com.faux.vktest/files/drivers/panvk-rynx-p13/` (adpkg-style dir + `meta.json`, `driver.txt` selection); `driver.txt` restored to `system` after testing.

**Identity/load.** `libvkvalidate --identity` (adrenotools loader): `loaded_via: adrenotools`, device `Mali-G77 MC9`, driver `panvk` / `Mesa 26.3.0-devel`, `api_version 1.3.354`, `driver_id 20`, kbase JM 11.38 init OK.

**Core-check run (all 100 `--list` IDs, headless `libvkvalidate --check`, per-check JSON pulled to `/tmp/opencode/vktest-p13/`).**
- p13: **97 completed verdicts + 3 crashes (segfault RC=139, no JSON)**. Verdicts: **71 pass / 13 fail / 12 unsupported / 1 warn**.
- Crashes: `xfb.capture`, `xfb.geometry_shader_capture`, `stage.geometry_point_to_quad` (all segfault).
- System baseline (from `/tmp/opencode/report-system.json`, 95 verdicts): **54 pass / 2 fail / 39 unsupported**. Known fails: `compat.texel_buffer_type_punning`, `timeline.semaphore`.

**Notable deltas vs system (p13 vs system):**
- Improved/exposed: `timeline.semaphore` now **pass** (was fail); many features pass that system reported unsupported (e.g. `atomic.int64_buffer`, BC decode/claim, `border.swizzle`, `cwe.color_write_enable`, EDS1/2/3 checks, `depth.clip_control`, `vids.attribute_offset`, `push.max_uniform_buffers`, `perf.bc_texture_stats`, host image copy checks). `compat.texel_buffer_type_punning` remains **fail** (same class as system).
- Regressions/crashes/concerns: **3 crashes** (`xfb.capture`, `xfb.geometry_shader_capture`, `stage.geometry_point_to_quad` — system pass). Fails where system passed: `core.indirect_first_instance`, `core.mrt_partial_kill`, `compat.nested_map`, `perf.fb_local_barrier_large_draws`, `perf.tess_small_draw_cost`, `stage.tessellation_mirror`, `stress.scratch_per_batch`, `stress.spill_helper_lanes` (vkQueueSubmit -4), `stress.tess_mixed_levels` (vkQueueSubmit -4), and `perf.occlusion_query_in_pass_cost` **warn**. Fails where system unsupported: `core.multi_draw_indirect_instances`, `push.max_combined_image_samplers`, `stress.multi_draw_indirect_large`. `stage.geometry_max_output` unsupported (system pass). `compat.ahb_import`/`compat.sync_fd_export` unsupported in this run.

**Interpretation (0011/0012):** No clear functional regression attributable specifically to 0011 (merged JM submit default, `PANVK_MERGE_SUBMIT=0` override) or 0012 (v9 compute TLS floor 4096) from these results alone; 0011/0012 are CPU-submit/compute-scratch tweaks, not XFB/geometry/tessellation/barrier correctness paths. However there is **no p12-vs-p13 bionic A/B** here, so regressions vs system may be baseline PanVK/JM behavior on this fork/device rather than 0011/0012. No FPS/`DRIVERBENCH_*` performance comparison was possible (benchmark scenes are UI-driven and require screen unlocked/app foreground); available checks provide functional/compat verdicts only, so **no measured perf gain/loss from 0011/0012**.

**Follow-ups:** A/B p13 with `PANVK_MERGE_SUBMIT=0` (if plumbable in this env) vs default; compare against a p7/p12-equivalent bionic build to isolate 0011/0012; investigate XFB/geometry/tess crashes and queue-submit failures (`-4`) on kbase JM; run UI-driven benchmarks on-device for perf signal.

## 2026-11-18 Performance comparison vs stock Mali driver (same device, `com.faux.vktest` 1.32)

Fresh headless perf checks were run against both drivers on the same X6739 device. The stock
driver is `Mali-G77 MC9 / v1.r32p1-01eac0…` (`loaded_via: system`); PanVK is the p13 bionic build
(`loaded_via: adrenotools`). Source data: `/tmp/opencode/sysperf/sysperf/*.json` (stock) and
`/tmp/opencode/results-prior/vktest-p13/*.json` (PanVK p13).

| check | stock (ms) | PanVK p13 (ms) | ratio | note |
|---|---|---|---|---|
| `perf.fb_local_barrier_overdraw` | 1.66 | 1.29 | **0.78x (faster)** | both pass |
| `perf.occlusion_query_in_pass_cost` | 1.06 | 18.80 | **17.7x slower** | stock pass; p13 `warn` (limit 6.66 ms) |
| `perf.fb_local_barrier_large_draws` | 13.35 | n/a | n/a | stock pass; **p13 FAIL** (1247 wrong pixels after 64 blended draws) |
| `perf.bc_texture_stats` | unsupported | pass | n/a | PanVK adds BC decode (hardware) that stock does not advertise |

So PanVK is competitive on a simple framebuffer-local-barrier case, but has a large occlusion
query regression (~18x) and a real correctness failure on framebuffer-local barriers with many
draws. These are **driver-backend gaps relative to stock**, not evidence that 0011/0012 help or
hurt: 0011 only changes submit batching and 0012 only changes v9 compute scratch sizing. A/B
with `PANVK_MERGE_SUBMIT=0` (and a build without 0012) is needed for attribution.

Other quality gaps seen in the p13 run (full evidence in the per-check JSONs): drawIndirect
`firstInstance` is ignored (`core.indirect_first_instance`, `core.multi_draw_indirect_instances`,
`stress.multi_draw_indirect_large`), write-mask-0 on MRT is not honoured (`core.mrt_partial_kill`),
nested `vkMapMemory` returns `VK_ERROR_OUT_OF_HOST_MEMORY` (`compat.nested_map`), ~5432 bytes
of out-of-bounds writes next to driver allocations (`push.max_combined_image_samplers`), 4
checks return `VK_ERROR_DEVICE_LOST` on submit (tessellation / shader-spill cases), and 3 checks
segfault (`xfb.capture`, `xfb.geometry_shader_capture`, `stage.geometry_point_to_quad`).
