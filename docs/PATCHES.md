# Patches

`PanVK-rynx` is rebased onto [`zenithblue-oss/panvk-kbase-android`](https://github.com/zenithblue-oss/panvk-kbase-android) (`cf70e02b`, release `panvk-kbase-v26.3.1` / build `122i`, upstream Mesa `5a07217f034b3e50d8c7c7794f97a2df1742613b`). `build.sh` and `build-bionic.sh` first run `scripts/prepare-rc5-tree.sh` from `panvk-kbase-android` and then apply this repository's patches in filename order with `patch -p1`.

| Patch | Purpose |
| :--- | :--- |
| `0001-mediatek-private-handle-afbc-and-dmabuf-fd.patch` | When vendor AIMapper loading fails in untrusted app namespaces (`[P0A-V19-FULLPLANE] mapper load failed`), decode MediaTek gralloc `private_handle_t` (`magic == 0x03141592`, `alloc_format` at `ints[30..31]`) into the exact `DRM_FORMAT_MOD_ARM_AFBC(...)` / `DRM_FORMAT_MOD_ARM_16X16_BLOCK_U_INTERLEAVED` / `DRM_FORMAT_MOD_LINEAR` modifier and scan `native_handle_t` fds via `/proc/self/fd/%d` for the `dmabuf` fd in both `u_gralloc_fallback.c` and `vk_android_import_anb_memory`. |
| `0002-kbase-jm-sync-file-export-fallback.patch` | Keep `export_sync_file` registered on JM (`arch < 10`) kbase sync types and wait for GPU completion before returning `*sync_file = -1` (already signaled). Prevents `get_semaphore_sync_type()` from returning `NULL` and segfaulting in `vk_common_ImportSemaphoreFdKHR` / `vkAcquireImageANDROID` / `wsi.present_wait` on Mali-G77 (`arch 9`). |
| `0003-kbase-disable-drm-syncobj-copy-payloads.patch` | Do not wire `device->vk.copy_sync_payloads = vk_drm_syncobj_copy_payloads` on kbase devices (non-DRM sync types). Forces `vk_common_QueueSignalReleaseImageANDROID` onto its `QueueSubmit2` wait-to-signal path instead of failing with `VK_ERROR_UNKNOWN` (`-13`) in DRM syncobj payload copy. |
