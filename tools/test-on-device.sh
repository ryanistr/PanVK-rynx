#!/usr/bin/env bash
# Host-side CI test: install a built bionic PanVK-rynx artifact on the X6739 device,
# run identity + all vktest checks, compute verdict counts and perf timings, and print
# a machine-readable summary. Requires adb root and the self-hosted runner labels.
set -euo pipefail

ARTIFACT_DIR=${1:?artifact dir}
OUT_DIR=${2:-test-results}
DEVICE=${ADB_SERIAL:-102562537K104189}
DRIVER=panvk-ci

mkdir -p "$OUT_DIR" "$OUT_DIR/extract"
TZST=$(find "$ARTIFACT_DIR" -name 'PanVK-rynx-*-bionic.tzst' | head -1)
test -n "$TZST" || { echo "no bionic tzst in $ARTIFACT_DIR" >&2; exit 1; }
tar --zstd -xf "$TZST" -C "$OUT_DIR/extract" usr/lib/libvulkan_panvk.so meta.json

adb devices | grep -q "$DEVICE" || { echo "device $DEVICE not connected" >&2; exit 1; }
NAT=$(adb -s "$DEVICE" shell 'ls -d /data/app/*/com.faux.vktest-*/lib/arm64 2>/dev/null | head -1' | tr -d '\r')
test -n "$NAT" || { echo "com.faux.vktest not installed" >&2; exit 1; }

adb -s "$DEVICE" push "$OUT_DIR/extract/usr/lib/libvulkan_panvk.so" /data/local/tmp/panvk-ci.so >/dev/null
adb -s "$DEVICE" push "$OUT_DIR/extract/meta.json" /data/local/tmp/panvk-ci-meta.json >/dev/null
adb -s "$DEVICE" shell "su -c 'APP=/data/data/com.faux.vktest; mkdir -p \$APP/files/drivers/$DRIVER; cp /data/local/tmp/panvk-ci.so \$APP/files/drivers/$DRIVER/libvulkan_panvk.so; cp /data/local/tmp/panvk-ci-meta.json \$APP/files/drivers/$DRIVER/meta.json; UID=\$(stat -c %u \$APP); chown -R \$UID:\$UID \$APP/files/drivers; chmod -R 755 \$APP/files/drivers'"

adb -s "$DEVICE" push tools/vkvalidate-harness.sh /data/local/tmp/vkvalidate-harness.sh >/dev/null
adb -s "$DEVICE" shell 'chmod 755 /data/local/tmp/vkvalidate-harness.sh'

echo "=== identity ==="
adb -s "$DEVICE" shell "su -c '$NAT/libvkvalidate.so --identity --driver-dir /data/data/com.faux.vktest/files/drivers/$DRIVER/ --driver-lib libvulkan_panvk.so --hook-dir $NAT/ --out /data/local/tmp/vk-identity.json'" >/dev/null
adb -s "$DEVICE" shell 'su -c "cat /data/local/tmp/vk-identity.json"' > "$OUT_DIR/identity.json"
python3 -c 'import json; j=json.load(open("'"$OUT_DIR"'/identity.json")); print("loaded_via=%s device=%s driver=%s info=%s" % (j["loaded_via"], j["driver"]["device_name"], j["driver"]["name"], j["driver"]["info"]))'

echo "=== full check suite (100 IDs) ==="
adb -s "$DEVICE" shell "su -c '/data/local/tmp/vkvalidate-harness.sh ci $DRIVER -'" > "$OUT_DIR/verdicts.txt"
adb -s "$DEVICE" shell "su -c 'chmod -R 644 /data/local/tmp/vk_ci; chmod 755 /data/local/tmp/vk_ci'"
adb -s "$DEVICE" pull /data/local/tmp/vk_ci "$OUT_DIR/raw" >/dev/null

python3 - "$OUT_DIR" <<'PY'
import json, glob, os, sys
from collections import Counter
out = sys.argv[1]
raw = os.path.join(out, 'raw', 'vk_ci')
res = {}
for p in glob.glob(raw + '/*.json'):
    j = json.load(open(p))
    res[j['check']] = j
logs = {os.path.basename(p)[:-4] for p in glob.glob(raw + '/*.log')}
crashes = sorted(logs - set(res))
counts = Counter(j.get('verdict') for j in res.values())
summary = {
    'verdicts': dict(counts),
    'crashes': crashes,
    'total_verdicts': len(res),
}
def timing(name):
    j = res.get(name)
    if not j: return None
    for e in j.get('evidence', []):
        g = e.get('got')
        if isinstance(g, (int, float)) and 'ms' in e.get('what', ''):
            return g
    return None
summary['perf_ms'] = {
    'perf.occlusion_query_in_pass_cost': timing('perf.occlusion_query_in_pass_cost'),
    'perf.fb_local_barrier_overdraw': timing('perf.fb_local_barrier_overdraw'),
    'perf.fb_local_barrier_large_draws': timing('perf.fb_local_barrier_large_draws'),
}
json.dump(summary, open(os.path.join(out, 'summary.json'), 'w'), indent=2)
print(json.dumps(summary, indent=2))
PY

# Restore the device to the stock driver selection.
adb -s "$DEVICE" shell 'su -c "echo system > /data/data/com.faux.vktest/files/drivers/driver.txt"' >/dev/null
echo TEST_DONE
