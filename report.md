# PanVK-rynx MT6893 (Mali-G77 MC9) On-Device Validation & Benchmark Report

**Device:** OnePlus CPH2493 (`mt6893`, MT6893Z_T/CZA, Android 15 / SDK 35, `gpu_id 0x90800011`, kbase JM `11.38`)
**Base Tree:** [`zenithblue-oss/panvk-kbase-android`](https://github.com/zenithblue-oss/panvk-kbase-android) (`cf70e02b`, release `panvk-kbase-v26.3.1` / build `122i`, upstream Mesa `5a07217f034b3e50d8c7c7794f97a2df1742613b`, 228 base + 170 `jm-v7-wip` patches)
**Final Repo HEAD:** `0a1b19f` (`main`, patches `0001`–`0009`)
**Final Bionic CI Run:** `44461931990` (`success`, `libvulkan_panvk.so`, `35,675,280` bytes, sha256 `da10197c7f689af7708fae3f6697c2924600a71d9a8c26124f0e2204d4dd7652`)

---

## 1. Executive Summary

- **Rebase & MT6893 Bring-Up (`0001`–`0009`):**
  - Rebased `PanVK-rynx` from `apexspan-svg/mesa-panvk-mali-g57` (`v1.2.0`) onto `zenithblue-oss/panvk-kbase-android` (`v26.3.1` / Mesa `5a07217f`).
  - Fixed untrusted-app swapchain creation (`0001`), Mali-G77 JM `sync_file` semaphore import crash (`0002`), kbase non-DRM `copy_sync_payloads` `-13` error (`0003`), v9 `MALLOC_VERTEX_JOB` `gl_PointSize` (`0004`), v9 9-core compute `task_axis` (`0005`), Android non-tiled AFBC 1024 B body alignment (`0006`), linear swapchain allocation on `U_GRALLOC_TYPE_FALLBACK` to eliminate portrait/1080p `DISP_OVL` AFBC scanout noise (`0007`), dirty-only `kbase_kmod_jm_clean_imports()` (`0008`), and async JM `BASE_JD_REQ_SOFT_FENCE_TRIGGER` `sync_file` export (`0009`).
- **`vkvalidate` Suite (`0009` / `44461931990`):** **88 pass / 7 fail / 2 warn / 3 unsupported / 0 crashes** (100/100 verdicts).
  - +34 passes vs stock (`54`), +7 vs old `apexspan-svg` tree (`81`), +3 vs unmodified `zenithblue` (`85`).
  - `compat.ahb_import`, `compat.sync_fd_export`, and `core.point_size` all pass.
  - `perf.fb_local_barrier_overdraw`: **`1.26 ms`** vs stock **`1.66 ms`** (**`1.32x` faster**).
  - `perf.fb_local_barrier_large_draws`: **`14.00 ms`** vs stock **`13.35 ms`** (`0.95x`).
- **`com.faux.vktest` Speed Test (`valid: True`, `0009` / `44461931990`):**
  - Overall 1080p geomean: **`22.01 ms`** vs stock **`22.25 ms`** (beats stock; down from `37.30 ms` on the old `apexspan-svg` tree; `panvk_faux123_v1.1.8` scores `17.29 ms` on the same device).
  - `hdr_2160p` (3840x2160): **`34.61 ms`** vs stock **`41.55 ms`** (**`1.20x` faster** than stock and faster than `panvk_faux123_v1.1.8` `35.30 ms`).
  - `compute_nbody`: **`20.91 ms`** vs stock **`27.21 ms`** (**`1.30x` faster**; down from `90.91 ms` single-core before `0005`).
  - `oit_linked_lists`: **`22.76 ms`** vs stock **`22.68 ms`** (parity).
  - `subpasses`: **`23.63 ms`** vs stock **`22.21 ms`** (down from `31.61 ms` before `0008`/`0009`).
  - `pipeline_barriers`: **`20.88 ms`** vs stock **`17.87 ms`** (down from `69.56 ms` on old tree; `panvk_faux123_v1.1.8` achieves `10.51 ms` via JM framebuffer-local barrier optimization).

---

## 2. Patches (`0001`–`0009`)

| Patch | Commit | Purpose & Root Cause Fixed |
| :--- | :--- | :--- |
| `0001-mediatek-private-handle-afbc-and-dmabuf-fd.patch` | `9825aad` | Decode MediaTek `private_handle_t` (`magic == 0x03141592`, `alloc_format` at `ints[30..31]`) when AIMapper fails in untrusted app namespaces, and scan `/proc/self/fd/%d` for the `dmabuf` fd. |
| `0002-kbase-jm-sync-file-export-fallback.patch` | `e394ab9` | Keep `export_sync_file` registered on JM (`arch < 10`) kbase sync types so `get_semaphore_sync_type()` does not return `NULL` and segfault on `vkAcquireImageANDROID` / `ImportSemaphoreFdKHR`. |
| `0003-kbase-disable-drm-syncobj-copy-payloads.patch` | `9320cff` | Do not wire `vk_drm_syncobj_copy_payloads` on kbase (non-DRM) devices; fixes `QueueSignalReleaseImageANDROID failed: -13` (`VK_ERROR_UNKNOWN`). |
| `0004-panvk-jm-v9-point-size-in-malloc-vertex-job.patch` | `801a77c` | Set `point_size_array_format = MALI_POINT_SIZE_ARRAY_FORMAT_FP16` in v9 `MALLOC_VERTEX_JOB.PRIMITIVE` for `MESA_PRIM_POINTS`; fixes `compute_nbody` 1x1 dots and `core.point_size`. |
| `0005-panvk-jm-v9-compute-task-axis-and-increment.patch` | `801a77c` | Compute `task_axis`/`task_increment` across `compute_core_mask` on v9 JM `COMPUTE_JOB` instead of hardcoding `MALI_TASK_AXIS_Z`/`1` (fixes 1-of-9 core collapse in `compute_nbody`: `90.91 ms -> 20.91 ms`). |
| `0006-panfrost-android-afbc-1024b-body-align.patch` | `b45f3cc` | Align non-tiled AFBC `body_offset` to `1024 B` (`0x400`) on Android (`arch >= 6`), matching MediaTek `init_afbc`. |
| `0007-vk-android-linear-swapchain-on-fallback-gralloc.patch` | `9011017` | Request `GRALLOC_USAGE_SW_READ_RARELY \| GRALLOC_USAGE_SW_WRITE_RARELY` on `U_GRALLOC_TYPE_FALLBACK` (unless `PANVK_ANB_AFBC=1`) so swapchain buffers allocate linear (`DRM_FORMAT_MOD_LINEAR`), eliminating portrait/1080p `DISP_OVL` AFBC noise while keeping AFBC on internal render targets. |
| `0008-kbase-jm-dirty-only-import-sync.patch` | `03f66eb` | Track `nc_map_count`/`nc_dirty` in `kbase_kmod_bo_mmap`/`munmap` so `kbase_kmod_jm_clean_imports()` skips unmapped swapchain and static buffers. |
| `0009-kbase-jm-async-sync-file-fence-export.patch` | `03f66eb` / `0a1b19f` | Implement `kbase_kmod_jm_fence_after()` (`KBASE_IOCTL_STREAM_CREATE` + `BASE_JD_REQ_SOFT_FENCE_TRIGGER` `0x202`) for non-blocking async JM `sync_file` export on `vkQueuePresentKHR`. |

---

## 3. `vkvalidate` Results (`0009` / `44461931990` / `0a1b19f`)

- **Identity:** `Mali-G77 MC9`, `driver=panvk`, `Mesa 26.3.0-devel (git-3ebfcbac83, p0175, 2026-11-19)`
- **Verdicts:** `88 pass`, `7 fail`, `2 warn`, `3 unsupported`, `0 crashes` (100 total; stock baseline: `54 pass`, `2 fail`, `0 crashes`).
- **Perf microbenchmarks:**
  - `perf.fb_local_barrier_overdraw`: **`1.26 ms`** vs stock **`1.66 ms`** (**`1.32x` faster**)
  - `perf.fb_local_barrier_large_draws`: **`14.00 ms`** vs stock **`13.35 ms`** (`0.95x`)
  - `perf.occlusion_query_in_pass_cost`: `25.55 ms` vs stock `1.06 ms`

---

## 4. `com.faux.vktest` Speed Test Results (Best-Round Mean ms)

| Scene | Stock (`system`, `valid=True`) | Old `apexspan-svg` (`0036`, `valid=True`) | `panvk_faux123_v1.1.8` (`valid=True`) | Rebased `p0007` (`valid=True`) | **Rebased `p0009` (`valid=True`)** | Speedup vs Stock (`p0009`) |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| `oit_linked_lists` (1080p) | `22.68 ms` | `24.59 ms` | `22.27 ms` | `25.21 ms` | **`22.76 ms`** | `1.00x` |
| `subpasses` (1080p) | `22.21 ms` | `32.32 ms` | `19.49 ms` | `31.61 ms` | **`23.63 ms`** | `0.94x` |
| `compute_nbody` (1080p) | `27.21 ms` | `31.91 ms` | `19.60 ms` | `25.53 ms` | **`20.91 ms`** | **`1.30x`** |
| `pipeline_barriers` (1080p) | `17.87 ms` | `76.31 ms` | `10.51 ms` | `25.02 ms` | **`20.88 ms`** | `0.86x` |
| `hdr_2160p` (3840x2160) | `41.55 ms` | `35.97 ms` | `35.30 ms` | `34.81 ms` | **`34.61 ms`** | **`1.20x`** |
| **Overall 1080p Geomean** | **`22.25 ms`** | `37.30 ms` | **`17.29 ms`** | `26.71 ms` | **`22.01 ms`** | **`1.01x`** |
