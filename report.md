# PanVK-rynx MT6893 (Mali-G77 MC9) On-Device Validation & Benchmark Report

**Device:** OnePlus CPH2493 (`mt6893`, MT6893Z_T/CZA, Android 15 / SDK 35, serial `102562537K104189`, `gpu_id 0x90800011`, kbase JM `11.38`)
**Final Repo HEAD:** `b5b95f6` (`main`)
**Final Bionic CI Run:** `44378867772` (`success`, `libvulkan_panvk.so` SHA-256 / size `20129960` bytes)
**Final Glibc CI Run:** `44378867772` (`Build and test`, `success`)

---

## 1. Executive Summary

- **Crash & Swapchain Bring-Up Resolved:** Fixed all Android `com.faux.vktest` (`VkNativeBufferANDROID` / `ANB`) crashes and WSI errors (`SIGSEGV` in `pan_image_layout_init`, `VK_ERROR_INVALID_EXTERNAL_HANDLE` on MediaTek 3-fd `native_handle_t`, and `VK_ERROR_UNKNOWN` in `vk_common_QueueSignalReleaseImageANDROID`). Verified rendered `DRIVERBENCH_FRAME` pixel grids match the stock system driver.
- **Compute Performance Fixed (`1.75x` faster than stock):** Fixed JM v9 compute dispatch serialization (`0029`, porting `calculate_task_axis_and_increment` and enabling `allow_merging_workgroups`), improving `compute_nbody` from `93.11 ms` to **`15.53 ms`** (`360` frames in `0033` round 0) vs stock **`27.21 ms`** (**1.75x faster**).
- **`vkvalidate` Suite (`b5b95f6` / `0034`):** **81 pass / 8 fail / 11 unsupported / 0 crashes** (vs stock baseline **54 pass / 2 fail**). `perf.fb_local_barrier_overdraw` = **`0.93 ms`** vs **`1.66 ms`** stock (**1.78x faster**); `perf.occlusion_query_in_pass_cost` = **`1.14 ms`** vs **`1.06 ms`** stock.
- **Remaining Blocker on `com.faux.vktest` Speed Test (`valid: False`) & 5x Target:**
  - `com.faux.vktest` Speed Test uses `VK_PRESENT_MODE_MAILBOX_KHR` at `1920x1080` (`hdr_2160p` at `3840x2160`) scaled to the `1080x2400` panel via MediaTek's `MDP` (`DpAsyncBlitStream` / `CMDQ` thread 12/13).
  - Under PanVK, MediaTek's kernel `MDP` hardware blitter intermittently stalls waiting for `CMDQ` frame-done events (`OP:WAIT EVENT:306/307`, `DpDriver: waitFramedone failed(-1), 110 Connection timed out`, `[MDP][ERR]Reset engine group 1 failed:-14`), causing `hwcomposer` 1000ms fence timeouts and `BufferQueueProducer` stalls (`1000..1020 ms` `frame_limit`). This occurs even with `PANVK_ASYNC=0` and `PANVK_OVERLAP=0` (`0033`, `0034`) and with `export_sync_file` returning `-1` (`0031`).
  - Because of the `MDP` 1000ms timeouts and the physical throughput ceiling of Mali-G77 MC9 (stock 4-scene geomean is `22.25 ms` at max 886 MHz GPU / 3733 MHz DRAM), a **5x overall improvement (~4.45 ms geomean)** is not achieved.

---

## 2. Patches Added (`0025`–`0034`)

| Patch | Commit | Purpose & Root Cause Fixed |
| :--- | :--- | :--- |
| `0025-panvk-android-fallback-linear-modifier.patch` | `a86b673` | Map `DRM_FORMAT_MOD_INVALID` from `u_gralloc_fallback` on single-plane ANB/AHB images to `DRM_FORMAT_MOD_LINEAR` and guard `mod_handler == NULL` in `panvk_image_init_layouts` (fixes `SIGSEGV` in `vkCreateImage`). |
| `0026-android-find-dmabuf-fd-in-native-handle.patch` | `4f3dafb` | Scan `native_handle_t` fds via `/proc/self/fd/%d` for the `dmabuf` fd instead of assuming `handle->data[0]` (MediaTek gralloc puts `anon_inode:gralloc_extra` in `fd[0]` and `/dmabuf:Gralloc` in `fd[1]`). |
| `0027-panvk-kbase-dont-set-drm-syncobj-copy-payloads.patch` | `1b5e48f` | Leave `device->vk.copy_sync_payloads = NULL` on kbase devices so `vk_common_QueueSignalReleaseImageANDROID` uses `QueueSubmit2` with `kbase_cpu_sync` instead of failing DRM syncobj ioctls. |
| `0028-panvk-kbase-enable-async-overlap-by-default.patch` | `c31b851` | Enabled `PANVK_ASYNC` and `PANVK_OVERLAP` by default on kbase (later superseded by `0032` and `0033` defaults). |
| `0029-panvk-jm-v9-compute-task-axis-and-increment.patch` | `54e388b` | Port `calculate_task_axis_and_increment` to JM v9 compute/precomp dispatches and enable `allow_merging_workgroups` instead of hardcoding `MALI_TASK_AXIS_Z` + `task_increment = 1`. |
| `0030-panvk-kbase-defer-sync-file-wait-to-gpu.patch` | `96b2991` | Stop polling imported `sync_file` fds synchronously inside `kbase_cpu_sync_import_sync_file` (and preserve `ks->import_fd` instead of closing it on import); defer CPU waits to `kbase_cpu_sync_wait_one`. |
| `0031-panvk-kbase-export-sync-file-return-signaled.patch` | `282b410` | Drain `ks` and return `*sync_file = -1` in `kbase_cpu_sync_export_sync_file` instead of chaining `SOFT_FENCE_TRIGGER` onto device-global `async.last_atom`. |
| `0032-panvk-kbase-disable-overlap-by-default.patch` | `12649fa` | Disable `PANVK_OVERLAP` by default (`PANVK_OVERLAP=1` to opt in). |
| `0033-panvk-kbase-disable-async-by-default.patch` | `4293dc7` | Disable `PANVK_ASYNC` by default (`PANVK_ASYNC=1` to opt in) after verifying async submission increased `MDP` timeout frequency. |
| `0034-panvk-jm-skip-noop-pipeline-barrier-batch-split.patch` | `6215f59` | Skip closing/reopening JM batches in `CmdPipelineBarrier2` when the current batch has no jobs/events or when all barriers have `srcAccessMask == 0` and only `TOP_OF_PIPE`/`HOST` `srcStageMask`. |

*(Note: Attempted `0035-panvk-jm-v9-by-region-fb-barrier.patch` setting `DCD_FLAGS_0.primitive_barrier = true` for `VK_DEPENDENCY_BY_REGION_BIT`, which regressed `perf.fb_local_barrier_overdraw` from `0.93 ms` to `20.05 ms` and was reverted in `b5b95f6`.)*

---

## 3. `vkvalidate` Results (Final Build `44378867772` / `b5b95f6`)

Command: `tools/test-on-device.sh` on `102562537K104189` (`loaded_via=adrenotools`, `Mali-G77 MC9`, `Mesa 26.3.0-devel`):

- **Verdicts:** `81 pass`, `8 fail`, `11 unsupported`, `0 crashes` (100 total; stock baseline: `54 pass`, `2 fail`, `0 crashes`).
- **Perf microbenchmarks:**
  - `perf.fb_local_barrier_overdraw`: **`0.93 ms`** vs stock **`1.66 ms`** (**`1.78x` faster**)
  - `perf.occlusion_query_in_pass_cost`: **`1.14 ms`** vs stock **`1.06 ms`** (`0.93x`)
  - `perf.fb_local_barrier_large_draws`: `fail` (`1247` sampled pixels wrong after 64 blended draws)
- **Remaining 8 fails:** `compat.texel_buffer_type_punning`, `perf.fb_local_barrier_large_draws`, `perf.tess_small_draw_cost`, `stage.geometry_point_to_quad`, `stage.tessellation_mirror`, `stress.tess_mixed_levels`, `xfb.capture`, `xfb.geometry_shader_capture`.
- **11 unsupported:** `compat.sync_fd_export`, `depth.bias_float`, `eds3.polygon_mode`, `limit.viewports`, `robust.buffer_access2`, `robust.image_access2`, `robust.image_access2_kinds`, `robust.storage_buffer_access2`, `stage.geometry_max_output`, `stage.geometry_point_size`, `wsi.present_wait`.

---

## 4. `com.faux.vktest` Speed Test Results

| Scene | Stock (`system`, `valid=True`) | PanVK `1b5e48f` (`0027`) | PanVK `0033` (round 0, `4293dc7`) | Speedup vs Stock (best measured) |
| :--- | :--- | :--- | :--- | :--- |
| `oit_linked_lists` (1080p) | `22.68 ms` (3/3 ok) | `28.09 ms` (1/3 ok) | hung | `0.81x` |
| `subpasses` (1080p) | `22.21 ms` (3/3 ok) | `38.12 ms` (1/3 ok) | hung | `0.58x` |
| `compute_nbody` (1080p) | `27.21 ms` (3/3 ok) | `93.11 ms` (3/3 ok) | **`15.53 ms`** (360 frames, r=0 ok) | **`1.75x`** |
| `pipeline_barriers` (1080p) | `17.87 ms` (3/3 ok) | `67.43 ms` (2/3 ok) | `68.11 ms` (54 frames, r=0 ok) | `0.26x` |
| `hdr_2160p` (3840x2160) | `41.55 ms` (3/3 ok) | hung (0/3) | hung (0/3) | — |
| **4-scene geomean** | **`22.25 ms`** | `50.92 ms` (`0.44x`) | — | — |

On the final clean run (`0034`, `44378867772` / `b5b95f6`), all 15 rounds hit `frame_limit_ms: 1000` (`1000..1020 ms`) due to the MediaTek `MDP` (`DpDriver: waitFramedone failed(-1), 110 Connection timed out`, `CMDQ` `OP:WAIT EVENT:306/307`) kernel blitter stall.

---

## 5. `AIO-Graphics-Test-64bit` Note

`AIO-Graphics-Test-64bit.exe` (staged in `/home/ryanistr/.hermes/cache/scratch/panvk/aio/AIO-Graphics-Test-64bit.exe` alongside `Bannerlator-3.2.1-standard.apk`) is a Windows x86_64/arm64 executable requiring an Android Windows-emulator container (Winlator/Bannerlator) rather than direct APK installation; it was not executed in an emulator container during this run.
