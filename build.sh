#!/usr/bin/env bash
# PanVK-rynx - the Mali-G77 Vulkan driver, built for aarch64 glibc.
#
# Rebased onto zenithblue-oss/panvk-kbase-android (v26.3.1 / build 122i, Mesa 5a07217f)
# plus this repository's patches. Publishes PanVK-rynx-<version>-<patch>.tzst.
set -euxo pipefail

VERSION=${PANVK_RYNX_VERSION:-26.3.1}
PATCH=${PANVK_RYNX_PATCH:-}
CODENAME="PanVK-rynx-$VERSION${PATCH:+-$PATCH}"
ZB_REPO=${PANVK_ZB_REPO:-https://github.com/zenithblue-oss/panvk-kbase-android.git}
ZB_COMMIT=${PANVK_ZB_COMMIT:-cf70e02b918e1864cbcd746a7fefa57b96c673ce}
MESA_REPO=${PANVK_MESA_REPO:-https://gitlab.freedesktop.org/mesa/mesa.git}
MESA_COMMIT=${PANVK_MESA_COMMIT:-5a07217f034b3e50d8c7c7794f97a2df1742613b}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK=${GITHUB_WORKSPACE:-$PWD}
ZB="$WORK/zenithblue-src"
SRC="$WORK/mesa-source"

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
    if [ -f "$p" ]; then
        patch -p1 --no-backup-if-mismatch < "$p"
    fi
done

meson setup builddir \
    -Dbuildtype=release \
    -Dvulkan-drivers=panfrost \
    -Dgallium-drivers= \
    -Dplatforms=wayland,x11 \
    -Dpanfrost-kmds=kbase \
    -Ddebug=false \
    -Dbuild-tests=false \
    -Degl=disabled -Dgles1=disabled -Dgles2=disabled -Dopengl=false \
    -Dglx=disabled -Dgbm=disabled -Dlibunwind=disabled -Dzstd=disabled \
    -Dprefix=/usr \
    -Dlibdir=lib

ninja -C builddir src/panfrost/vulkan/libvulkan_panfrost.so
test -f builddir/src/panfrost/vulkan/libvulkan_panfrost.so

mkdir -p "$WORK/out/usr/lib" "$WORK/out/usr/share/vulkan/icd.d"
cp builddir/src/panfrost/vulkan/libvulkan_panfrost.so "$WORK/out/usr/lib/libvulkan_panvk.so"

readelf -sW "$WORK/out/usr/lib/libvulkan_panvk.so" | grep -q 'panvk_v9_' \
    || { echo "built driver has no v9 backend" >&2; exit 1; }
readelf -sW "$WORK/out/usr/lib/libvulkan_panvk.so" | grep -q 'panvk_v10_' \
    || { echo "built driver has no v10 CSF backend" >&2; exit 1; }
readelf -sW "$WORK/out/usr/lib/libvulkan_panvk.so" | grep -q 'panvk_v11_' \
    || { echo "built driver has no v11 backend" >&2; exit 1; }

strip --strip-unneeded "$WORK/out/usr/lib/libvulkan_panvk.so"

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
    "description": "PanVK-rynx $VERSION - universal Mali v6-v14 PanVK (glibc) on kbase, rebased on zenithblue-oss/panvk-kbase-android ($ZB_COMMIT).",
    "driverVersion": "$VERSION${PATCH:+-$PATCH}",
    "libc": "glibc",
    "minGlibc": "2.35",
    "gpuArch": [9, 10, 11],
    "sourceLibraryName": "libvulkan_panvk.so",
    "importedAt": 0
}
META

cd "$WORK/out"
tar --use-compress-program="zstd -19" -cf "$WORK/$CODENAME.tzst" usr meta.json
sha256sum "$WORK/$CODENAME.tzst" > "$WORK/$CODENAME.tzst.sha256"
ls -la "$WORK/$CODENAME.tzst" "$WORK/$CODENAME.tzst.sha256"
