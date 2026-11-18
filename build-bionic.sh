#!/usr/bin/env bash
# PanVK-rynx - bionic (Android/NDK) build of the G77 PanVK driver.
#
# The main build.sh produces the glibc ICD for DroidDeck. This script produces the
# Android/bionic counterpart (AdrenoTools-style: libvulkan_panvk.so + meta.json) from the
# exact same tag and patches, so both targets are validated against one source state.
# It is intended for GitHub Actions on an x86_64 runner with the Android NDK available.
set -euxo pipefail

VERSION=${PANVK_RYNX_VERSION:-1.2.0}
TAG=${PANVK_SOURCE_TAG:-v$VERSION}
REPO=${PANVK_SOURCE_REPO:-https://github.com/apexspan-svg/mesa-panvk-mali-g57.git}
NDK_PATH=${ANDROID_NDK_ROOT:-/opt/android-ndk}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK=${GITHUB_WORKSPACE:-$PWD}
SRC="$WORK/mesa-bionic-src"
HT="$WORK/host-tools"
DEPS="$WORK/android-deps"
X11="$WORK/android-x11-stub"
BDIR="$WORK/build-bionic"
NDKBIN="$NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/bin"

test -d "$NDKBIN" || { echo "Android NDK not found at $NDK_PATH" >&2; exit 1; }

# ---- source: same tag + same patches as build.sh -------------------------------
rm -rf "$SRC"
git clone -q --depth 1 --branch "$TAG" "$REPO" "$SRC"
cd "$SRC"
for p in "$SCRIPT_DIR"/patches/*.patch; do
   [ -f "$p" ] && patch -p1 --no-backup-if-mismatch < "$p"
done

# ---- Android-stub build fixes (bionic only; do not touch the glibc tree) -------
python3 - <<'PY'
def rep(path, old, new):
   s = open(path).read()
   if new in s:
      return
   assert old in s, f"pattern missing in {path}"
   open(path, 'w').write(s.replace(old, new, 1))

# The Android stub and vk_android_native_buffer.h both typedef buffer_handle_t;
# guard the definitions so they are compatible in either translation unit.
rep('include/vulkan/vk_android_native_buffer.h',
    'typedef void *buffer_handle_t;',
    '#ifndef ANDROID_BUFFER_HANDLE_T_DEFINED\n#define ANDROID_BUFFER_HANDLE_T_DEFINED\ntypedef void *buffer_handle_t;\n#endif')
rep('include/android_stub/cutils/native_handle.h',
    'typedef const native_handle_t* buffer_handle_t;',
    '#ifndef ANDROID_BUFFER_HANDLE_T_DEFINED\n#define ANDROID_BUFFER_HANDLE_T_DEFINED\ntypedef const native_handle_t* buffer_handle_t;\n#endif')

# anb->handle is a void* with the portable stub; cast it before use.
p = 'src/vulkan/runtime/vk_android.c'
s = open(p).read()
s = s.replace('assert(anb && anb->handle && anb->handle->numFds > 0);',
              'assert(anb && anb->handle && ((const native_handle_t *)anb->handle)->numFds > 0);')
s = s.replace('int dma_buf_fd = anb->handle->data[0];',
              'int dma_buf_fd = ((const native_handle_t *)anb->handle)->data[0];')
open(p, 'w').write(s)

# vk_android.c already provides HAL_MODULE_INFO_SYM on Android; the extra bridge
# would define it twice in the same shared library.
rep('src/panfrost/vulkan/meson.build',
    '  panvk_android_hal_bridge, panvk_entrypoints, panvk_tracepoints, panvk_drirc],',
    '  panvk_entrypoints, panvk_tracepoints, panvk_drirc],')
print('bionic source fixes applied')
PY

# ---- host codegen tools (x86_64 native, no WSI platforms needed) ---------------
rm -rf "$HT"
meson setup "$HT" "$SRC" \
   -Dbuildtype=release -Dvulkan-drivers=panfrost -Dgallium-drivers= \
   -Dplatforms= -Dpanfrost-kmds=kbase,panthor -Dpanvk-use-kbase=true \
   -Dmesa-clc=enabled -Dprecomp-compiler=enabled \
   -Degl=disabled -Dgles1=disabled -Dgles2=disabled -Dopengl=false \
   -Dglx=disabled -Dgbm=disabled -Dlibunwind=disabled -Dzstd=disabled
ninja -j"$(nproc)" -C "$HT" \
   src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2 \
   src/panfrost/clc/panfrost_compile
ln -sf ../src/compiler/clc/mesa_clc "$HT/bin/mesa_clc"
ln -sf ../src/compiler/spirv/vtn_bindgen2 "$HT/bin/vtn_bindgen2"
ln -sf ../src/panfrost/clc/panfrost_compile "$HT/bin/panfrost_compile"

# ---- Android sysroot bits: static libdrm + minimal pkg-config stubs ------------
export PATH="$NDKBIN:$PATH"
cat > "$WORK/android-aarch64.ini" <<'INI'
[binaries]
c = 'aarch64-linux-android35-clang'
cpp = 'aarch64-linux-android35-clang++'
ar = 'llvm-ar'
strip = 'llvm-strip'
pkg-config = 'pkg-config'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
INI
rm -rf "$DEPS"
git clone -q --depth 1 -b libdrm-2.4.125 https://gitlab.freedesktop.org/mesa/drm.git "$WORK/libdrm-src"
meson setup "$WORK/libdrm-build" "$WORK/libdrm-src" \
   --cross-file "$WORK/android-aarch64.ini" --prefix="$DEPS" --libdir=lib \
   -Dbuildtype=release -Ddefault_library=static \
   -Dintel=disabled -Dradeon=disabled -Damdgpu=disabled -Dnouveau=disabled \
   -Dvmwgfx=disabled -Domap=disabled -Dexynos=disabled -Dfreedreno=disabled \
   -Dtegra=disabled -Dvc4=disabled -Detnaviv=disabled -Dcairo-tests=disabled \
   -Dman-pages=disabled -Dvalgrind=disabled -Dtests=false -Dudev=false
ninja -C "$WORK/libdrm-build" install
mkdir -p "$DEPS/lib/pkgconfig" "$X11/lib/pkgconfig"
cat > "$DEPS/lib/pkgconfig/zlib.pc" <<'PC'
Name: zlib
Description: zlib from the NDK sysroot
Version: 1.3
Libs: -lz
Cflags:
PC
cat > "$X11/lib/pkgconfig/xcb.pc" <<'PC'
Name: xcb
Description: stub
Version: 0
Libs:
Cflags:
PC

# ---- cross-build the bionic driver ---------------------------------------------
cat > "$WORK/bionic.cross.ini" <<INI
[binaries]
c = 'aarch64-linux-android35-clang'
cpp = 'aarch64-linux-android35-clang++'
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
   -Dbuildtype=release -Dplatforms=android -Dandroid-stub=true -Dandroid-strict=false \
   -Dgallium-drivers= -Dvulkan-drivers=panfrost \
   -Dpanfrost-kmds=kbase,panthor -Dpanvk-use-kbase=true \
   -Dmesa-clc=system -Dprecomp-compiler=system \
   -Dxlib-lease=disabled -Degl=disabled -Dgles1=disabled -Dgles2=disabled \
   -Dopengl=false -Dglx=disabled -Dgbm=disabled -Dlibunwind=disabled -Dzstd=disabled \
   -Dcpp_link_args=-static-libstdc++
ninja -j"$(nproc)" -C "$BDIR" src/panfrost/vulkan/libvulkan_panfrost.so

SO="$BDIR/src/panfrost/vulkan/libvulkan_panfrost.so"
test -f "$SO"
readelf -sW "$SO" | grep -q panvk_v9_
readelf -sW "$SO" | grep -q panvk_v11_
strings -a "$SO" | grep -q PANVK_FD_INTEROP

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
   "description": "PanVK-rynx $VERSION (Android/bionic): Mali-G77 v9 JM and v10/v11 CSF on the source tree's own kbase backend. Built from $REPO with this repository's patches.",
   "author": "PanVK-rynx",
   "driverVersion": "$VERSION-bionic",
   "minApi": 29,
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
