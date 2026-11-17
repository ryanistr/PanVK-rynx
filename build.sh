#!/usr/bin/env bash
# PanVK-rynx - the Mali-G77 Vulkan driver, built for aarch64 glibc.
#
# Mesa's stock PanVK has no Valhall arch-9 Job Manager backend, so a Mali-G77 (MT6893,
# gpu_id 0x90800011) enumerates no device at all. This builds the one tree that does have
# a real v9 JM backend and its own kbase driver, applies this repository's patches, and
# publishes the result as PanVK-rynx-<version>-<patch>.tzst. The kbase backend is compiled
# in: there is no libpanvk_kbase_jm.so to keep beside the driver.
set -euxo pipefail

VERSION=${PANVK_RYNX_VERSION:-1.2.0}
PATCH=${PANVK_RYNX_PATCH:-}
CODENAME="PanVK-rynx-$VERSION${PATCH:+-$PATCH}"
SOURCE_REPO=${PANVK_SOURCE_REPO:-https://github.com/apexspan-svg/mesa-panvk-mali-g57.git}
SOURCE_TAG=${PANVK_SOURCE_TAG:-v$VERSION}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK=${GITHUB_WORKSPACE:-$PWD}

git clone -q --depth 1 --branch "$SOURCE_TAG" "$SOURCE_REPO" "$WORK/mesa-source"
cd "$WORK/mesa-source"

for p in "$SCRIPT_DIR"/patches/*.patch; do
    if [ -f "$p" ]; then
        patch -p1 --no-backup-if-mismatch < "$p"
    fi
done

# panfrost-kmds=kbase is what defines HAVE_PAN_KMOD_KBASE; panvk-use-kbase selects the
# backend. Wayland and x11 build the WSI gamescope presents through. Gallium is empty on
# purpose: only the Vulkan driver is wanted.
meson setup builddir \
    -Dbuildtype=release \
    -Dvulkan-drivers=panfrost \
    -Dgallium-drivers= \
    -Dplatforms=wayland,x11 \
    -Dpanvk-use-kbase=true \
    -Dpanfrost-kmds=kbase,panthor \
    -Ddebug=false \
    -Dbuild-tests=false \
    -Dprefix=/usr \
    -Dlibdir=lib

ninja -C builddir src/panfrost/vulkan/libvulkan_panfrost.so
test -f builddir/src/panfrost/vulkan/libvulkan_panfrost.so

mkdir -p "$WORK/out/usr/lib" "$WORK/out/usr/share/vulkan/icd.d"
cp builddir/src/panfrost/vulkan/libvulkan_panfrost.so "$WORK/out/usr/lib/libvulkan_panvk.so"

# The G77 needs the v9 Job Manager backend. v10/v11 are the CSF backends used by other
# Mali generations in the same binary; arch 11 only exists here because of patch 0003.
# Check before stripping: these are local symbols and --strip-unneeded removes them.
readelf -sW "$WORK/out/usr/lib/libvulkan_panvk.so" | grep -q 'panvk_v9_' \
    || { echo "built driver has no v9 backend" >&2; exit 1; }
readelf -sW "$WORK/out/usr/lib/libvulkan_panvk.so" | grep -q 'panvk_v10_' \
    || { echo "built driver has no v10 CSF backend" >&2; exit 1; }
readelf -sW "$WORK/out/usr/lib/libvulkan_panvk.so" | grep -q 'panvk_v11_' \
    || { echo "built driver has no v11 backend (0003 not applied?)" >&2; exit 1; }

strip --strip-unneeded "$WORK/out/usr/lib/libvulkan_panvk.so"

# gamescope needs external memory / semaphore fd interop, which the source tree gates on
# this string. A build without it cannot advertise the extensions gamescope requires.
strings -a "$WORK/out/usr/lib/libvulkan_panvk.so" | grep -q 'PANVK_FD_INTEROP' \
    || { echo "built driver predates the PANVK_FD_INTEROP gate" >&2; exit 1; }

# LLVM, libclc and the SPIR-V translator build mesa_clc only. None of them may end up in
# the driver the runtime loads.
if readelf -dW "$WORK/out/usr/lib/libvulkan_panvk.so" | grep -qiE 'libLLVM|libclc|libLLVMSPIRV|libSPIRV'; then
    echo "driver links LLVM/SPIRV, which it must not" >&2
    readelf -dW "$WORK/out/usr/lib/libvulkan_panvk.so" | grep -iE 'NEEDED' >&2
    exit 1
fi

cat > "$WORK/out/usr/share/vulkan/icd.d/panvk_icd.aarch64.json" <<ICD
{
    "file_format_version": "1.0.1",
    "ICD": {
        "api_version": "1.3.354",
        "library_arch": "64",
        "library_path": "/usr/lib/libvulkan_panvk.so"
    }
}
ICD

cat > "$WORK/out/meta.json" <<META
{
    "schemaVersion": 1,
    "kind": "linux-vulkan-icd",
    "name": "$CODENAME",
    "description": "PanVK-rynx $VERSION - the Mali-G77 Vulkan driver (glibc): Valhall v9 Job Manager and v10/v11 CSF on the source tree's own kbase backend. Built from $SOURCE_REPO with this repository's patches.",
    "driverVersion": "$VERSION${PATCH:+-$PATCH}",
    "libc": "glibc",
    "minGlibc": "2.35",
    "gpuArch": [9, 10, 11],
    "sourceLibraryName": "libvulkan_panvk.so",
    "importedAt": 0
}
META

cd "$WORK/out"
# The patch is part of the asset name: consumers identify an installed build by asset name.
tar --use-compress-program="zstd -19" -cf "$WORK/$CODENAME.tzst" usr meta.json
sha256sum "$WORK/$CODENAME.tzst" > "$WORK/$CODENAME.tzst.sha256"
ls -l "$WORK/$CODENAME.tzst"*
