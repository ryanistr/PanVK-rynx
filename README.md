# PanVK-rynx

A standalone, Mali-G77-focused Vulkan driver: Mesa PanVK built for aarch64 **glibc** with a
Valhall **arch-9 Job Manager** backend and an in-tree `mali_kbase` backend. It is the driver
that a Linux guest (Steam, Proton, gamescope, the desktop) uses on MediaTek MT6893 devices
such as the Infinix GT 10 Pro (X6739), where the GPU is a Mali-G77 MC9 (`gpu_id 0x90800011`)
and the only path to the 3D engine is `/dev/mali0`.

This repository builds and publishes the driver. It is not an Android app and not the
system/compositor driver — the Android-side compositor has its own bionic driver, which is
maintained separately in [DroidDeck](https://github.com/ryanistr/DroidDeck-Mali).

## Why this exists

Stock Mesa PanVK enables arches 6, 7 and 10 only. A G77 is Valhall arch 9 with a Job Manager,
so upstream produces no physical device for it. The source tree used here
(`apexspan-svg/mesa-panvk-mali-g57`, Mesa 26.3.0-devel) carries the v9 JM backend and its own
kbase code. On top of it this repository applies twelve patches that make the driver work on
MT6893: dma-heap nodes that are `0444`, a missing G77 model row, real swapchain BO dumps,
the DRM device numbers gamescope matches on, and CSF fixes for the newer Mali generations
compiled into the same binary. See [docs/PATCHES.md](docs/PATCHES.md).

The driver is self-contained: the kbase backend is compiled into `libvulkan_panvk.so`.
There is no `libpanvk_kbase_jm.so` to ship beside it.

## Build

On an `ubuntu-24.04-arm` runner (Mesa 26.3 needs meson >= 1.4):

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

`build.sh` writes `PanVK-rynx-<version>-<patch>.tzst` and its `.sha256` in the working
directory. The archive contains `usr/lib/libvulkan_panvk.so`,
`usr/share/vulkan/icd.d/panvk_icd.aarch64.json` and `meta.json`.

| Variable | Default | Meaning |
|---|---|---|
| `PANVK_RYNX_VERSION` | `1.2.0` | Source tag `v<version>` and driver version |
| `PANVK_RYNX_PATCH` | empty | Patch level from the release tag, e.g. `p7` |
| `PANVK_SOURCE_REPO` | `apexspan-svg/mesa-panvk-mali-g57` | Source tree (read-only upstream fork) |
| `PANVK_SOURCE_TAG` | `v$PANVK_RYNX_VERSION` | Source tag to check out |

The build fails rather than publishing a driver that cannot drive the G77: it asserts the
v9, v10 and v11 backends are present before stripping, requires the `PANVK_FD_INTEROP`
gate gamescope depends on, and refuses to link LLVM/SPIRV into the shipped library.

## Releases

Releases are tagged `PanVK-rynx-<version>-<patch>` and carry
`PanVK-rynx-<version>-<patch>.tzst` plus its `.sha256`. They are consumed by build tooling
that fetches the tag and verifies the checksum; they are not user-installable APKs and are
kept out of "Latest".

`release.env` records the source pin and the currently recommended release. p7
(`85a6935490d00876925945404cf6135bad3cf1d640c3fa96d8217df252b798c3`) is byte-identical to
the asset previously published in `ryanistr/DroidDeck-Mali` — only its home changes. That
asset must be published under this repository's tag with the same checksum before
DroidDeck's `tools/build_local.sh` and CI can fetch it. The exact commands to create the
repo, push it and migrate that asset are in [docs/PUBLISH.md](docs/PUBLISH.md).

## Support and status

The driver advertises `gpuArch [9, 10, 11]`. v12-v14 CSF objects are compiled into the same
binary but are not advertised because no G720-family device has been run from this tree.
Arch 10/11 devices need a kbase CSF backend; the G77 uses v9 JM and is the reference target.
See [docs/STATUS.md](docs/STATUS.md) for what works, what is still broken, and the next
experiments.

## Provenance and license

The driver is built from Mesa (`src/panfrost/vulkan`), from the read-only
`apexspan-svg/mesa-panvk-mali-g57` fork. Individual patches carry their own `From:` lines
naming where they came from. Packaging scripts here are original to this repository.
See [LICENSE.md](LICENSE.md).
