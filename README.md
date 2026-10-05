# debian-web-kiosk

Turn a fresh, minimal Debian install into a locked-down single-site web kiosk
with one command.

Built for a school library catalog station, but it works for any kiosk that
should show exactly one website and nothing else: a sign-in station, a public
catalog, a status board, an ordering terminal.

```bash
sudo bash build-catalog-kiosk.sh \
  --url "https://catalog.example.org/" \
  --allow "catalog.example.org" \
  --hostname KIOSK-01 \
  --admin_user youruser \
  --grub_password yes \
  --reboot yes
```

Five minutes later the machine boots straight into that site, full screen, with
no desktop, no address bar, and no way to reach the rest of the internet.

---

## What you get

- **Boots directly into one website.** Cage (a Wayland compositor that runs a
  single full-screen app) plus Chromium. No desktop environment is installed.
- **Everything else is blocked.** Chromium enterprise policy blocks all URLs
  except your allowlist, plus downloads, DevTools, printing, file dialogs,
  browser sign-in, and the password manager.
- **A "Back to catalog" button.** A small bundled extension floats a large
  button on every page, so a non-technical user who lands somewhere unexpected
  is never stranded. Vendor sites love putting a link in their logo.
- **Off-site links are disabled**, with a friendly notice instead of a dead end.
  Pop-ups, middle-click, Ctrl-click, and the right-click menu are all forced
  back into the single window.
- **Resets itself.** Returns to the home page after a couple of idle minutes,
  and Chromium restarts after a longer idle backstop. The browser profile lives
  in RAM and is wiped on every restart, so nothing persists between users.
- **Updates itself.** Debian packages Chromium, so security updates arrive via
  `unattended-upgrades` with no update nags and no manual work. Reboots at 3 AM
  only when an update requires it.
- **Hardened.** `kernel.sysrq=0`, USB storage blocked (including USB 3 UAS),
  suspend and Ctrl+Alt+Del masked, console switching off, and optional GRUB
  password-locking that still lets the machine boot unattended.
- **Survives power loss.** systemd restarts the browser if it dies; set your
  BIOS to power on after an outage and the kiosk comes back by itself.

Re-running the script is safe and is the normal way to change the URL or
allowlist. Replaced files are backed up under `/root/kiosk-backups/`.

---

## Requirements

- Any x86-64 machine. Cheap used thin clients and mini PCs are ideal — the
  reference build runs on a Lenovo ThinkCentre M710q with 4 GB of RAM.
- **Debian 13 (trixie)** or similar, installed with **only** "SSH server" and
  "standard system utilities". No desktop environment.
- Wired Ethernet, and SSH access from another machine.

**Do not use Ubuntu.** Its Chromium ships as a snap, which is confined and
cannot load the extension from `/opt` or write a profile to `/run`. The kiosk
will appear to work and the Back button will silently never show up.

---

## Options

| Parameter | Default | Purpose |
|---|---|---|
| `--url` | required | The page the kiosk opens |
| `--allow` | keeps existing | Comma-separated allowed domains; subdomains included automatically |
| `--hostname` | unchanged | Machine name |
| `--admin_user` | `$SUDO_USER` | Account added to the sudo group |
| `--idle_min` | 2 | Idle minutes before returning to the home page |
| `--backstop_min` | 10 | Idle minutes before Chromium restarts itself |
| `--printing` | `no` | Allow printing |
| `--grub_password` | `no` | Password-lock boot menu editing (prompts, or reads `GRUB_PASSWORD`) |
| `--reboot` | `no` | Reboot when finished |

The script follows a simple tool contract: `--key value` arguments, a JSON
result on stdout, human-readable progress on stderr and in
`/var/log/kiosk-build.log`, exit 0 on success. That makes it easy to call from
your own automation.

```json
{
  "status": "ok",
  "data": {
    "hostname": "KIOSK-01",
    "ip": "10.0.0.42",
    "mac": "6c:4b:90:00:00:00",
    "allowed_hosts": ["catalog.example.org"],
    "boot_menu_locked": true,
    "reboot_required": true,
    "manual_steps": ["..."]
  },
  "error": null
}
```

---

## Finish the job outside the script

Software can only do so much. Three things matter as much as anything above:

1. **BIOS:** set a supervisor password, disable USB and network boot and the
   boot menu key, and set the machine to power on after an outage.
2. **Firewall:** restrict the kiosk's IP to the allowed domains at the network
   level. The browser allowlist is the polite layer; this is the real one.
3. **Physical:** VESA-mount it behind the monitor with a cable lock.

---

## Picking the right start URL

Use the URL that *starts* the session, not the one your browser shows after the
site has finished redirecting. Many web apps land you on an address full of
session parameters that works when you arrive at it but fails as an entry
point — the kiosk then shows a "page blocked" screen that looks like an
allowlist problem but isn't.

Before building, open the site in a normal browser, press F12, and watch the
**Network** tab while you load the page, sign in, and use the main feature.
Every hostname in the Domain column belongs in `--allow`. Sites commonly pull
in a CDN, fonts, or a separate login domain, and a missing one gives you a
half-broken page rather than an obvious error.

<details>
<summary>Worked example: Follett Destiny library catalog</summary>

```bash
sudo bash build-catalog-kiosk.sh \
  --url "https://bscl.follettdestiny.com/portal/portal?appId=destiny-XXXX-XXXX" \
  --allow "bscl.follettdestiny.com,portal.follettdestiny.com,follettsoftware.com" \
  --hostname LIBRARY-01 --admin_user youruser
```

Replace `destiny-XXXX-XXXX` with your district's own app ID.

Two things that cost real time here: the post-redirect
`portal.follettdestiny.com/portal?...&siteGuid=...` address does **not** work as
a start URL, and `follettsoftware.com` is required even though it never appears
while browsing the catalog.
</details>

---

## Troubleshooting

**"Page blocked" on screen.** Usually the wrong start URL rather than a missing
domain. Check it:

```bash
grep ExecStart /etc/systemd/system/kiosk.service
```

**Black screen or restart loop:**

```bash
journalctl -u kiosk -b --no-pager | tail -40
sudo systemctl disable --now kiosk     # stops it while you work
```

**Back button missing:**

```bash
journalctl -u kiosk -b --no-pager | grep -iE 'extension|policy' | tail -20
```

**Need a real browser to diagnose.** This gives you an address bar and DevTools
on the kiosk screen. **Lockdown is off while this is in place:**

```bash
sudo python3 -c "
import json; p='/etc/chromium/policies/managed/kiosk.json'
d=json.load(open(p)); d['URLBlocklist']=[]; d['DeveloperToolsAvailability']=1
json.dump(d,open(p,'w'),indent=2)"
sudo mkdir -p /etc/systemd/system/kiosk.service.d
sudo tee /etc/systemd/system/kiosk.service.d/debug.conf > /dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/cage -- /usr/bin/chromium --ozone-platform=wayland --no-first-run --user-data-dir=/run/kiosk/profile "https://catalog.example.org/"
EOF
sudo systemctl daemon-reload && sudo systemctl restart kiosk
```

Undo it by removing the override and re-running the build script, which also
restores the blocklist and disables DevTools:

```bash
sudo rm -rf /etc/systemd/system/kiosk.service.d
sudo systemctl daemon-reload
sudo bash build-catalog-kiosk.sh --url "https://catalog.example.org/" --admin_user youruser
```

---

## What it changes on the system

| Path | Purpose |
|---|---|
| `/etc/systemd/system/kiosk.service` | Autostarts Cage + Chromium on tty1 as the `kiosk` user |
| `/etc/chromium/policies/managed/kiosk.json` | Enterprise policy: allowlist and lockdown |
| `/opt/kiosk-ext/` | Back button, link guard, idle reset |
| `/etc/pam.d/cage` | Login session for the kiosk user |
| `/etc/sysctl.d/99-kiosk.conf` | Disables SysRq |
| `/etc/modprobe.d/kiosk-no-usb-storage.conf` | Blocks USB storage |
| `/etc/systemd/logind.conf.d/kiosk.conf` | Ignores power and lid keys |
| `/etc/apt/apt.conf.d/*` | Automatic security updates |
| `/etc/grub.d/01_kiosk_password` | Boot menu lock (with `--grub_password yes`) |
| `/root/kiosk-backups/` | Timestamped backups of replaced files |

Packages installed: `cage`, `chromium`, `unattended-upgrades`, `sudo`,
`python3`, `openssh-server`, and `intel-microcode` on Intel CPUs.

---

## Known limitations

- **Ctrl+N and Ctrl+T** are built into Chromium and can't be disabled by policy.
  A stray blank window closes with Ctrl+W, and the idle backstop clears it
  otherwise. Where users only need to click, unplug the keyboard.
- **Not an atomic-update appliance.** There's no A/B rollback or Secure Boot
  image signing here. For a fleet of hundreds, look at RAUC, SWUpdate, or
  Ubuntu Core instead.
- **Tested on Debian 13 (trixie)** on amd64. Other Debian versions will likely
  work; other distributions have not been tried.

## Alternatives worth knowing

- **[Porteus Kiosk](https://porteus-kiosk.org/)** — a polished, read-only kiosk
  distribution with central config management. Commercial licensing per machine.
- **[Ubuntu Frame](https://ubuntu.com/frame)** — Canonical's display server for
  embedded kiosks and signage, with snap-based updates.
- **ChromeOS Flex** — easiest to manage if you already pay for Chrome Enterprise
  or Education licensing, which kiosk mode requires.

This project exists for the case where you want no license, no vendor, and a
single readable shell script you can audit in ten minutes.

## License

MIT — see [LICENSE](LICENSE).
