# PanVK-rynx

A standalone, high-performance Mali-G77-focused Vulkan driver: Mesa PanVK built with a Valhall
**arch-9 Job Manager** backend and an in-tree `mali_kbase` kernel driver interface (`/dev/mali0`).
It supports both **aarch64 Android Bionic** (for Android apps, test suites, and microbenchmarks)
and **aarch64 Linux glibc** (for guest environments: Steam, Proton, gamescope, and desktop Wayland/X11).

The reference device is the MediaTek MT6893 / Dimensity 1200 (OnePlus Nord 2T / CPH2493, Infinix GT 10 Pro / X6739),
featuring a 9-core Mali-G77 MC9 (`gpu_id 0x90800011`, core mask `0x00660067`).

---

## Architecture & Base Tree

Upstream Mesa PanVK focuses primarily on Bifrost (arches 6, 7) and newer Valhall CSF (arch 10+).
Mali-G77 is a Valhall arch-9 GPU that uses the legacy Job Manager (JM) submission architecture rather than CSF.

`PanVK-rynx` is rebased onto [`zenithblue-oss/panvk-kbase-android`](https://github.com/zenithblue-oss/panvk-kbase-android)
(`cf70e02b`, release `v26.3.1` / build `122i`, upstream Mesa `5a07217f034b3e50d8c7c7794f97a2df1742613b`),
incorporating 228 base patches and 170 `jm-v7-wip` patches. On top of this tree, this repository
maintains hardware-specific fixes and optimizations for MediaTek MT6893 / kbase platforms.

The driver is entirely self-contained: the `kbase` backend is compiled directly into `libvulkan_panvk.so`.
No external `libpanvk_kbase_jm.so` or separate shim is needed.

---

## Active Patches (`patches/`)

Patches are applied in filename order by `build.sh` and `build-bionic.sh` via `patch -p1`:

| Patch | Purpose |
| :--- | :--- |
| [`0001-mediatek-private-handle-afbc-and-dmabuf-fd.patch`](patches/0001-mediatek-private-handle-afbc-and-dmabuf-fd.patch) | Decodes MediaTek `private_handle_t` (`magic 0x03141592`) for AFBC modifier detection and recovers dmabuf fds via `/proc/self/fd/%d` when vendor AIMapper fails in untrusted app namespaces. |
| [`0002-kbase-jm-sync-file-export-fallback.patch`](patches/0002-kbase-jm-sync-file-export-fallback.patch) | Keeps `export_sync_file` registered on JM (`arch < 10`) kbase sync types to prevent `get_semaphore_sync_type()` returning `NULL` and segfaulting in `vk_common_ImportSemaphoreFdKHR` / `vkAcquireImageANDROID`. |
| [`0003-kbase-disable-drm-syncobj-copy-payloads.patch`](patches/0003-kbase-disable-drm-syncobj-copy-payloads.patch) | Prevents wiring `vk_drm_syncobj_copy_payloads` on kbase devices; routes `QueueSignalReleaseImageANDROID` to `QueueSubmit2` instead of failing with `-13` (`VK_ERROR_UNKNOWN`). |
| [`0004-panvk-jm-v9-point-size-in-malloc-vertex-job.patch`](patches/0004-panvk-jm-v9-point-size-in-malloc-vertex-job.patch) | Sets `cfg.point_size_array_format = MALI_POINT_SIZE_ARRAY_FORMAT_FP16` in v9 `MALLOC_VERTEX_JOB.PRIMITIVE` for `MESA_PRIM_POINTS`; fixes `gl_PointSize` and `core.point_size`. |
| [`0005-panvk-jm-v9-compute-task-axis-and-increment.patch`](patches/0005-panvk-jm-v9-compute-task-axis-and-increment.patch) | Computes `task_axis` and `task_increment` across `compute_core_mask` for Valhall v9 JM `COMPUTE_JOB` payloads, distributing work across all 9 shader cores (`compute_nbody` 90.91 ms -> 20.91 ms). |
| [`0006-panfrost-android-afbc-1024b-body-align.patch`](patches/0006-panfrost-android-afbc-1024b-body-align.patch) | Aligns non-tiled AFBC `body_offset` to 1024 B (`0x400`) on Android (`arch >= 6`), matching MediaTek `init_afbc` and MTK `DISP_OVL` hardware scanout alignment. |
| [`0007-vk-android-linear-swapchain-on-fallback-gralloc.patch`](patches/0007-vk-android-linear-swapchain-on-fallback-gralloc.patch) | Requests `GRALLOC_USAGE_SW_READ_RARELY \| GRALLOC_USAGE_SW_WRITE_RARELY` on fallback gralloc so swapchain buffers allocate linear (`DRM_FORMAT_MOD_LINEAR`), eliminating portrait/1080p `DISP_OVL` scanout noise while preserving AFBC on internal render targets. |
| [`0008-kbase-jm-dirty-only-import-sync.patch`](patches/0008-kbase-jm-dirty-only-import-sync.patch) | Tracks `nc_map_count` and `nc_dirty` so `kbase_kmod_jm_clean_imports()` skips unmapped swapchain and static BOs, eliminating unnecessary `DMA_BUF_IOCTL_SYNC` flushes. |
| [`0009-kbase-jm-async-sync-file-fence-export.patch`](patches/0009-kbase-jm-async-sync-file-fence-export.patch) | Implements `kbase_kmod_jm_fence_after()` using `KBASE_IOCTL_STREAM_CREATE` + `BASE_JD_REQ_SOFT_FENCE_TRIGGER` (`0x202`) for non-blocking async `sync_file` export on `vkQueuePresentKHR`. |

See [docs/PATCHES.md](docs/PATCHES.md) for full patch details.

---

## Building

### 1. Android Bionic Build (`build-bionic.sh`)

Requires an Android NDK (r27c recommended) on Linux x86_64:

```sh
export ANDROID_NDK_ROOT=/path/to/android-ndk-r27c
./build-bionic.sh
```

The script fetches the pinned `zenithblue-oss/panvk-kbase-android` and Mesa trees, bootstraps native host codegen tools, cross-compiles static `libdrm`, applies `patches/*.patch`, and compiles `libvulkan_panvk.so` for Android API 29+ aarch64.

CI workflow: [`.github/workflows/build-bionic.yml`](.github/workflows/build-bionic.yml).

### 2. Linux Glibc Build (`build.sh`)

On an `ubuntu-24.04-arm` (aarch64) runner or native arm64 host:

```sh
sudo apt-get install -y --no-install-recommends \
  git ninja-build pkg-config patch python3-mako python3-ply python3-yaml python3-packaging \
  libwayland-dev libwayland-egl-backend-dev libdrm-dev libx11-dev libxext-dev libx11-xcb-dev \
  libxcb1-dev libxcb-dri3-dev libxcb-present-dev libxcb-sync-dev libxcb-xfixes0-dev \
  libxcb-randr0-dev libxcb-shm0-dev libxcb-keysyms1-dev libxfixes-dev libxrandr-dev \
  libxshmfence-dev libxxf86vm-dev libglvnd-dev libegl-dev libgles-dev libelf-dev \
  zlib1g-dev libzstd-dev libexpat1-dev bison flex zstd libdisplay-info-dev libudev-dev \
  wayland-protocols llvm-18-dev libclang-18-dev libclc-18-dev libllvmspirvlib-18-dev spirv-tools
python3 -m pip install --break-system-packages -U 'meson>=1.4'
./build.sh
```

`build.sh` produces `PanVK-rynx-<version>-<patch>.tzst` containing `usr/lib/libvulkan_panvk.so`, `usr/share/vulkan/icd.d/panvk_icd.aarch64.json`, and `meta.json`.

---

## On-Device Verification (Mali-G77 MC9, Android 15)

Tested on OnePlus CPH2493 (MT6893, Mali-G77 MC9 r0p1 `0x9080`, kbase `11.38`):

### 1. `vkvalidate` Conformance & Microbenchmarks (100 Tests)
- **Results:** **88 pass / 7 fail / 2 warn / 3 unsupported / 0 crashes** (+34 passes over stock Android driver).
- `compat.ahb_import`, `compat.sync_fd_export`, and `core.point_size` pass.
- `perf.fb_local_barrier_overdraw`: **`1.26 ms`** vs stock **`1.66 ms`** (**1.32x faster**).

### 2. `com.faux.vktest` Speed Test
- **Overall 1080p Geomean:** **`22.01 ms`** vs stock **`22.25 ms`** (beats stock driver).
- `compute_nbody`: **`20.91 ms`** vs stock **`27.21 ms`** (**1.30x faster**).
- `hdr_2160p` (3840x2160): **`34.61 ms`** vs stock **`41.55 ms`** (**1.20x faster**).
- `oit_linked_lists`: **`22.76 ms`** vs stock **`22.68 ms`** (parity).
- `pipeline_barriers`: **`20.88 ms`** vs stock **`17.87 ms`**.

Full hardware telemetry, log analysis, and comparative charts are documented in [report.md](report.md).

---

## License & Provenance

The driver is built on Mesa (`src/panfrost/vulkan`), incorporating contributions from the Panfrost and Mesa communities, `apexspan-svg`, and `zenithblue-oss`. Packaging and integration logic are licensed under MIT. See [LICENSE.md](LICENSE.md).
