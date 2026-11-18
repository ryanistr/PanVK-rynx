#!/system/bin/sh
# Device-side harness: run one or all vktest checks against a given PanVK driver dir.
# Usage: vkvalidate-harness.sh <label> <driver-dir-name> <extra-env-or-> [check ids...]
LABEL=$1
DRIVERNAME=$2
ENVSTR=$3
shift 3
NATIVEDIR=$(ls -d /data/app/*/com.faux.vktest-*/lib/arm64 2>/dev/null | head -1)
DRIVERDIR=/data/data/com.faux.vktest/files/drivers/$DRIVERNAME
OUT=/data/local/tmp/vk_$LABEL
mkdir -p "$OUT"
if [ -n "$ENVSTR" ] && [ "$ENVSTR" != "-" ]; then
  export "${ENVSTR%%=*}=${ENVSTR#*=}"
fi
if [ $# -eq 0 ]; then
  set -- $($NATIVEDIR/libvkvalidate.so --list | awk '{print $1}')
fi
for id in "$@"; do
  $NATIVEDIR/libvkvalidate.so --check "$id" \
    --driver-dir "$DRIVERDIR/" --driver-lib libvulkan_panvk.so \
    --hook-dir "$NATIVEDIR/" --out "$OUT/$id.json" > "$OUT/$id.log" 2>&1
  rc=$?
  v=$(sed -n 's/.*"verdict"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$OUT/$id.json" | head -1)
  [ -z "$v" ] && v="CRASH(rc=$rc)"
  echo "$id $v rc=$rc"
done
