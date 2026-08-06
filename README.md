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

`New-AptPromotion` downloads both architectures' `.deb` with **your** GitHub
access and commits them next to the manifest edit, so the pull request shows
exactly what customers will receive. It refuses a version whose release is
missing either architecture, keeps the previous version, and stops if the
working tree is dirty or you are not on `main`. Merging the pull request is
what publishes.

That download is the only crossing from private to public, and a person makes
it. CI holds no credential for `iot-edge` and cannot reach it.

Rolling a bad version back is `Remove-AptPromotion -Version <bad> -Push`. It
edits the manifest as it stands rather than reverting the promotion commit,
which stops working as soon as a later promotion has touched the same file. The
pool is rebuilt without that version, and machines that already took it return
with `apt install skbridge=<previous>` — which is why the manifest keeps two.

## How this repository is published

`.github/workflows/publish.yml` rebuilds the whole index on each run:

1. checks the committed `pool/` holds exactly the `.deb` files `stable.list`
   names — no more, no fewer,
2. generates `Packages`/`Release` with `apt-ftparchive` and stamps a 30-day
   `Valid-Until`,
3. clear-signs `InRelease` and detach-signs `Release.gpg`,
4. installs the result inside a `debian:13-slim` container through apt itself
   before publishing,
5. deploys the tree to GitHub Pages.

Consequences worth knowing before changing anything here:

- **`pool/` is committed, `dists/` is not.** Committing the packages is what
  removes the need for any cross-repository credential in CI. The cost is that
  each promoted version leaves about 11 MB in git history permanently, even
  after it is withdrawn — only promotions add to that, not upstream releases.
- **The weekly schedule is not decorative.** The `Valid-Until` stamp lapses
  30 days after a publish, and apt then rejects the index. The schedule
  re-signs it; disabling the workflow eventually takes every appliance's
  `apt update` down. It re-signs the set `stable.list` already names, so it
  cannot promote anything on its own.
- **`APT_SIGNING_KEY` is the only secret**, holding the armored private signing
  key. `APT_SIGNING_PASSPHRASE` is optional and only needed if the key is ever
  replaced with a protected one. Nothing here can read a private repository.
