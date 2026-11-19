# Patches

`PanVK-rynx` is rebased onto [`zenithblue-oss/panvk-kbase-android`](https://github.com/zenithblue-oss/panvk-kbase-android) (`cf70e02b`, release `panvk-kbase-v26.3.1` / build `122i`, upstream Mesa `5a07217f034b3e50d8c7c7794f97a2df1742613b`). `build.sh` and `build-bionic.sh` first run `scripts/prepare-rc5-tree.sh` from `panvk-kbase-android` and then apply this repository's patches in filename order with `patch -p1`.

| Patch | Purpose |
| :--- | :--- |
| `0001-mediatek-private-handle-afbc-and-dmabuf-fd.patch` | When vendor AIMapper loading fails in untrusted app namespaces (`[P0A-V19-FULLPLANE] mapper load failed`), decode MediaTek gralloc `private_handle_t` (`magic == 0x03141592`, `alloc_format` at `ints[30..31]`) into the exact `DRM_FORMAT_MOD_ARM_AFBC(...)` / `DRM_FORMAT_MOD_ARM_16X16_BLOCK_U_INTERLEAVED` / `DRM_FORMAT_MOD_LINEAR` modifier and scan `native_handle_t` fds via `/proc/self/fd/%d` for the `dmabuf` fd in both `u_gralloc_fallback.c` and `vk_android_import_anb_memory`. |
