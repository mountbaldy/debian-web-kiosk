#!/usr/bin/env bash
# build-catalog-kiosk.sh - fresh Debian install -> locked-down library catalog kiosk
#
# Follows the tool-registry contract: --key value parameters, JSON result on stdout,
# progress on stderr (also appended to /var/log/kiosk-build.log), exit 0 = success.
#
# Start from a Debian 13 install with ONLY "SSH server" + "standard system utilities".
# Run as root (sudo, or `su -` first if sudo isn't installed yet):
#
#   bash build-catalog-kiosk.sh --url https://catalog.example.org/ \
#        --allow "catalog.example.org,cdn.vendor.com" --hostname KIOSK-03 \
#        --grub_password yes --reboot yes
#
# Parameters
#   --url            (required) catalog home page
#   --allow          comma-separated allowed domains (the --url domain is always added).
#                    Omit on a re-run to keep the existing allowlist.
#   --hostname       machine name, e.g. KIOSK-03
#   --admin_user     existing account to add to the sudo group (default: $SUDO_USER)
#   --idle_min       idle minutes before the page returns home           (default 2)
#   --backstop_min   idle minutes before Chromium restarts itself        (default 10)
#   --printing       yes|no  allow printing from the catalog             (default no)
#   --grub_password  yes|no  password-lock boot menu editing; prompts,
#                            or reads the GRUB_PASSWORD env var           (default no)
#   --reboot         yes|no  reboot when finished                         (default no)
#
# Safe to re-run. Replaced files are backed up to /root/kiosk-backups/<timestamp>/.

set -Eeuo pipefail

R="${KIOSK_TEST_ROOT:-}"   # test harness only - leave unset on real machines

URL="" ALLOW="" NEW_HOSTNAME="" ADMIN_USER="${SUDO_USER:-}"
IDLE_MIN=2 BACKSTOP_MIN=10 PRINTING=no GRUB_PW=no REBOOT=no
EXT_DIR="$R/opt/kiosk-ext"
POLICY="$R/etc/chromium/policies/managed/kiosk.json"
SERVICE="$R/etc/systemd/system/kiosk.service"
LOGFILE="$R/var/log/kiosk-build.log"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$R/root/kiosk-backups/$STAMP"
STEP="startup"

json_escape() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/ }; printf '%s' "$s"; }
fail() {
  [[ $BASHPID == "$$" ]] || exit 1   # inside $(...): let the main shell report once
  printf '{"status":"error","data":{"step":"%s"},"error":"%s"}\n' \
    "$(json_escape "$STEP")" "$(json_escape "$1")"
  echo "[kiosk] ERROR during '$STEP': $1" >&2
  exit 1
}
trap 'fail "a command failed - details in /var/log/kiosk-build.log"' ERR
log() { printf '[kiosk] %s\n' "$*" >&2; }
backup() {
  if [[ -e "$1" ]]; then
    mkdir -p "$BACKUP_DIR"
    cp -a "$1" "$BACKUP_DIR/$(printf '%s' "${1#"$R"}" | tr '/' '_')"
  fi
}
has_candidate() {
  # No pipe to grep -q here: under 'set -o pipefail', grep -q exits on the first
  # match and apt-cache dies of SIGPIPE, making the whole pipeline return 141.
  local out
  out=$(apt-cache policy "$1" 2>/dev/null) || return 1
  [[ $out == *Candidate:\ [0-9]* ]]
}

# ------------------------------------------------------------------ parameters
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || fail "missing value for $1"
  case "$1" in
    --url)           URL=$2 ;;
    --allow)         ALLOW=$2 ;;
    --hostname)      NEW_HOSTNAME=$2 ;;
    --admin_user)    ADMIN_USER=$2 ;;
    --idle_min)      IDLE_MIN=$2 ;;
    --backstop_min)  BACKSTOP_MIN=$2 ;;
    --printing)      PRINTING=$2 ;;
    --grub_password) GRUB_PW=$2 ;;
    --reboot)        REBOOT=$2 ;;
    *) fail "unknown parameter: $1" ;;
  esac
  shift 2
done

STEP="validate"
[[ -n "$R" || $EUID -eq 0 ]] || fail "run as root (sudo bash ..., or su - first)"
[[ -r "$R/etc/debian_version" ]] || fail "this script expects Debian"
[[ "$URL" =~ ^https?://[^/]+ ]] || fail "--url is required and must start with http:// or https://"
[[ "$IDLE_MIN" =~ ^[1-9][0-9]*$ ]] || fail "--idle_min must be a whole number of minutes (1 or more)"
[[ "$BACKSTOP_MIN" =~ ^[1-9][0-9]*$ ]] || fail "--backstop_min must be a whole number of minutes (1 or more)"
for pair in "printing:$PRINTING" "grub_password:$GRUB_PW" "reboot:$REBOOT"; do
  [[ "${pair#*:}" == yes || "${pair#*:}" == no ]] || fail "--${pair%%:*} must be yes or no"
done
if [[ -n "$NEW_HOSTNAME" && ! "$NEW_HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]]; then
  fail "--hostname may only contain letters, numbers, and dashes"
fi

mkdir -p "$(dirname "$LOGFILE")"
exec 2> >(tee -a "$LOGFILE" >&2)
log "==== build started $STAMP ===="

# Ask for the boot menu password up front so nobody babysits the apt step waiting for a prompt.
if [[ "$GRUB_PW" == yes && -z "${GRUB_PASSWORD:-}" ]]; then
  STEP="boot menu password prompt"
  read -rsp "Boot menu password (needed to edit boot entries): " p1 </dev/tty; echo >&2
  read -rsp "Repeat boot menu password: " p2 </dev/tty; echo >&2
  [[ -n "$p1" && "$p1" == "$p2" ]] || fail "boot menu passwords were empty or didn't match"
  GRUB_PASSWORD=$p1
  unset p1 p2
fi

# ------------------------------------------------------------------ packages
STEP="apt sources"
if [[ -f "$R/etc/apt/sources.list" ]] && grep -qE '^[[:space:]]*deb[[:space:]]+cdrom:' "$R/etc/apt/sources.list"; then
  backup "$R/etc/apt/sources.list"
  sed -i -E 's/^([[:space:]]*deb[[:space:]]+cdrom:)/# \1/' "$R/etc/apt/sources.list"
  log "Disabled the install DVD/USB as a package source"
fi

STEP="apt update"
log "Updating package lists..."
DEBIAN_FRONTEND=noninteractive apt-get update >&2

STEP="check mirror"
has_candidate chromium || fail "chromium isn't available - add a Debian network mirror to /etc/apt/sources.list"

STEP="install packages"
PKGS=(cage chromium unattended-upgrades sudo python3 openssh-server)
if grep -q GenuineIntel /proc/cpuinfo && has_candidate intel-microcode; then PKGS+=(intel-microcode); fi
log "Installing: ${PKGS[*]}"
DEBIAN_FRONTEND=noninteractive apt-get install -y "${PKGS[@]}" >&2

STEP="automatic updates"
cat > "$R/etc/apt/apt.conf.d/20auto-upgrades" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
cat > "$R/etc/apt/apt.conf.d/52kiosk-unattended-upgrades" <<'EOF'
// Written by build-catalog-kiosk.sh - reboots at 3 AM only when an update requires it
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
EOF

# ------------------------------------------------------------------ accounts + name
STEP="admin user"
if [[ -n "$ADMIN_USER" && "$ADMIN_USER" != root ]]; then
  id "$ADMIN_USER" >/dev/null 2>&1 || fail "--admin_user '$ADMIN_USER' does not exist"
  usermod -aG sudo "$ADMIN_USER"
  log "Added $ADMIN_USER to the sudo group"
fi

STEP="hostname"
if [[ -n "$NEW_HOSTNAME" ]]; then
  backup "$R/etc/hosts"
  hostnamectl set-hostname "$NEW_HOSTNAME"
  if grep -q '^127\.0\.1\.1' "$R/etc/hosts"; then
    sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t$NEW_HOSTNAME/" "$R/etc/hosts"
  else
    printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" >> "$R/etc/hosts"
  fi
  log "Hostname set to $NEW_HOSTNAME"
fi

STEP="kiosk user"
id kiosk >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin kiosk

STEP="login session"
cat > "$R/etc/pam.d/cage" <<'EOF'
auth     required pam_unix.so nullok
account  required pam_unix.so
session  required pam_unix.so
session  required pam_systemd.so
EOF

# ------------------------------------------------------------------ extension files
STEP="kiosk extension"
mkdir -p "$EXT_DIR"
cat > "$EXT_DIR/manifest.json" <<'EOF'
{
  "manifest_version": 3,
  "name": "Library Kiosk Helper",
  "version": "1.1",
  "description": "Back-to-catalog button, off-site link guard, and idle reset for library kiosks.",
  "content_scripts": [
    {
      "matches": ["http://*/*", "https://*/*"],
      "js": ["no-popups.js"],
      "run_at": "document_start",
      "world": "MAIN"
    },
    {
      "matches": ["http://*/*", "https://*/*"],
      "js": ["kiosk.js"],
      "run_at": "document_idle"
    }
  ]
}
EOF

cat > "$EXT_DIR/no-popups.js" <<'EOF'
// Runs in the page's own JavaScript world: window.open() stays in the single kiosk window.
window.open = function (url) {
  try {
    if (url) location.assign(new URL(url, location.href).href);
  } catch (e) { /* ignore malformed URLs */ }
  return null;
};
EOF

cat > "$EXT_DIR/kiosk.js" <<'EOF'
// Library Kiosk Helper - generated by build-catalog-kiosk.sh (re-run the script to change settings)
(() => {
  if (window.top !== window) return;

  const HOME = __HOME__;
  const ALLOWED = __ALLOWED__;
  const IDLE_MINUTES = __IDLE_MIN__;
  // CSS selectors for links to disable even on allowed domains, e.g. ["header a.logo"]
  const BLOCK_SELECTORS = [];

  const trimSlash = (u) => u.replace(/\/+$/, "");
  const hostAllowed = (host) =>
    ALLOWED.some((d) => host === d || host.endsWith("." + d));

  // ---- Back-to-catalog button + notice (closed shadow DOM so site CSS can't break it)
  const box = document.createElement("div");
  box.style.cssText =
    "all:initial;position:fixed;right:24px;bottom:24px;z-index:2147483647;";
  const shadow = box.attachShadow({ mode: "closed" });
  shadow.innerHTML = `
    <style>
      button {
        font: 700 22px/1 system-ui, "DejaVu Sans", sans-serif;
        padding: 18px 28px; min-height: 60px;
        color: #ffffff; background: #1f5e3b;
        border: 3px solid #ffffff; border-radius: 14px;
        box-shadow: 0 6px 18px rgba(0, 0, 0, .4);
        cursor: pointer;
      }
      button:active { background: #16452c; transform: translateY(2px); }
      button:focus-visible { outline: 4px solid #ffd24a; outline-offset: 3px; }
      .notice {
        position: fixed; left: 50%; bottom: 110px; transform: translateX(-50%);
        font: 600 20px/1.3 system-ui, "DejaVu Sans", sans-serif;
        color: #ffffff; background: #16452c; padding: 14px 22px; border-radius: 10px;
        box-shadow: 0 6px 18px rgba(0, 0, 0, .4);
        opacity: 0; transition: opacity .2s; pointer-events: none; white-space: nowrap;
      }
      .notice.show { opacity: 1; }
      @media (prefers-reduced-motion: reduce) { .notice { transition: none; } }
    </style>
    <div class="notice" role="status">That link is turned off on this computer.</div>
    <button type="button">Back to catalog</button>`;
  const notice = shadow.querySelector(".notice");
  shadow.querySelector("button").addEventListener("click", () => location.assign(HOME));
  document.documentElement.appendChild(box);

  let noticeTimer;
  const showNotice = () => {
    notice.classList.add("show");
    clearTimeout(noticeTimer);
    noticeTimer = setTimeout(() => notice.classList.remove("show"), 2500);
  };

  // ---- Link guard: stop off-site links and new windows before they happen
  const findLink = (e) => {
    for (const el of e.composedPath()) {
      if (el.nodeType === 1 && (el.localName === "a" || el.localName === "area")) return el;
    }
    return null;
  };

  const blockedBySelector = (el) =>
    BLOCK_SELECTORS.some((s) => { try { return el.matches(s); } catch { return false; } });

  const guard = (e) => {
    if (e.type === "auxclick" && e.button !== 1) return;   // only middle-click
    const link = findLink(e);
    if (!link) return;
    const raw = link.getAttribute("href") ?? link.getAttribute("xlink:href");
    if (raw === null) return;

    let url;
    try { url = new URL(raw, location.href); } catch { return; }

    const isWeb = url.protocol === "http:" || url.protocol === "https:";
    const offSite = isWeb ? !hostAllowed(url.hostname) : url.protocol !== "javascript:";

    if (offSite || blockedBySelector(link)) {
      e.preventDefault();
      e.stopImmediatePropagation();
      showNotice();
      return;
    }

    const wantsNewWindow =
      e.type === "auxclick" || e.shiftKey || e.ctrlKey || e.metaKey ||
      (link.target && link.target !== "_self" && link.target !== "_top");
    if (isWeb && wantsNewWindow) {
      e.preventDefault();
      e.stopImmediatePropagation();
      location.assign(url.href);
    }
  };
  document.addEventListener("click", guard, true);
  document.addEventListener("auxclick", guard, true);
  document.addEventListener("contextmenu", (e) => e.preventDefault(), true);

  // ---- Idle reset: back to the catalog home page after IDLE_MINUTES with no input
  let idleTimer;
  const resetIdle = () => {
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => {
      if (trimSlash(location.href) !== trimSlash(HOME)) location.assign(HOME);
    }, IDLE_MINUTES * 60 * 1000);
  };
  ["pointerdown", "pointermove", "keydown", "wheel", "touchstart", "scroll"].forEach((t) =>
    window.addEventListener(t, resetIdle, { capture: true, passive: true }));
  resetIdle();
})();
EOF

# ------------------------------------------------------------------ Chromium policy + fill extension
STEP="chromium policy"
mkdir -p "$(dirname "$POLICY")"
backup "$POLICY"
ALLOWED_JSON=$(python3 - "$POLICY" "$URL" "$ALLOW" "$IDLE_MIN" "$BACKSTOP_MIN" "$PRINTING" "$EXT_DIR/kiosk.js" <<'PY'
import json, os, sys
from urllib.parse import urlsplit

policy_path, url, allow_csv, idle_min, backstop_min, printing, js_path = sys.argv[1:8]

def host_of(entry):
    e = str(entry).strip()
    if not e:
        return ""
    if "://" not in e:
        e = "https://" + e.lstrip(".")
    return (urlsplit(e).hostname or "").lstrip("*.").lower()

existing = {}
if os.path.exists(policy_path):
    try:
        with open(policy_path) as f:
            existing = json.load(f)
        if not isinstance(existing, dict):
            raise ValueError("top level is not a JSON object")
    except Exception as e:
        print(f"[kiosk] WARNING: existing policy unreadable ({e}); starting fresh", file=sys.stderr)
        existing = {}

if allow_csv.strip():
    entries = [a for a in allow_csv.split(",") if a.strip()]
else:
    entries = list(existing.get("URLAllowlist", []))

hosts = []
for h in [host_of(e) for e in entries] + [host_of(url)]:
    if h and h not in hosts:
        hosts.append(h)

pol = dict(existing)
# Lockdown settings - always enforced
pol.update({
    "URLBlocklist": ["*"],
    "URLAllowlist": hosts,
    "IncognitoModeAvailability": 1,        # extensions don't run in incognito; RAM profile instead
    "BrowserGuestModeEnabled": False,
    "DeveloperToolsAvailability": 2,
    "DownloadRestrictions": 3,
    "AllowFileSelectionDialogs": False,
    "BrowserSignin": 0,
    "PrintingEnabled": printing == "yes",
    "IdleTimeout": int(backstop_min),
    "IdleTimeoutActions": ["close_browsers"],
})
# Comfort settings - defaults only, so manual edits survive a re-run
for k, v in {
    "PasswordManagerEnabled": False,
    "AutofillAddressEnabled": False,
    "AutofillCreditCardEnabled": False,
    "TranslateEnabled": False,
    "BookmarkBarEnabled": False,
    "DefaultBrowserSettingEnabled": False,
    "MetricsReportingEnabled": False,
    "DefaultNotificationsSetting": 2,
    "DefaultGeolocationSetting": 2,
    "AudioCaptureAllowed": False,
    "VideoCaptureAllowed": False,
}.items():
    pol.setdefault(k, v)

tmp = policy_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(pol, f, indent=2)
    f.write("\n")
os.replace(tmp, policy_path)

with open(js_path) as f:
    src = f.read()
src = (src.replace("__HOME__", json.dumps(url))
          .replace("__ALLOWED__", json.dumps(hosts))
          .replace("__IDLE_MIN__", str(int(idle_min))))
with open(js_path, "w") as f:
    f.write(src)

if int(backstop_min) <= int(idle_min):
    print("[kiosk] WARNING: --backstop_min should be longer than --idle_min", file=sys.stderr)
print(json.dumps(hosts))
PY
)
chmod 755 "$EXT_DIR"
chmod 644 "$EXT_DIR"/* "$POLICY"
log "Allowed domains: $ALLOWED_JSON"

# ------------------------------------------------------------------ kiosk service
STEP="kiosk service"
backup "$SERVICE"
SAFE_URL="${URL//%/%%}"   # systemd treats % as a specifier
cat > "$SERVICE" <<EOF
[Unit]
Description=Library catalog kiosk
After=systemd-user-sessions.service dbus.socket systemd-logind.service getty@tty1.service
Wants=dbus.socket systemd-logind.service
Conflicts=getty@tty1.service

[Service]
User=kiosk
PAMName=cage
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty-fail
UtmpIdentifier=tty1
UtmpMode=user
# /run/kiosk lives in RAM and is deleted whenever the browser stops = fresh profile every launch
RuntimeDirectory=kiosk
ExecStart=/usr/bin/cage -- /usr/bin/chromium --kiosk --ozone-platform=wayland --noerrdialogs --no-first-run --disable-session-crashed-bubble --user-data-dir=/run/kiosk/profile --disk-cache-size=104857600 --load-extension=${EXT_DIR#"$R"} --disable-features=DisableLoadExtensionCommandLineSwitch "$SAFE_URL"
Restart=always
RestartSec=2

[Install]
WantedBy=graphical.target
EOF

# ------------------------------------------------------------------ OS lockdown
STEP="lockdown"
echo "kernel.sysrq=0" > "$R/etc/sysctl.d/99-kiosk.conf"
sysctl -q -p "$R/etc/sysctl.d/99-kiosk.conf" >&2 || true

# 'install ... /bin/false' also stops USB 3 (uas) drives, which a plain blacklist doesn't
cat > "$R/etc/modprobe.d/kiosk-no-usb-storage.conf" <<'EOF'
install usb_storage /bin/false
install uas /bin/false
EOF

mkdir -p "$R/etc/systemd/logind.conf.d"
cat > "$R/etc/systemd/logind.conf.d/kiosk.conf" <<'EOF'
[Login]
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
IdleAction=ignore
EOF
systemctl mask ctrl-alt-del.target sleep.target suspend.target hibernate.target hybrid-sleep.target >&2

log "Rebuilding initramfs..."
update-initramfs -u >&2

# ------------------------------------------------------------------ boot menu lock (optional)
GRUB_LOCKED=false
if [[ "$GRUB_PW" == yes ]]; then
  STEP="boot menu lock"
  command -v grub-mkpasswd-pbkdf2 >/dev/null || fail "grub-mkpasswd-pbkdf2 not found - is GRUB the boot loader?"
  GRUB_HASH=$(printf '%s\n%s\n' "$GRUB_PASSWORD" "$GRUB_PASSWORD" | grub-mkpasswd-pbkdf2 2>/dev/null \
              | grep -o 'grub\.pbkdf2\.sha512\.[^[:space:]]*' || true)
  unset GRUB_PASSWORD
  [[ -n "$GRUB_HASH" ]] || fail "couldn't generate the boot menu password hash"

  LINUX_GEN="$R/etc/grub.d/10_linux"
  backup "$LINUX_GEN"; backup "$R/etc/default/grub"
  # Normal boot entries must stay password-free, or the kiosk won't boot on its own.
  if ! grep -q -- '--unrestricted' "$LINUX_GEN"; then
    sed -i -E 's/^CLASS="--class gnu-linux --class gnu --class os"$/CLASS="--class gnu-linux --class gnu --class os --unrestricted"/' "$LINUX_GEN"
  fi
  grep -q -- '--unrestricted' "$LINUX_GEN" \
    || fail "couldn't mark boot entries unrestricted, so the boot menu was NOT locked (nothing changed)"

  cat > "$R/etc/grub.d/01_kiosk_password" <<EOF
#!/bin/sh
# Written by build-catalog-kiosk.sh: a password is required to EDIT boot entries; normal boot needs none.
cat <<'GRUBEOF'
set superusers="kioskadmin"
password_pbkdf2 kioskadmin $GRUB_HASH
GRUBEOF
EOF
  chmod 755 "$R/etc/grub.d/01_kiosk_password"

  set_grub_default() {
    local f="$R/etc/default/grub"
    if grep -qE "^#?[[:space:]]*$1=" "$f"; then
      sed -i -E "s|^#?[[:space:]]*$1=.*|$1=$2|" "$f"
    else
      echo "$1=$2" >> "$f"
    fi
  }
  set_grub_default GRUB_DISABLE_RECOVERY '"true"'
  set_grub_default GRUB_TIMEOUT 1
  update-grub >&2
  GRUB_LOCKED=true
  log "Boot menu locked (username kioskadmin)"
fi

# ------------------------------------------------------------------ enable
STEP="enable kiosk"
systemctl daemon-reload
systemctl enable kiosk.service >&2
systemctl set-default graphical.target >&2

# ------------------------------------------------------------------ result
STEP="summary"
IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}' || true)
MAC=""
if [[ -n "$IFACE" && -r "/sys/class/net/$IFACE/address" ]]; then MAC=$(cat "/sys/class/net/$IFACE/address"); fi
IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
BACKUPS=""; [[ -d "$BACKUP_DIR" ]] && BACKUPS="${BACKUP_DIR#"$R"}"

python3 - "$(hostname)" "$IP" "$MAC" "$URL" "$ALLOWED_JSON" "$PRINTING" "$GRUB_LOCKED" "$BACKUPS" "$REBOOT" <<'PY'
import json, sys
host, ip, mac, url, allowed, printing, grub_locked, backups, reboot = sys.argv[1:10]
print(json.dumps({
    "status": "ok",
    "data": {
        "hostname": host,
        "ip": ip or None,
        "mac": mac or None,
        "home_url": url,
        "allowed_hosts": json.loads(allowed),
        "printing_enabled": printing == "yes",
        "boot_menu_locked": grub_locked == "true",
        "backups": backups or None,
        "rebooting_now": reboot == "yes",
        "reboot_required": True,
        "manual_steps": [
            "BIOS: set a supervisor password; disable USB boot, network boot, and the F12 boot menu",
            f"DHCP reservation for MAC {mac}" if mac else "DHCP reservation for this machine's MAC",
            "Firewall: allow this machine to reach only the allowed_hosts",
            "Mount behind the monitor with a cable lock",
        ],
    },
    "error": None,
}, indent=2))
PY
log "==== build finished - reboot to start the kiosk ===="

if [[ "$REBOOT" == yes ]]; then
  sleep 3
  systemctl reboot
fi
