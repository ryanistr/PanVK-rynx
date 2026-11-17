# Patches

Applied in filename order to `apexspan-svg/mesa-panvk-mali-g57` tag `v1.2.0` by `build.sh`.
Patch bodies are kept byte-for-byte so they continue to apply to that tag.

| Patch | What it fixes |
|---|---|
| `0001-guard-ahb-path-for-glibc.patch` | The AHB-only allocation path calls helpers that are not compiled outside `__ANDROID__`; it returns `VK_ERROR_OUT_OF_DEVICE_MEMORY` early in a glibc build. |
| `0002-dma-heap-rdonly.patch` | On MT6893 every `/dev/dma_heap/*` node is `0444`, so the fork's `O_RDWR` open fails for the app uid. Falls back to `O_RDONLY`; `DMA_HEAP_IOCTL_ALLOC` and `mmap` work on that fd. Without it, exportable allocations fail and gamescope aborts with `VK_ERROR_INVALID_EXTERNAL_HANDLE`. |
| `0003-enable-valhall-gen3-arch-11.patch` | Ports arch 11 (Mali-G615/G715) wiring into the fork: genxml schema, per-arch build lists, arch dispatch, pandecode entries and model rows. The CSF side of the binary otherwise enumerates no device on a G615. |
| `0004-csf-fix-provoking-vertex-fn-address-truncation.patch` | `get_fb_descs()` held a 64-bit `fns_bo->addr.dev` in a `uint32_t`. On Android's SAME_VA kbase the address is above 4 GB, so the CSF frontend prefetched from a truncated address and every group faulted (`exception 0xc1`), cascading into DEVICE LOST. |
| `0005-kbase-report-node-rdev-as-drm-device.patch` | `panvk_physical_device_init_kbase()` left the DRM rdevs at zero, so Vulkan-to-DRM matching (including gamescope's WSI) silently failed. Reports `/dev/mali0`'s `st_rdev` as the render device. Guarded with `#ifndef __ANDROID__`; the bionic half keeps platform-reported numbers. |
| `0006-csf-single-merged-csg.patch` | Uses one merged CSG for all subqueues, with fence-wait generation reclaim instead of per-subqueue teardown. |
| `0007-csf-reported-register-count.patch` | Replaces a hardcoded 96-register file with `CLAMP((stream_features & 0xff) + 1, 96, 128)`, and sets `nr_kernel_registers` on the job-emission `cs_builder_conf` like every other builder in the tree. Under-sizing a 5th-gen part or letting the stream use a kernel-clobbered register both break command stream generation. |
| `0008-advertise-physical-device-drm.patch` | Derives `EXT_physical_device_drm` from the rdevs filled by 0005. Without it, 0005's properties are unreachable through `VkPhysicalDeviceProperties2` and gamescope logs "physical device doesn't support VK_EXT_physical_device_drm". |
| `0009-add-mali-g77-model-row.patch` | Adds the row for `PAN_PROD_ID(9, 0, 0)` — the G77's `gpu_id 0x90800011` — reusing the G57's Valhall v9 tile buffer sizes and rates. Without it the driver runs on the "Mali (unknown Valhall)" fallback with no anisotropic filtering or clock rates. |
| `0010-dump-the-real-swapchain-bo-size.patch` | Widens the native-BO debug dump from 640x480x4 only to also include 1600x720x4 (4608000 bytes), the swapchain size actually used in a session, so the guest's own post-CSYNC view of the presented buffer exists. |

0001-0003 and 0009-0010 are specific to the G77 bring-up path. 0004-0008 are CSF fixes for
the other Mali generations compiled into the same binary; they do not change arch-9 JM
submission.
