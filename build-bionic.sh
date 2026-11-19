#!/usr/bin/env bash
# PanVK-rynx - bionic (Android/NDK) build of the universal PanVK kbase driver.
#
# Rebased onto zenithblue-oss/panvk-kbase-android (v26.3.1 / build 122i, Mesa 5a07217f)
# plus this repository's patches (MT6893 MediaTek gralloc AFBC + dmabuf fd fallback).
set -euxo pipefail

VERSION=${PANVK_RYNX_VERSION:-26.3.1}
ZB_REPO=${PANVK_ZB_REPO:-https://github.com/zenithblue-oss/panvk-kbase-android.git}
ZB_COMMIT=${PANVK_ZB_COMMIT:-cf70e02b918e1864cbcd746a7fefa57b96c673ce}
MESA_REPO=${PANVK_MESA_REPO:-https://gitlab.freedesktop.org/mesa/mesa.git}
MESA_COMMIT=${PANVK_MESA_COMMIT:-5a07217f034b3e50d8c7c7794f97a2df1742613b}
API=${ANDROID_API:-29}
NDK_PATH=${ANDROID_NDK_ROOT:-/opt/android-ndk}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK=${GITHUB_WORKSPACE:-$PWD}
ZB="$WORK/zenithblue-src"
SRC="$WORK/mesa-bionic-src"
HT="$WORK/host-tools"
DEPS="$WORK/android-deps"
X11="$WORK/android-x11-deps"
BDIR="$WORK/build-bionic"
NDKBIN="$NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/bin"

test -d "$NDKBIN" || { echo "Android NDK not found at $NDK_PATH" >&2; exit 1; }

# ---- source: zenithblue-oss/panvk-kbase-android + pinned Mesa 5a07217f ---------
rm -rf "$ZB" "$SRC"
mkdir -p "$ZB" "$SRC"
git -C "$ZB" init -q
git -C "$ZB" remote add origin "$ZB_REPO"
git -C "$ZB" fetch -q --depth 1 origin "$ZB_COMMIT"
git -C "$ZB" checkout -q FETCH_HEAD

git -C "$SRC" init -q
git -C "$SRC" remote add origin "$MESA_REPO"
git -C "$SRC" fetch -q --depth 1 origin "$MESA_COMMIT"
git -C "$SRC" checkout -q FETCH_HEAD
git -C "$SRC" config user.name "PanVK-rynx"
git -C "$SRC" config user.email "panvk@local"

sh "$ZB/scripts/prepare-rc5-tree.sh" --mesa "$SRC"

cd "$SRC"
for p in "$SCRIPT_DIR"/patches/*.patch; do
   [ -f "$p" ] && patch -p1 --no-backup-if-mismatch < "$p"
done

# ---- host codegen tools (x86_64 native) ----------------------------------------
rm -rf "$HT"
sh "$ZB/scripts/bootstrap-host-tools.sh" --mesa "$SRC" --out "$HT"

# ---- Android sysroot bits: static libdrm + header-only X11/XCB -----------------
export PATH="$NDKBIN:$PATH"
CC_TRIPLE="aarch64-linux-android$API-clang"
cat > "$WORK/android-aarch64.ini" <<INI
[binaries]
c = '$CC_TRIPLE'
cpp = '${CC_TRIPLE}++'
ar = 'llvm-ar'
strip = 'llvm-strip'
pkg-config = 'pkg-config'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
INI

rm -rf "$DEPS" "$WORK/libdrm-src" "$WORK/libdrm-build"
git clone -q --depth 1 -b libdrm-2.4.125 https://gitlab.freedesktop.org/mesa/drm.git "$WORK/libdrm-src"
meson setup "$WORK/libdrm-build" "$WORK/libdrm-src" \
   --cross-file "$WORK/android-aarch64.ini" --prefix="$DEPS" --libdir=lib \
   -Dbuildtype=release -Ddefault_library=static \
   -Dintel=disabled -Dradeon=disabled -Damdgpu=disabled -Dnouveau=disabled \
   -Dvmwgfx=disabled -Domap=disabled -Dexynos=disabled -Dfreedreno=disabled \
   -Dtegra=disabled -Dvc4=disabled -Detnaviv=disabled -Dcairo-tests=disabled \
   -Dman-pages=disabled -Dvalgrind=disabled -Dtests=false -Dudev=false
ninja -C "$WORK/libdrm-build" install
mkdir -p "$DEPS/lib/pkgconfig"
cat > "$DEPS/lib/pkgconfig/zlib.pc" <<'PC'
Name: zlib
Description: zlib from the NDK sysroot
Version: 1.3
Libs: -lz
Cflags:
PC

sh "$ZB/scripts/prepare-x11-headers.sh" "$X11"

# ---- cross-build the bionic driver ---------------------------------------------
cat > "$WORK/bionic.cross.ini" <<INI
[binaries]
c = '$CC_TRIPLE'
cpp = '${CC_TRIPLE}++'
ar = 'llvm-ar'
strip = 'llvm-strip'
pkg-config = 'pkg-config'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
pkg_config_libdir = ['$DEPS/lib/pkgconfig', '$X11/lib/pkgconfig']
INI

export PATH="$HT/bin:$NDKBIN:$PATH"
rm -rf "$BDIR"
meson setup "$BDIR" "$SRC" --cross-file "$WORK/bionic.cross.ini" \
   -Dbuildtype=release -Dplatforms=android,x11 -Dandroid-stub=true -Dandroid-strict=false \
   -Dgallium-drivers= -Dvulkan-drivers=panfrost -Dpanfrost-kmds=kbase \
   -Dmesa-clc=system -Dprecomp-compiler=system -Dxlib-lease=disabled \
   -Degl=disabled -Dgles1=disabled -Dgles2=disabled -Dopengl=false \
   -Dglx=disabled -Dgbm=disabled -Dlibunwind=disabled -Dzstd=disabled \
   -Dcpp_link_args=-static-libstdc++
ninja -j"$(nproc)" -C "$BDIR" src/panfrost/vulkan/libvulkan_panfrost.so

SO="$BDIR/src/panfrost/vulkan/libvulkan_panfrost.so"
test -f "$SO"
readelf -sW "$SO" | grep -q panvk_v9_
readelf -sW "$SO" | grep -q panvk_v11_
if readelf -dW "$SO" | grep -qiE 'libLLVM|libclc|libLLVMSPIRV|libSPIRV'; then
   echo "driver links LLVM/SPIRV, which it must not" >&2
   readelf -dW "$SO" | grep -iE 'NEEDED' >&2
   exit 1
fi

# ---- package: AdrenoTools-style driver directory --------------------------------
OUT="$WORK/out-bionic"
rm -rf "$OUT"
mkdir -p "$OUT/usr/lib" "$OUT/usr/share/vulkan/icd.d"
cp "$SO" "$OUT/usr/lib/libvulkan_panvk.so"
llvm-strip --strip-unneeded "$OUT/usr/lib/libvulkan_panvk.so"
cat > "$OUT/usr/share/vulkan/icd.d/panvk_icd.aarch64.json" <<'ICD'
{
   "file_format_version": "1.0.1",
   "ICD": {
      "api_version": "1.3.354",
      "library_arch": "64",
      "library_path": "libvulkan_panvk.so"
   }
}
ICD
cat > "$OUT/meta.json" <<META
{
   "schemaVersion": 1,
   "kind": "android-vulkan-driver",
   "name": "PanVK-rynx-$VERSION-bionic",
   "description": "PanVK-rynx $VERSION (Android/bionic): universal Mali v6-v14 PanVK on kbase, rebased on zenithblue-oss/panvk-kbase-android ($ZB_COMMIT) + MT6893 MediaTek gralloc patches.",
   "author": "PanVK-rynx",
   "driverVersion": "$VERSION-bionic",
   "minApi": $API,
   "libraryName": "libvulkan_panvk.so",
   "gpuArch": [9, 10, 11],
   "importedAt": 0
}
META
cd "$OUT"
tar --use-compress-program="zstd -19" -cf "$WORK/PanVK-rynx-$VERSION-bionic.tzst" usr meta.json
sha256sum "$WORK/PanVK-rynx-$VERSION-bionic.tzst" > "$WORK/PanVK-rynx-$VERSION-bionic.tzst.sha256"
file "$OUT/usr/lib/libvulkan_panvk.so"
readelf -h "$OUT/usr/lib/libvulkan_panvk.so" | grep -E 'Class|Machine|OS/ABI'
ls -l "$WORK"/PanVK-rynx-*-bionic.tzst*
echo BIONIC_BUILD_OK
