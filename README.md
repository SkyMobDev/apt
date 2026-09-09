# SkyMob apt repository

Signed Debian package channel for the SkyMob edge appliances, served at
**<https://apt.skymob.app>**.

Carries, for `amd64` (virtual machines) and `arm64` (the physical appliance):

| Package | | Built from |
|---|---|---|
| `skbridge` | the LAN↔cloud bridge appliance | `skbridge-v*` |
| `skprinter` | the label printer service, alongside the bridge on the same appliance | `skprinter-appliance-v*` |

The upstream tag is named for the project, not for the package it produces —
and `skprinter-v*` is a different product, the Windows SKPrinter, whose releases
carry no `.deb`. `Promote.psm1` holds the mapping and refuses a package it does
not know rather than guessing.

## Installing

Debian 13 (trixie). Earlier releases are not supported: `skbridge` needs glibc
2.34 and trixie's `libssl3t64`, and `skprinter` needs glibc 2.38 — which
bookworm's 2.36 does not satisfy either. The floors are read from the published
binaries at package time, so they move on their own; `apt show <package>` has
the current ones.

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
sudo apt install skbridge skprinter
```

Install only what the appliance needs — `skprinter` is for a site that prints
labels; the two are independent and coexist. The architecture is left out on
purpose: apt fetches the index matching the machine's own dpkg architecture.
Every later upgrade is `sudo apt upgrade`.

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

### Where the private key lives, and how to get it back

Three copies, and no fourth:

| Copy | Purpose |
|---|---|
| `APT_SIGNING_KEY` secret on this repository | what CI signs with — write-only, GitHub never reads it back |
| `apt-signing-key` in Azure Key Vault `SkyMobSecrets` | the recoverable copy |
| `apt-signing-key-revocation` in the same vault | the revocation certificate, the only way to publicly retire the key if it leaks |

Restoring it — after a lost Actions secret, or to sign something by hand:

```bash
az keyvault secret download --vault-name SkyMobSecrets --name apt-signing-key \
  --file key.asc --encoding utf-8

# Windows writes CRLF here; the secret should hold the armor exactly as gpg
# emitted it, so strip them on the way in.
tr -d '\r' < key.asc | gh secret set APT_SIGNING_KEY --repo SkyMobDev/apt

gpg --batch --import key.asc      # only if you need to sign locally
rm -f key.asc
```

Confirm you got the right key before trusting it — the fingerprint above must
match `gpg --show-keys key.asc`.

Losing all three copies is recoverable but expensive: a new key means every
appliance needs its `/etc/apt/keyrings/skymob.asc` replaced by hand before
`apt update` works again.

## Promoting a release

Cutting a release upstream publishes nothing here. What reaches customers is
exactly what [`stable.list`](stable.list) names, so promotion is a deliberate,
reviewed edit. [`Promote.psm1`](Promote.psm1) drives it — it needs PowerShell 7
and a `gh` authenticated with read access to `iot-edge`:

```powershell
Import-Module .\Promote.psm1 -Force

Get-AptChannel                                          # every package: published vs. upstream
Save-AptCandidate -Package skbridge -Version 0.1.41     # pull the .deb for a test VM
New-AptPromotion  -Package skbridge -Version 0.1.41 -Push   # branch + commit + pull request
Test-AptChannel                                         # after the merge: what the channel serves
```

`-Package` is required rather than defaulted: with more than one package on the
channel, a forgotten flag would promote the wrong thing silently.
[`SMOKE-TEST.md`](SMOKE-TEST.md) is the manual check to run on a VM between
`Save-AptCandidate` and `New-AptPromotion` — CI can install these packages but
never starts them, so nothing automated has seen the services run.

`New-AptPromotion` downloads both architectures' `.deb` with **your** GitHub
access and commits them next to the manifest edit, so the pull request shows
exactly what customers will receive. It refuses a version whose release is
missing either architecture, keeps the previous version, and stops if the
working tree is dirty or you are not on `main`. Merging the pull request is
what publishes.

That download is the only crossing from private to public, and a person makes
it. CI holds no credential for `iot-edge` and cannot reach it.

Rolling a bad version back is `Remove-AptPromotion -Package <pkg> -Version <bad>
-Push`. It edits the manifest as it stands rather than reverting the promotion
commit, which stops working as soon as a later promotion has touched the same
file. The pool is rebuilt without that version, and machines that took it return
with `apt install <pkg>=<previous>` — which is why the manifest keeps two.

## How this repository is published

`.github/workflows/publish.yml` rebuilds the whole index on each run:

1. checks the committed `pool/` holds exactly the `.deb` files `stable.list`
   names — no more, no fewer,
2. generates `Packages`/`Release` with `apt-ftparchive` and stamps a 90-day
   `Valid-Until`,
3. clear-signs `InRelease` and detach-signs `Release.gpg`,
4. installs every package `stable.list` names inside a `debian:13-slim`
   container, through apt itself and in a single call, before publishing,
5. deploys the tree to GitHub Pages.

Consequences worth knowing before changing anything here:

- **`pool/` is committed, `dists/` is not.** Committing the packages is what
  removes the need for any cross-repository credential in CI. The cost is that
  each promoted version leaves its packages in git history permanently, even
  after it is withdrawn — about 11 MB per `skbridge` version and 21 MB per
  `skprinter` one, across both architectures. Only promotions add to that, not
  upstream releases.
- **The weekly schedule is not decorative.** The `Valid-Until` stamp lapses
  90 days after a publish, and apt then rejects the index outright — it will
  not fall back to cached lists. The schedule re-signs it and cannot promote
  anything, since it publishes the set `stable.list` already names.

  The window is far longer than the cadence on purpose. GitHub neither retries
  nor backfills a dropped scheduled run, and it **disables schedules after 60
  days of repository inactivity** — so the realistic failure is not a run
  failing loudly but the schedule quietly ceasing to exist. Any push resets
  that clock, so promoting every couple of months keeps it alive by itself.
  `Test-AptChannel` reports how long ago the index was signed, which goes bad
  within days of a missed cycle rather than months later.
- **`APT_SIGNING_KEY` is the only secret**, holding the armored private signing
  key. `APT_SIGNING_PASSPHRASE` is optional and only needed if the key is ever
  replaced with a protected one. Nothing here can read a private repository.
