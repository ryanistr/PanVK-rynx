# Status (2026-11-17)

Status of the **driver**, not of the whole Steam-in-a-rootfs stack. Full on-device history
and evidence live in DroidDeck's
[`docs/development/panvk-mali-g77-bringup.md`](https://github.com/ryanistr/DroidDeck-Mali/blob/main/docs/development/panvk-mali-g77-bringup.md).

## Working

- The G77 is recognized by name. `gpu_id 0x90800011` maps to the G77 row added in 0009; the
  "unknown Valhall" fallback is gone (verified in session `2026-11-06-07-steam`).
- A guest session reaches `READY` with a first frame and renders through the GPU, not
  software. Valhall v9 Job Manager submission over `/dev/mali0` works.
- The driver is self-contained: the kbase backend is compiled in, with no
  `libpanvk_kbase_jm.so` dependency and no LLVM/SPIRV linkage in the shipped `.so`.
- The dma-heap `0444` problem is fixed (0002); the dma-buf fd interop extensions gamescope
  requires are gated on and present.
- The v9, v10 and v11 backends are all compiled into the one library; backend selection is
  from the GPU id at runtime.
- `DMA_BUF_IOCTL_SYNC` (the only sync ioctl in the 5.10 uapi) answers `r=0`; the compositor
  can ask the exporter to make guest writes visible before sampling.

## Not working / open

- **Full tile buffer (0014) faults real games.** Giving a v9 render pass the whole tile
  buffer hard-stopped every JM atom in GTA V (`event=0x4`, `vkWaitForFences` = -4);
  patch 0015 makes it opt-in (`PANVK_V9_FULL_TIB=1`) and restores half-size pipelined
  tiles as the default. Evidence: `test-results/GameCrash-20261119-175724.txt`.
- **Swapchain ping-pong.** The guest presents a three-slot ring that holds two contents and
  rotates; the guest then stops committing entirely, which shows as a frozen screen until
  input arrives. Two compositor-side mitigations were measured and reverted because they
  hid the symptom or froze the picture. The remaining suspects are the guest's WSI/swapchain
  write visibility and its ring contents.
- **Present-path dilemma.** `PANVK_KBASE_DRI3=1` sets `kbase_dmabuf=1`, which makes the
  screen draw but requires DRI3 in the guest X server. The session exports
  `XWAYLAND_NO_GLAMOR=1`, so there is no DRI3: zink fails to create a swapchain and GLX dies.
  Setting the knob to `0` removes those errors but presents nothing.
- **Client UI on SwiftShader.** With no glamor there is no `GLX_ARB_create_context` and no
  DRI3, so CEF/ANGLE initialises a software display. The boot lag and ~5 fps UI come from
  here, not from the v9 backend.
- **Guest-side ground truth.** The widened BO dump from 0010 is in p7, but `NATIVEBO CSYNC`
  has not printed yet, so the guest's own view of the swapchain bytes is still missing.
- **Bionic half.** The compositor's Android driver is a separate asset. The bundled one
  predates 0009 and still runs on the "unknown Valhall" fallback; it needs a rebuild from a
  tree with the G77 row. Dependency/soname issues (missing `libandroid-shmem.so`, vendor
  `libdrm.so` shadowing) have also been observed when loading PanVK in the compositor.
- **CSF devices.** Arch 10/11 GPUs (GT 20 Pro G610, GT 30 Pro G615) have a CSF kbase but no
  published CSF-specific guest build. v12-v14 objects are compiled but unadvertised.

## Next experiments

1. A/B the `DMA_BUF_IOCTL_SYNC` bracket on an *animating* Big Picture UI, reading the
   compositor from `app.log` and using `cdp targets` (not screen brightness) as the liveness
   oracle.
2. Capture the guest's `NATIVEBO CSYNC` bytes and compare them with the host's CPU and GPU
   reads of the same dma-buf. If they differ, the fix is guest write visibility; if they
   agree, the fix is the guest's ring.
3. Drop the `XWAYLAND_NO_GLAMOR=1` export for one session build, so the guest X offers DRI3
   and `GLX_ARB_create_context`. This needs an APK rebuild because session scripts are
   re-staged from the APK at every launch.
4. Rebuild the bionic asset with the G77 model row.
