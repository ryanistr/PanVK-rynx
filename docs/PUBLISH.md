# Create the GitHub repo and migrate p7

The repository was scaffolded locally at `/mnt/mainline/PanVK-rynx` with one commit and no
remote. These are the remaining steps; they need a GitHub account with permission to create
repos under `ryanistr`.

## 1. Create the public repo and push

From the repo root:

```sh
gh repo create ryanistr/PanVK-rynx --public --source=. --remote=origin --push
```

Or create the empty repo on github.com first, then:

```sh
git remote add origin https://github.com/ryanistr/PanVK-rynx.git
git push -u origin main
```

## 2. Move the existing p7 asset to the new repo

DroidDeck now fetches `PanVK-rynx-1.2.0-p7` from `ryanistr/PanVK-rynx`. The asset bytes are
unchanged from the release in `ryanistr/DroidDeck-Mali`, so re-upload them rather than
rebuilding:

```sh
mkdir -p /tmp/opencode/panvk-migrate
cd /tmp/opencode/panvk-migrate
gh release download PanVK-rynx-1.2.0-p7 -R ryanistr/DroidDeck-Mali \
  -p 'PanVK-rynx-*.tzst' -p '*.sha256'
sha256sum -c PanVK-rynx-1.2.0-p7.tzst.sha256
gh release create PanVK-rynx-1.2.0-p7 -R ryanistr/PanVK-rynx \
  --title PanVK-rynx-1.2.0-p7 --latest=false --prerelease=false \
  PanVK-rynx-1.2.0-p7.tzst PanVK-rynx-1.2.0-p7.tzst.sha256
```

Verify the new release before a DroidDeck build:

```sh
gh release view PanVK-rynx-1.2.0-p7 -R ryanistr/PanVK-rynx
```

## 3. Build DroidDeck

Only after steps 1 and 2:

```sh
git -C /mnt/mainline/DroidDeck diff   # review the rewired pin and docs
cd /mnt/mainline/DroidDeck && tools/build_local.sh
```

If the release is missing, `tools/build_local.sh` fails at `gh release download` rather than
fetching stale data. To roll back temporarily, set `PANVK_REPO=ryanistr/DroidDeck-Mali` in
`tools/panvk/release.env`.


## 4. Future patch releases (consumers monitor these)

Patches are published by dispatching `.github/workflows/release.yml` from this repo. For
example, p8 was published with:

```sh
gh workflow run release.yml -R ryanistr/PanVK-rynx -f version=1.2.0 -f tag=PanVK-rynx-1.2.0-p8
```

The workflow builds `build.sh` on `ubuntu-24.04-arm` and publishes `PanVK-rynx-<tag>.tzst`
plus its `.sha256` as a non-latest, non-prerelease release. After it completes, update
`release.env` here and the consumer pin in `DroidDeck/tools/panvk/release.env` to the new
tag and sha256. p7 was migrated unmodified from the old home; p8 onward are built here.

DroidDeck also runs `.github/workflows/monitor-panvk-release.yml` every 6 hours (and on
manual dispatch). It finds the newest published `PanVK-rynx-<version>-p<n>` release in this
repo, reads its `.sha256` asset, and opens a PR in DroidDeck when the tag or checksum no
longer matches `tools/panvk/release.env`. It never builds or publishes a driver itself.
