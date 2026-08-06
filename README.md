# SkyMob apt repository

Signed Debian package channel for the SkyMob edge appliances, served at
**<https://apt.skymob.app>**.

Currently carries `skbridge` (the LAN↔cloud bridge appliance) for `amd64`
(virtual machines) and `arm64` (the physical appliance).

## Installing

Debian 13 (trixie). Earlier releases are not supported — the packages need
glibc 2.34 or newer and trixie's `libssl3t64`.

```bash
sudo apt install -y curl
sudo install -d /etc/apt/keyrings
sudo curl -fsSL https://apt.skymob.app/skymob.asc -o /etc/apt/keyrings/skymob.asc
sudo tee /etc/apt/sources.list.d/skymob.sources >/dev/null <<'EOF'
Types: deb
URIs: https://apt.skymob.app
Suites: stable
Components: main
Signed-By: /etc/apt/keyrings/skymob.asc
EOF
sudo apt update
sudo apt install skbridge
```

The architecture is left out on purpose: apt fetches the index matching the
machine's own dpkg architecture. Every later upgrade is `sudo apt upgrade`.

## Signing key

```
CB08 8823 E147 2096 157A  7917 ABEF 2B35 90BE B0ED
```

Verify what you downloaded before trusting it:

```bash
gpg --show-keys /etc/apt/keyrings/skymob.asc
```

The key does not expire. If it ever has to be replaced, the new one is
published here alongside a transition announcement — a rotation that broke
`apt update` on every appliance at once would be worse than the risk it
guards against.

## Promoting a release

Cutting a `skbridge-v*` release upstream publishes nothing here. What reaches
customers is exactly what [`stable.list`](stable.list) names, so promotion is a
deliberate, reviewed edit. [`Promote.psm1`](Promote.psm1) drives it — it needs
PowerShell 7 and a `gh` authenticated with read access to `iot-edge`:

```powershell
Import-Module .\Promote.psm1 -Force

Get-AptChannel                            # published vs. available upstream
Save-AptCandidate -Version 0.1.27         # pull the .deb, install it on a test VM
New-AptPromotion  -Version 0.1.27 -Push   # branch + commit + pull request
Test-AptChannel                           # after the merge: what the channel serves
```

`New-AptPromotion` refuses a version whose release is missing either
architecture's `.deb`, keeps the previous version in the manifest, and stops if
the working tree is dirty or you are not on `main`. Merging the pull request is
what publishes.

Rolling a bad version back is `git revert` on that commit: the pool is rebuilt
from the manifest, so the package disappears from the channel and machines that
already took it can return with `apt install skbridge=<previous>`.

## How this repository is published

`.github/workflows/publish.yml` rebuilds the whole index on each run:

1. downloads the `.deb` assets named by `stable.list` from the (private)
   `SkyMobDev/iot-edge` repository,
2. generates `Packages`/`Release` with `apt-ftparchive` and stamps a 30-day
   `Valid-Until`,
3. clear-signs `InRelease` and detach-signs `Release.gpg`,
4. installs the result inside a `debian:13-slim` container through apt itself
   before publishing,
5. deploys the tree to GitHub Pages.

Consequences worth knowing before changing anything here:

- **No package is ever committed.** `dists/` and `pool/` are build output, so
  git history stays small and the published repository is reproducible from
  the upstream releases alone.
- **The weekly schedule is not decorative.** The `Valid-Until` stamp lapses
  30 days after a publish, and apt then rejects the index. The schedule
  re-signs it; disabling the workflow eventually takes every appliance's
  `apt update` down. It re-signs the set `stable.list` already names, so it
  cannot promote anything on its own.
- **`RELEASES_TOKEN`** is a fine-grained PAT with `Contents: Read` on
  `SkyMobDev/iot-edge` — the only reason this public repository can see the
  private one.
- **`APT_SIGNING_KEY`** holds the armored private key; `APT_SIGNING_PASSPHRASE`
  is optional and only needed if the key is ever replaced with a protected one.
