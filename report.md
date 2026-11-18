# PanVK-rynx MT6893 (Mali-G77 MC9) On-Device Validation & Benchmark Report

**Device:** OnePlus CPH2493 (`mt6893`, MT6893Z_T/CZA, Android 15 / SDK 35, `gpu_id 0x90800011`, kbase JM `11.38`)
**Final Repo HEAD:** `d2a48bd` (`main`, patches `0001`–`0038`)
**Final Bionic CI Run:** `44410823457` (`success`, `libvulkan_panvk.so`, `20132232` bytes)

---

## 1. Executive Summary

- **Visual Corruption, MDP Hangs, and `not valid` Runs Fixed (`0035`):**
  - Root cause: MediaTek gralloc allocates **AFBC-compressed** `ANativeWindowBuffer` / `AHardwareBuffer` swapchain buffers (`private_handle_t` magic `0x03141592`, `alloc_format` in `ints[30..31]`, e.g. `0x619` = `AFBC 32x8 | SPLIT | YTR | SPARSE` for `0xb00` SurfaceView buffers). Because `build-bionic.sh` uses `-Dandroid-stub=true`, `u_gralloc_fallback` returned `DRM_FORMAT_MOD_INVALID` and `0025` mapped it to `DRM_FORMAT_MOD_LINEAR`. PanVK wrote linear pixels over the AFBC header, causing striped/blocky noise on screen and causing MediaTek's `MDP` (`DpAsyncBlitStream` / `CMDQ`) to time out (`1000 ms` per frame).
  - [`0035-u_gralloc-fallback-decode-mediatek-afbc-modifier.patch`](file:///mnt/mainline/PanVK-rynx/patches/0035-u_gralloc-fallback-decode-mediatek-afbc-modifier.patch) decodes MediaTek `private_handle_t` `alloc_format` into the exact `DRM_FORMAT_MOD_ARM_AFBC(...)` or `DRM_FORMAT_MOD_LINEAR` modifier. Swapchain rendering is now clean (`vktest_0035_render.png`) with zero MDP timeouts and `valid: True` across all 5 Speed Test scenes.
- **`vkvalidate` Suite (`0038` / `44410823457`):** **81 pass / 8 fail / 11 unsupported / 0 warn / 0 crashes** (stock baseline: **54 pass / 2 fail**).
  - `perf.fb_local_barrier_overdraw`: **`1.39 ms`** vs stock **`1.66 ms`** (**`1.19x` faster**; `0.73 ms` / `2.27x` on `0035`).
  - `perf.occlusion_query_in_pass_cost`: **`1.09 ms`** vs stock **`1.06 ms`** (`0.97x`).
- **`com.faux.vktest` Speed Test (`valid: True`, `0035`–`0038`):**
  - Overall score: **`37.30 ms`** (`0036`) / **`37.38 ms`** (`0037`) vs stock **`22.25 ms`**.
  - `hdr_2160p` (3840x2160): **`35.87 ms`** vs stock **`41.55 ms`** (**`1.16x` faster than stock**).
  - `oit_linked_lists`: **`24.23 ms`** vs stock **`22.68 ms`** (`0.94x`).
  - `compute_nbody`: **`32.73 ms`** vs stock **`27.21 ms`** (`0.83x`; GPU OPP observed at `350 MHz` via `/proc/gpufreqv2/gpufreq_status`).
  - `subpasses`: **`32.85 ms`** vs stock **`22.21 ms`** (`0.68x`).
  - `pipeline_barriers`: **`69.56 ms`–`74.28 ms`** vs stock **`17.87 ms`** (`0.24x`–`0.26x`, main remaining bottleneck).
- **`< 10 ms` Overall Target Assessment:**
  - Not met (`37.30 ms` best measured vs `< 10 ms` target). On Mali-G77 MC9, ARM's own stock driver scores `22.25 ms` overall, and `hdr_2160p` (4K HDR) alone is `35.87 ms` on PanVK (`41.55 ms` stock), making `< 10 ms` overall geometric mean physically unreachable on this GPU even if `pipeline_barriers` and `subpasses` are brought to stock parity (`~22 ms`).

---

## 2. Patches Added (`0025`–`0038`)

| Patch | Commit | Purpose & Root Cause Fixed |
| :--- | :--- | :--- |
| `0025-panvk-android-fallback-linear-modifier.patch` | `a86b673` | Map `DRM_FORMAT_MOD_INVALID` on single-plane ANB/AHB images to `DRM_FORMAT_MOD_LINEAR` and guard `mod_handler == NULL`. |
| `0026-android-find-dmabuf-fd-in-native-handle.patch` | `4f3dafb` | Scan `native_handle_t` fds via `/proc/self/fd/%d` for the `dmabuf` fd (`fd[1]` on MediaTek gralloc). |
| `0027-panvk-kbase-dont-set-drm-syncobj-copy-payloads.patch` | `1b5e48f` | Leave `device->vk.copy_sync_payloads = NULL` on kbase devices. |
| `0028-panvk-kbase-enable-async-overlap-by-default.patch` | `c31b851` | Enabled `PANVK_ASYNC` and `PANVK_OVERLAP` by default on kbase. |
| `0029-panvk-jm-v9-compute-task-axis-and-increment.patch` | `54e388b` | Port `calculate_task_axis_and_increment` to JM v9 compute/precomp dispatches and enable `allow_merging_workgroups`. |
| `0030-panvk-kbase-defer-sync-file-wait-to-gpu.patch` | `96b2991` | Defer `sync_file` CPU `poll()` from `import_sync_file` to `kbase_cpu_sync_wait_one` and preserve `ks->import_fd`. |
| `0031-panvk-kbase-export-sync-file-return-signaled.patch` | `282b410` | Drain `ks` and return `*sync_file = -1` in `kbase_cpu_sync_export_sync_file`. |
| `0032-panvk-kbase-disable-overlap-by-default.patch` | `12649fa` | Disable `PANVK_OVERLAP` by default (`PANVK_OVERLAP=1` to opt in). |
| `0033-panvk-kbase-disable-async-by-default.patch` | `4293dc7` | Disable `PANVK_ASYNC` by default (`PANVK_ASYNC=1` to opt in). |
| `0034-panvk-jm-skip-noop-pipeline-barrier-batch-split.patch` | `6215f59` | Skip closing/reopening JM batches in `CmdPipelineBarrier2` on empty batches or trivial `TOP_OF_PIPE`/`HOST` barriers. |
| `0035-u_gralloc-fallback-decode-mediatek-afbc-modifier.patch` | `7f84bf8` | Decode MediaTek `private_handle_t` `alloc_format` into `DRM_FORMAT_MOD_ARM_AFBC(...)` or `DRM_FORMAT_MOD_LINEAR` in `u_gralloc_fallback`. |
| `0036-panvk-kbase-reenable-async-by-default.patch` | `444053b` | Re-enable `PANVK_ASYNC=1` by default on kbase (`PANVK_ASYNC=0` to disable). |
| `0037-panvk-overlap-sync-and-prefrag-barrier.patch` | `d39eef0` | Re-enable `PANVK_OVERLAP=1` and non-blocking `KBASE_JD_REQ_SOFT_FENCE_TRIGGER` sync_file export, and skip pre-fragment-to-fragment / `BOTTOM_OF_PIPE` barrier splits. |
| `0038-panvk-jm-overlap-intra-cmdbuf-and-cache-env.patch` | `d2a48bd` | Overlap `vtc` (JS1) and `frag` (JS0) across graphics batches within the same command buffer and cache `PANVK_VERBOSE` in `panvk_vX_cmd_draw.c`. |

---

## 3. `vkvalidate` Results (`0038` / `44410823457` / `d2a48bd`)

- **Verdicts:** `81 pass`, `8 fail`, `11 unsupported`, `0 warn`, `0 crashes` (100 total; stock baseline: `54 pass`, `2 fail`, `0 crashes`).
- **Perf microbenchmarks:**
  - `perf.fb_local_barrier_overdraw`: **`1.39 ms`** vs stock **`1.66 ms`** (**`1.19x` faster**)
  - `perf.occlusion_query_in_pass_cost`: **`1.09 ms`** vs stock **`1.06 ms`** (`0.97x`)
  - `perf.fb_local_barrier_large_draws`: `null` (did not pass)
- **8 fails / 11 unsupported:** Same 8 failing checks and 11 unsupported checks as `b5b95f6` (`0034`).

---

## 4. `com.faux.vktest` Speed Test Results

| Scene | Stock (`system`, `valid=True`) | PanVK `0035` (`valid=True`) | PanVK `0036` (`valid=True`) | PanVK `0037` (`valid=True`) | PanVK `0038` (`valid=True`) | Speedup vs Stock (`0038`) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `oit_linked_lists` (1080p) | `22.68 ms` | `24.20 ms` | `24.59 ms` | `24.51 ms` | `24.23 ms` | `0.94x` |
| `subpasses` (1080p) | `22.21 ms` | `33.63 ms` | `32.32 ms` | `33.88 ms` | `32.85 ms` | `0.68x` |
| `compute_nbody` (1080p) | `27.21 ms` | `32.80 ms` | `31.91 ms` | `33.79 ms` | `32.73 ms` | `0.83x` |
| `pipeline_barriers` (1080p) | `17.87 ms` | `73.41 ms` | `76.31 ms` | `69.56 ms` | `74.28 ms` | `0.24x` |
| `hdr_2160p` (3840x2160) | `41.55 ms` | `36.07 ms` | `35.97 ms` | `36.48 ms` | **`35.87 ms`** | **`1.16x`** |
| **Overall Score** | **`22.25 ms`** | `37.41 ms` | `37.30 ms` | `37.38 ms` | `~37.3 ms` | `0.60x` |
