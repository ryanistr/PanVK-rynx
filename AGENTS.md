# AGENTS.md — PanVK-rynx

Packaging repo for a Mali-G77 (MT6893, `gpu_id 0x90800011`, `/dev/mali0`) Vulkan driver on
aarch64 glibc. It contains **no Mesa source**: `build.sh` clones the read-only fork
`apexspan-svg/mesa-panvk-mali-g57`, applies `patches/*.patch`, and publishes a `.tzst`.
The Android/bionic compositor driver is a different asset in DroidDeck-Mali — do not add
Android build machinery here.

## Fix the issue — never stub, bypass, skip, or work around
- Ensure that not only does it "PASS" — ensure it actually works. Do not bypass a
  check, stub a function, skip a step, add a no-op, or add a workaround — or
  anything equivalent — just so it can return PASS on each function. The goal is
  NOT SUBBING: the underlying issue must be genuinely fixed.
- Verify every respective feature actually works and performs correctly, not just
  that a test/gate reports success. A green result from a bypassed or stubbed path
  is a failure, not a pass.
- When something does not work, find and fix the root cause. If a real fix is not
  possible, say exactly what is blocked — never manufacture a passing result.
- Do exactly what the user asked for. If the user asked for something specific,
  implement precisely that — do not try to outsmart the user, substitute a
  different solution, or "improve" the request.
- If a task seems impossible, do not fake it or force a workaround: ask the user
  for an alternative or stop here.
- Scope of bypass/workaround thinking: any instruction to find a bypass, workaround,
  alternate path, or equivalent applies ONLY when the user explicitly asks for that.
  It is never a standing license to route around a requested task. Without that
  explicit request, do not substitute a workaround for the real fix.

## Editing rules

- **Patches are byte-for-byte against tag `v1.2.0`.** Do not reformat, regenerate, or
  "clean up" existing patch files; they must keep applying as-is. Any new change is a new
  numbered patch (`0011-…`), and `docs/PATCHES.md` gets a table row.
- `build.sh` applies patches in filename order with `patch -p1`, not `git apply`.
- `docs/STATUS.md` is the current on-device truth; read it before claiming a feature works.
  Hardware validation happens in DroidDeck's guest stack, not in this repo.
- There are no tests, linters, or formatters. The verification loop is: dry-run the patches
  against the exact source tag, then the aarch64 CI build.

```sh
# patch-applicability check (the only local verification available)
git clone --depth 1 --branch v1.2.0 \
  https://github.com/apexspan-svg/mesa-panvk-mali-g57.git /tmp/opencode/panvk-check
for p in /mnt/mainline/PanVK-rynx/patches/*.patch; do
  patch -p1 --dry-run -d /tmp/opencode/panvk-check < "$p"
done
```

## Artifact ownership — absolute

- **Never present, package, publish, or ship another party's binary as a PanVK-rynx
  artifact or as our product.** In particular, faux123's closed-source
  `libvulkan_panfrost.so` (sha `499e3eae…`, or any of their `.adpkg.zip` releases) is
  **theirs**, not ours. It may be used as a local performance reference / RE target only.
  Every artifact, release tag, asset name, and benchmark claim must come from a driver
  built from this repository's own patches in our GitHub Actions workflows. Do not
  rename, re-sign, rebrand, or redistribute third-party binaries, and do not attribute
  their measurements to PanVK-rynx. If a gain exists only in a third-party binary, say so
  explicitly and leave it out of our releases.
- This overrides any "fastest path to the target" reasoning. A missed performance target
  is acceptable; a false ownership claim is not.

## Building

- **Never build this driver locally. All builds go through GitHub Actions.** Do not run
  `build.sh`, `build-bionic.sh`, `meson`, `ninja`, or any local cross-build in this repo or
  in a scratch directory. Local toolchains on this workstation are not reproducible here
  (NDK/LLVM/pkg-config differences) and are not an acceptable source of test artifacts.
  Trigger `.github/workflows/build.yml` / `.github/workflows/build-bionic.yml` with `gh`
  instead, then download the CI artifact. This overrides the scratch-build instructions
  below; they remain only as documentation of what CI does.
- **Run `build.sh` only on an aarch64 glibc host** (`ubuntu-24.04-arm`), or via the release
  workflow. It has no cross-compilation and no ELF-architecture assertion: on an x86_64
  workstation it happily produces an x86_64 `.so` packaged and named as the aarch64 driver.
  Never publish local output from a non-arm64 host.
- Run it from a scratch directory (`$PWD` or `$GITHUB_WORKSPACE` is the work dir):
  `cd /tmp/opencode/<scratch> && /mnt/mainline/PanVK-rynx/build.sh`. It creates
  `mesa-source/`, `builddir/`, `out/`, and the archive there; an existing `mesa-source/`
  makes the `git clone` fail. All of these are gitignored.
- Only `src/panfrost/vulkan/libvulkan_panfrost.so` is built (renamed to
  `libvulkan_panvk.so`). Gallium is intentionally empty; the kbase backend is compiled in,
  so never add a `libpanvk_kbase_jm.so` to the archive.
- The post-build gates in `build.sh` are load-bearing: `panvk_v9_`/`v10`/`v11` symbols must
  exist **before** stripping (they are local symbols), the `PANVK_FD_INTEROP` string must be
  present (gamescope), and no LLVM/libclc/SPIRV may appear in `DT_NEEDED`. Changing meson
  flags, patch order, or strip timing can trip them.
- Archive contents are fixed: `usr/lib/libvulkan_panvk.so`,
  `usr/share/vulkan/icd.d/panvk_icd.aarch64.json`, `meta.json`.
- `meta.json` advertises `gpuArch [9, 10, 11]`. v12–v14 CSF objects are compiled but
  deliberately unadvertised (no G720 hardware has run this tree); do not widen that list
  without device evidence.

## Versioning and releases

- Asset/tag format is `PanVK-rynx-<version>-p<n>`; **the patch level is part of the asset
  name**, and consumers identify an installed build by asset name. Bump both together.
- `PANVK_RYNX_VERSION`, `PANVK_RYNX_PATCH`, `PANVK_SOURCE_REPO`, `PANVK_SOURCE_TAG` are the
  only inputs. `release.env` is **not read** by `build.sh` or CI — it is the consumer-facing
  pin and must be updated by hand after a publish.
- Push builds only upload a CI artifact. A release is created only by `workflow_dispatch`
  with a non-empty `tag` (`gh workflow run release.yml -R ryanistr/PanVK-rynx -f version=…
  -f tag=…`), and it must stay `--latest=false`/non-prerelease — these are component
  archives, not user-installable builds.
- **Do not rebuild p7.** `PanVK-rynx-1.2.0-p7` must stay byte-identical to the asset
  previously hosted in `ryanistr/DroidDeck-Mali`
  (`sha256 85a6935490d00876925945404cf6135bad3cf1d640c3fa96d8217df252b798c3`). Migration is
  download-and-reupload; exact commands are in `docs/PUBLISH.md`.
