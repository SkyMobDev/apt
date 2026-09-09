# Pre-release smoke test

Run this on a throwaway Debian 13 VM before promoting a version, and again
against the live channel after the publish workflow has run.

CI already installs every package `stable.list` names inside a `debian:13-slim`
container, so a broken index, an unsatisfiable dependency or two packages
fighting over the same path fail there. What a container cannot do is run
systemd — so **nothing in CI has ever seen these services start**. That is what
this document is for.

What it still will not tell you:

- **arm64.** VirtualBox is amd64 only. The Pi carries an `LD_PRELOAD`
  workaround for a SkiaSharp linking bug that has no effect on x86-64, so an
  arm64 render fault cannot surface here. Test that on real hardware.
- **A real label.** Without a Zebra on the LAN, printing is only exercised as
  far as the connection attempt.

---

## 1. The VM

Debian 13 (trixie) netinst, amd64, 2 GB RAM, 10 GB disk. During install pick
only *SSH server* and *standard system utilities* — no desktop.

Set the network adapter to **Bridged**, not NAT: the bridge console has to be
reachable from your browser. Then take note of the address:

```bash
ip -4 addr show scope global | grep -oP '(?<=inet )[\d.]+'
```

Snapshot the VM here, named `clean`. Every section below is faster to redo
from that snapshot than to unpick by hand.

---

## 2. Install

**Before promotion** — the candidate `.deb` straight from the release:

```powershell
Import-Module .\Promote.psm1 -Force
Save-AptCandidate -Package skprinter -Version 0.1.5
```

Copy the amd64 file across (`scp candidates/skprinter-0.1.5/*_amd64.deb …`) and:

```bash
sudo apt install ./skbridge_<version>_amd64.deb ./skprinter_<version>_amd64.deb
```

Install both in **one** `apt install`, the way the appliance gets them.

**After publishing** — the channel itself, which also proves the signature and
the `Valid-Until` stamp. Use `Suites: stable beta` if you are testing a version
that is still on beta, and plain `stable` otherwise:

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

`apt update` must not warn about the signature or an expired index. If it does,
stop — that is the channel, not the package.

---

## 3. Terminal checks

```bash
systemctl is-active skbridge skprinter        # active, active
systemctl is-enabled skbridge skprinter       # enabled, enabled
skbridge --version && skprinter --version     # the versions you promoted
```

Both must be **active**, not activating and not restarting. `Restart=always`
means a service that crashes on startup looks alive for five seconds at a time:

```bash
systemctl show skprinter -p NRestarts         # NRestarts=0
```

A non-zero restart count is a crash loop, whatever `is-active` says.

```bash
curl -s localhost:19838/api/health | head -c 400
curl -s -o /dev/null -w '%{http_code}\n' localhost:9180/    # 200
```

Health always answers **200** by design — SKBridge reads any other status as
"service down". So read the body, not the code: `"status"` should be `healthy`,
and the per-printer entry under `checks` will be unhappy about `192.0.2.10`.
That is correct on a fresh install. It is the seeded documentation address,
chosen so a forgotten edit times out loudly instead of looking like it worked.

```bash
journalctl -u skbridge -u skprinter --since '10 min ago' -p warning
```

Expect nothing. In particular no fontconfig warning: the unit points
`FONTCONFIG_FILE` at the package's own `fonts.conf`, and without it every label
renders in Liberation **Mono** with accents dropped.

---

## 4. Browser checks

From your own machine, not the VM. Console is `http://<vm-ip>:9180`.

| # | Do this | Expect |
|---|---|---|
| 1 | Open `http://<vm-ip>:9180/` | Dashboard renders, styled — no unstyled HTML, no blank page. A broken `wwwroot` shows up here and nowhere else. |
| 2 | Look at the sync rows | "never" for poll/flush/heartbeat on an unenrolled appliance is correct. The unhealthy factory banner should be showing. |
| 3 | Look at the **LAN services** table | Empty on a fresh install. Services are registered, not discovered. |
| 4 | Add a service: `http://localhost:19838`, role **SKPrinter** | Row appears with a green **healthy** pill within a few seconds. A red *offline* pill means skprinter is not listening — go back to section 3. |
| 5 | Click **settings** on that row | `printer-settings.html` opens and lists the seeded printer at `192.0.2.10`, dpi 203. The link only appears for an SKPrinter on this machine, so its absence means the role or the URL is wrong. |
| 6 | Change something on that page and save, then reload | The value survives. This is the loopback-only `/api/settings` path — the bridge reaching the printer on the same box — and it is the part most likely to break. |
| 7 | Open `/collector.html` | Collector home renders. |
| 8 | Open `/settings.html` and `/console.html` | Both render. |
| 9 | Switch the console language | Labels change and none fall back to a raw key like `svc.settings`. |

Check the browser devtools console on the dashboard: no 404s for `.js` assets.
The console is bundled at build time, and a missing bundle is silent otherwise.

---

## 5. The canary path

Only for a version sitting on beta. Restore the `clean` snapshot, install from
the channel with `Suites: stable`, then opt in and confirm the site actually
moves:

```bash
apt-cache policy skbridge          # candidate = the stable version
sudo sed -i 's/^Suites: stable$/Suites: stable beta/' /etc/apt/sources.list.d/skymob.sources
sudo apt update
apt-cache policy skbridge          # candidate = the beta version, from beta/main
sudo apt upgrade
```

The version table must show both suites as sources, with the beta one winning.
If beta does not appear at all, the publish has not run since the promotion —
`Test-AptChannel` says so from your own machine.

Then confirm the way back, which is the part a site will actually need:

```bash
sudo sed -i 's/^Suites: stable beta$/Suites: stable/' /etc/apt/sources.list.d/skymob.sources
sudo apt update
sudo apt install skbridge=<stable version> --allow-downgrades
```

`--allow-downgrades` is required and is not a sign anything is wrong: apt never
steps a package backwards on its own, which is exactly why leaving the canary
group does not undo the upgrade by itself.

---

## 6. Upgrade and rollback

The path every existing site takes, and the one most worth proving. Restore the
`clean` snapshot first.

```bash
sudo apt install skbridge=<previous>            # the older version in the pool
sudo apt upgrade                                # to the promoted one
systemctl is-active skbridge && skbridge --version
```

The service must come back up on its own — postinst restarts it once after the
unpack. Then confirm a site can retreat:

```bash
sudo apt install skbridge=<previous>
skbridge --version
```

This only works while the pool still carries the older version, which is why
`stable.list` keeps two of each package.

State must survive both directions:

```bash
ls -l /var/lib/skbridge/bridge.db /var/lib/skprinter/settings.json
```

An upgrade that reseeds `settings.json` over an operator's edits is a bug —
`/var/lib` is seeded on first install only.

---

## 7. Removal

```bash
sudo apt remove skprinter && ls /var/lib/skprinter     # state kept
sudo apt purge skprinter  && ls /var/lib/skprinter     # gone
id skprinter                                           # purge also drops the user
```

Then restore the `clean` snapshot.

---

## 8. If you are testing a printer

With a Zebra reachable on the LAN, point an entry at it and print:

```bash
sudoedit /var/lib/skprinter/settings.json     # "address": "192.168.x.y:9100"
sudo systemctl restart skprinter
curl -s localhost:19838/api/health            # that printer's check now passes
```

Before blaming the service, prove the printer takes raw ZPL at all:

```bash
printf '^XA^FO50,50^A0N,40,40^FDSKPRINTER OK^FS^XZ\n' | nc 192.168.x.y 9100
```

On the label that comes out of a real template, check the **typeface**: it
should be proportional (Liberation Sans, metric-compatible with Arial). A
monospaced label means the fontconfig pin did not take.

Known and expected: a template declaring a rotated raster prints unrotated, and
an `<image>` slot whose geometry carries no `mm` suffix is dropped. Both are
shared with the Windows build — see `SKPrinter.Appliance/pkg/README.md` in
`iot-edge`.

---

## 9. After the publish workflow runs

```powershell
Test-AptChannel
```

Reports, for each suite, how long ago its index was signed, how long it stays
valid, and whether every version that suite's manifest names is actually served
on both architectures. Returns `$true` only when all of that holds for both —
a lapsed beta breaks `apt update` on the canaries even though stable is fine.
