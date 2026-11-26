#!/bin/bash
# Build Libre Export and install it on the iPhone connected to this Mac.
#
#   ./scripts/install.sh               # finds your team ID and your iPhone
#   ./scripts/install.sh AB12CD34EF    # use this team ID
#   DEVICE=<udid> ./scripts/install.sh # pick a phone when several are connected
#
# Needs: Xcode, signed in to your paid Apple Developer account (Xcode > Settings >
# Accounts), and the iPhone connected (cable or same Wi-Fi) with Developer Mode on.
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT=LibreSensorExport.xcodeproj
SCHEME=LibreSensorExport
DERIVED=build/DerivedData
LOCAL=Config/Local.xcconfig

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Xcode: installed, selected, set up
case "$(xcode-select -p 2>/dev/null)" in
    *Xcode*.app/*) ;;
    *) fail "Xcode isn't selected (the Command Line Tools are). Install Xcode from the Mac App Store, then:
       sudo xcode-select -s /Applications/Xcode.app" ;;
esac
xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 \
    || fail "Xcode isn't set up yet. Open Xcode once, or run: sudo xcodebuild -runFirstLaunch"
XCODE_MAJOR=$(xcodebuild -version 2>/dev/null | sed -n 's/^Xcode \([0-9]*\).*/\1/p')
[[ "${XCODE_MAJOR:-0}" -ge 16 ]] || fail "Xcode 16 or newer is needed (found: $(xcodebuild -version 2>/dev/null | head -1))."

# --- Team ID: argument, $TEAM, Config/Local.xcconfig, the paid teams signed in to Xcode, or
#     your unexpired Apple Development certificates
TEAM="${1:-${TEAM:-}}"
if [[ -z "$TEAM" && -f "$LOCAL" ]]; then
    TEAM=$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' "$LOCAL" | tail -1)
fi
if [[ -z "$TEAM" ]]; then
    TEAMS=$(xcrun python3 - <<'EOF'
import json, subprocess
teams = {}
# 1. teams signed in to Xcode (Settings > Accounts), paid ones only: free teams can't sign NFC apps
try:
    raw = subprocess.run(["defaults", "export", "com.apple.dt.Xcode", "-"], capture_output=True).stdout
    by_account = json.loads(subprocess.run(["plutil", "-extract", "IDEProvisioningTeamByIdentifier", "json",
                                            "-o", "-", "-"], input=raw, capture_output=True).stdout or b"{}")
    for account in by_account.values():
        for t in account:
            if not t.get("isFreeProvisioningTeam") and t.get("teamID"):
                teams[t["teamID"]] = t.get("teamName", "")
except Exception:
    pass
# 2. otherwise unexpired Apple Development certificates (their OU is the team ID)
if not teams:
    pems = subprocess.run(["security", "find-certificate", "-a", "-c", "Apple Development", "-p"],
                          capture_output=True, text=True).stdout.split("-----END CERTIFICATE-----")
    for pem in pems:
        if "BEGIN CERTIFICATE" not in pem:
            continue
        pem += "-----END CERTIFICATE-----\n"
        if subprocess.run(["openssl", "x509", "-noout", "-checkend", "0"], input=pem, text=True,
                          capture_output=True).returncode != 0:
            continue   # expired
        subject = subprocess.run(["openssl", "x509", "-noout", "-subject", "-nameopt", "multiline"],
                                 input=pem, text=True, capture_output=True).stdout
        for line in subject.splitlines():
            if line.strip().startswith("organizationalUnitName"):
                teams.setdefault(line.split("=", 1)[1].strip(), "")
for team_id, name in sorted(teams.items()):
    print(f"{team_id}\t{name}")
EOF
)
    case $(printf '%s' "$TEAMS" | grep -c .) in
        1) TEAM=$(printf '%s' "$TEAMS" | cut -f1) ;;
        0) fail "No paid Apple Developer team found. In Xcode: Settings > Accounts > + > Apple ID, with
       the Apple ID of your paid membership. Or pass your team ID:
       ./scripts/install.sh AB12CD34EF  (developer.apple.com > Account > Membership details)" ;;
        *) printf '%s\n' "$TEAMS" | awk -F'\t' '{print "  " $1 "  " $2}'
           fail "You have several teams. Pick one: ./scripts/install.sh <TEAM ID>" ;;
    esac
fi
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || fail "'$TEAM' doesn't look like a team ID (10 letters/digits)."
say "Team ID: $TEAM"

# --- Device: $DEVICE, or the one connected iPhone
DEVICES_JSON=$(mktemp)
trap 'rm -f "$DEVICES_JSON"' EXIT
if ! DEVICECTL_ERR=$(xcrun devicectl list devices --json-output "$DEVICES_JSON" 2>&1 >/dev/null); then
    fail "Could not list devices: ${DEVICECTL_ERR:-devicectl failed}"
fi
PHONES=$(xcrun python3 - "$DEVICES_JSON" <<'EOF'
import json, sys

def find(d, key):
    """The first value for key anywhere in d: devicectl is moving its fields into 'properties'."""
    if isinstance(d, dict):
        if key in d:
            return d[key]
        for v in d.values():
            r = find(v, key)
            if r is not None:
                return r
    elif isinstance(d, list):
        for v in d:
            r = find(v, key)
            if r is not None:
                return r
    return None

for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw = d.get("hardwareProperties") or find(d, "hardwareProperties") or {}
    props = d.get("deviceProperties") or find(d, "deviceProperties") or {}
    conn = d.get("connectionProperties") or find(d, "connectionProperties") or {}
    platform, reality = hw.get("platform") or find(d, "platform"), hw.get("reality") or find(d, "reality")
    kind = hw.get("deviceType") or find(d, "deviceType") or "iPhone"
    if platform != "iOS" or reality != "physical" or kind != "iPhone":
        continue   # Simulators, iPads, watches
    print("\t".join([hw.get("udid") or find(d, "udid") or "", props.get("name") or "?",
                     conn.get("tunnelState") or "", str(props.get("developerModeStatus", "?"))]))
EOF
)
if [[ -z "${DEVICE:-}" ]]; then
    CONNECTED=$(printf '%s\n' "$PHONES" | awk -F'\t' '$3 != "unavailable" && $1 != ""')
    case $(printf '%s' "$CONNECTED" | grep -c .) in
        1) DEVICE=$(printf '%s' "$CONNECTED" | cut -f1) ;;
        0) fail "No iPhone found. Connect it with a cable, unlock it, and tap Trust if asked." ;;
        *) printf '%s\n' "$CONNECTED" | awk -F'\t' '{print "  " $1 "  " $2}'
           fail "Several iPhones connected. Pick one: DEVICE=<udid> ./scripts/install.sh" ;;
    esac
fi
LINE=$(printf '%s\n' "$PHONES" | awk -F'\t' -v u="$DEVICE" '$1 == u')
[[ -n "$LINE" ]] || fail "No iPhone with UDID $DEVICE is known to this Mac. Check DEVICE, or leave it out."
say "iPhone: $(printf '%s' "$LINE" | cut -f2) ($DEVICE)"
if [[ "$(printf '%s' "$LINE" | cut -f4)" == "disabled" ]]; then
    fail "Developer Mode is off on the iPhone: Settings > Privacy & Security > Developer Mode, then restart it."
fi

# --- Build (Xcode creates the App ID and provisioning profile on first run)
say "Building (first build takes a minute)..."
LOG=build/xcodebuild.log
mkdir -p build
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
        -destination "id=$DEVICE" -derivedDataPath "$DERIVED" \
        -allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM="$TEAM" build >"$LOG" 2>&1; then
    grep -E "error:|requires a provisioning|No Accounts|signing" "$LOG" | sort -u | head -15 >&2 || true
    fail "Build failed. Full log: $LOG (it holds your team ID, name and the iPhone's ID: don't post it publicly)
       Most common fixes: unlock the iPhone and run again, or Xcode > Settings > Accounts, sign in with the Apple ID of team $TEAM."
fi
APP="$DERIVED/Build/Products/Release-iphoneos/LibreSensorExport.app"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")

# --- Install (devicectl is sometimes flaky: one retry)
say "Installing $BUNDLE_ID..."
xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null 2>&1 \
    || xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null \
    || fail "Install failed. Unlock the iPhone and run the script again."
rm -f "$LOG"   # holds signing identities and device IDs

say "Launching..."
if ! xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1; then
    echo "Installed, but it didn't start. Unlock the iPhone and open Libre Export from the home screen."
    echo "If iOS says the developer isn't trusted: Settings > General > VPN & Device Management >"
    echo "your Apple ID > Trust."
    exit 0
fi
say "Done: Libre Export is open on the iPhone."
