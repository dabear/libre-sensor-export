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

command -v xcodebuild >/dev/null || fail "Xcode is not installed. Get it from the Mac App Store."
xcrun --find devicectl >/dev/null 2>&1 || fail "Xcode 15 or newer is needed (devicectl not found)."

# --- Team ID: argument, $TEAM, Config/Local.xcconfig, or your Apple Development certificate
TEAM="${1:-${TEAM:-}}"
if [[ -z "$TEAM" && -f "$LOCAL" ]]; then
    TEAM=$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' "$LOCAL" | tail -1)
fi
if [[ -z "$TEAM" ]]; then
    # The certificate's OU field is the team ID.
    TEAMS=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
        | awk '/BEGIN CERT/{c=""} {c=c $0 "\n"} /END CERT/{printf "%s", c | "openssl x509 -noout -subject -nameopt multiline"; close("openssl x509 -noout -subject -nameopt multiline")}' \
        | sed -n 's/^[[:space:]]*organizationalUnitName[[:space:]]*=[[:space:]]*//p' | sort -u)
    case $(printf '%s' "$TEAMS" | grep -c .) in
        1) TEAM="$TEAMS" ;;
        0) fail "No Apple Development certificate found. In Xcode: Settings > Accounts > add your
       Apple ID > Manage Certificates > + > Apple Development. Or pass your team ID:
       ./scripts/install.sh AB12CD34EF  (developer.apple.com > Account > Membership details)" ;;
        *) fail "You have several teams: $(echo $TEAMS). Pick one: ./scripts/install.sh <TEAM ID>" ;;
    esac
fi
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || fail "'$TEAM' doesn't look like a team ID (10 letters/digits)."
say "Team ID: $TEAM"

# --- Device: $DEVICE, or the one connected physical iPhone
DEVICES_JSON=$(mktemp)
trap 'rm -f "$DEVICES_JSON"' EXIT
xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null 2>&1 || fail "Could not list devices (devicectl)."
PHONES=$(xcrun python3 - "$DEVICES_JSON" <<'EOF'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw, props = d.get("hardwareProperties", {}), d.get("deviceProperties", {})
    if hw.get("platform") != "iOS" or hw.get("reality") != "physical":
        continue
    state = d.get("connectionProperties", {}).get("tunnelState", "")
    print("\t".join([hw.get("udid", ""), props.get("name", "?"), state,
                     str(props.get("developerModeStatus", "?"))]))
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
        -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" build >"$LOG" 2>&1; then
    grep -E "error:|requires a provisioning|No Accounts|signing" "$LOG" | sort -u | head -15 >&2 || true
    fail "Build failed. Full log: $LOG
       Most common fix: Xcode > Settings > Accounts, sign in with the Apple ID of team $TEAM."
fi
APP="$DERIVED/Build/Products/Release-iphoneos/LibreSensorExport.app"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")

# --- Install (devicectl is sometimes flaky: one retry)
say "Installing $BUNDLE_ID..."
xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null 2>&1 \
    || xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null \
    || fail "Install failed. Unlock the iPhone and run the script again."

say "Launching..."
if ! xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1; then
    echo "Installed, but iOS didn't let it start yet. The first time, on the iPhone:"
    echo "  Settings > General > VPN & Device Management > your Apple ID > Trust"
    echo "then open Libre Export from the home screen."
    exit 0
fi
say "Done: Libre Export is open on the iPhone."
