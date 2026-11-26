# Libre Export

A small iOS app that scans a FreeStyle Libre sensor over NFC, shows everything the
sensor reveals, and shares it for offline analysis or bug reports. Made for
checking new sensor batches (such as the "303" Libre 2 sensors in
[LibreTransmitter#67](https://github.com/LoopKit/LibreTransmitter/pull/67)).
Not a medical device; for your own data research only.

<p align="center">
  <img src="docs/screenshot.png" width="300" alt="Libre Export after a scan: the current glucose with its rate of change, CRC checks and an 8-hour chart">
  <br><sub>Screenshot with a made-up sensor (Simulator demo mode).</sub>
</p>

## What it does
- **Scan** a sensor over NFC: hold the top of the iPhone against it.
- **The reading** at the top: glucose computed from the sensor's raw values,
  trend arrow and rate of change, serial, age, and a one-line summary such as
  *Libre 2 · Europe · Gen1*. Warm-up and expiry are shown when they apply.
- **Overview:** CRC checks; an 8-hour chart (history plus the last 16 minutes,
  70–180 mg/dL shaded, readings with quality flags as triangles); the **Patch
  info** card (raw bytes, byte 0, family, security version and generation, region,
  the sensor type LibreTransmitter gives it today and with PR #67, whether the
  memory decrypts with the first-generation scheme); the sensor's state, wear time,
  time left, start and end; and sharing.
- **Readings:** the last 16 minutes and the last 8 hours as tables, with raw
  values, temperature, glucose and the quality flags each reading carries (only
  for sensors whose memory was read).
- **Technical:** encryption, calibration (i1–i6), CRC values, ring-buffer indices,
  the region byte in memory; the NFC chip (UID, maker, IC serial, memory size, IC
  reference, which blocks are locked); and the raw bytes, 8 bytes per row.
- **Saved scans** (clock button): every scan is kept on the iPhone, grouped by
  sensor, so you can look at one again or compare it over time. A saved scan is
  marked *Saved scan · date*; the newest one opens when the app starts. Swipe to
  delete; touch and hold for *Copy report*.
- **If the memory fails its CRCs** (for example a batch with a different
  encryption), no glucose, chart or dates are shown, since they'd be garbage; the
  failing CRC is red and the raw values stay available under Readings and Technical.
  If only the body CRC fails, the sensor most likely updated during the read: scan again.
- **Settings** (gear button): mg/dL or mmol/L (defaults to your region), and
  *Read all memory*, which also reads the blocks after the 344-byte FRAM (slower;
  shows where the sensor stops answering).
- **Share:** *Copy report* gives a short text without the UID, serial, readings or
  patch info from byte 4, safe to paste into an issue or PR. *JSON file* and
  *Base64* contain everything.

**Sensors:** Libre 2 (first generation, EU, US, CA) and Libre US 14 day are read
and decrypted; Libre 1, whose memory isn't encrypted, is read as is, also when it
doesn't answer the patch info command. Gen2 Libre 2 and Libre 3 show their patch
info and chip details only (their memory needs an authenticated read or isn't
available over NFC). Libre Pro/H is read, but its memory layout isn't parsed.

## Install on your iPhone

You build the app yourself on a Mac and install it on your own phone; it isn't
on the App Store.

### What you need
- A **Mac** with **Xcode 16 or newer** (free, from the Mac App Store). Open Xcode
  once after installing so it can finish setting up.
- A **paid Apple Developer Program** membership (USD 99/year). A free Apple ID
  can't sign apps that read NFC tags.
- An **iPhone with iOS 17 or later**, and a USB cable for the first install.

### One-time setup
1. **Sign in to Xcode:** Xcode → Settings → Accounts → **+** → Apple ID, with the
   Apple ID of your developer membership.
2. **Connect the iPhone** with the cable, unlock it, and tap **Trust** when it asks
   whether to trust this computer.
3. **Turn on Developer Mode** on the iPhone: Settings → Privacy & Security →
   Developer Mode → on, then let it restart. (The switch only appears after the
   phone has been connected to Xcode once; if it's missing, open Xcode → Window →
   Devices and Simulators with the phone connected, then look again.)

### Install (one command)
In Terminal:

```sh
git clone https://github.com/dabear/libre-sensor-export.git
cd libre-sensor-export
./scripts/install.sh
```

The script finds your team ID (from the development certificate Xcode created
when you signed in) and your connected iPhone, then builds, installs and opens the
app. The first build takes a minute or two.

**First launch only:** iOS asks you to trust the developer. On the iPhone go to
Settings → General → VPN & Device Management → your Apple ID → **Trust**, then open
**Libre Export** from the home screen.

The app keeps working for a year (the life of the development profile). Run
`git pull && ./scripts/install.sh` again to renew it or to install a newer version; your phone
keeps the app, only the code is replaced.

### If something goes wrong
| Message | Fix |
|---|---|
| *No Apple Development certificate found* | Xcode → Settings → Accounts → select your Apple ID → Manage Certificates → **+** → Apple Development. Or pass your team ID: `./scripts/install.sh AB12CD34EF` (find it at developer.apple.com → Account → Membership details). |
| *You have several teams* | Run `./scripts/install.sh <TEAM ID>` with the paid team. |
| *No iPhone found* | Unlock the phone, reconnect the cable, tap Trust. |
| *Several iPhones connected* | `DEVICE=<udid> ./scripts/install.sh` with a UDID from the list it prints. |
| *Developer Mode is off* | See step 3 of the one-time setup. |
| *Build failed* … *No Accounts* / *provisioning* | You aren't signed in to Xcode with the paid team's Apple ID (step 1). The full log is in `build/xcodebuild.log`; it holds your team ID, name and the iPhone's ID, so don't post it publicly. |
| Installed, but it won't open | Unlock the iPhone and open it from the home screen; if iOS says the developer isn't trusted, see *First launch only* above. |

### Install from Xcode instead
1. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and put your
   team ID in it. (`Local.xcconfig` is ignored by git, so your settings stay out of
   the repo.)
2. Open `LibreSensorExport.xcodeproj`, pick your iPhone at the top of the window,
   and press **Run** (⌘R).

The bundle ID is `org.libresensorexport.<your team ID>`, which is unique to you
without any edits. To use your own, set `LIBRE_EXPORT_BUNDLE_ID` in
`Config/Local.xcconfig`.

## Using it
Tap **Scan sensor** and hold the top of the iPhone against the sensor. The phone
shows the progress and vibrates when it's done; if the read is cut short, hold
still and scan again. The scan is saved automatically.

The JSON file and base64 contain your sensor's identity (UID, serial) and your
glucose data. Only share them with people you'd share that with; for public
issues and PRs use **Copy report**.

### Privacy
- The app has no network access; nothing leaves the iPhone unless you share it.
- Every scan is saved on the iPhone, excluded from iCloud and computer backups,
  until you delete it in **Saved scans**; *Delete all* also removes leftover
  export files.
- *Base64* and raw bytes go to this iPhone's clipboard only (not to your other
  devices) and are cleared after 5 minutes. *Copy report* is a normal copy.

## Checking a new sensor batch
Made for confirming [LibreTransmitter#67](https://github.com/LoopKit/LibreTransmitter/pull/67)
(EU sensors with serials starting with 303). Scan the sensor and read the
**Patch info** card:

- **Raw** starts `84 0E 30 01`, **Family** 3, **Security ver** 0 → Gen1, **Region** Europe.
- **LT type**: *Unknown (main)* and *Libre 2 (PR #67)*, i.e. today's
  LibreTransmitter rejects it and the PR accepts it.
- **Gen1 crypto: yes, all CRCs match** is what the PR couldn't test: the batch still
  uses the first-generation encryption LibreTransmitter decrypts. The app decrypts by
  family, not by LibreTransmitter's type list, so it tries even when *main* says
  Unknown. *No, CRCs don't match* would mean the PR alone won't make these sensors work.
- Compare the glucose with the Libre app or reader.

Then tap **Copy report** (Overview, at the bottom) and paste it into the PR: it
has all of the above, plus the iOS version, iPhone model and scan time, without
the sensor's identity.

## Export format (`libre2-fram-export-v1`)
Base64 of a JSON object: `uid`, `patch_info`, `generation`, `fram_encrypted_hex`,
`fram_decrypted_hex`, `minutes_since_start`, `calibration{i1..i6}`, and
`trend_records[{minute, raw_glucose, raw_temperature, raw_temperature_adjustment}]`.
The `trend_records` feed directly into the independent-implementation harness.

Added later, same format name (readers of the fields above are unaffected):
`scanned_at` (time of the FRAM read), `serial`,
`patch_info_decoded{sensor_type, sensor_type_pr67, generation, family, security, region_code, crypto_word}`,
`decrypts_gen1` (all CRCs match after first-generation decryption; only when the FRAM was read),
`tag{ic_manufacturer_code, ic_serial_number, dsfid, afi, block_size, total_blocks, ic_reference | system_info_error}`,
`sensor_state`, `max_minutes_wear`, `next_trend_block`, `next_history_block`,
`fram_region`, `started_at`, `ends_at`, `crc{header|body|footer: {stored, computed}}`,
`history_records` (same shape as `trend_records`), and on each record
`temperature_c` and `glucose_mgdl` when they can be computed.

Version 1.1 adds: `fram_encryption` (`none`, `libre2`, `us14day`,
`undecryptable`, `not_read`; for `none`, `fram_decrypted_hex` is the memory as
read), `patch_info_error` (when the sensor didn't answer it),
`trend_rate_mgdl_per_min`, `error_flags` on each record (LibreTransmitter's
MeasurementError bits; 0 = none), and in `tag`: `block_security` (one status per
block from 0, bit 0 = locked), `block_security_error`, `extra_memory_hex`,
`extra_memory_from_block` and `extra_memory_note` (with *Read all memory*).

Version 1.2 adds `crc_ok` (all three CRCs match) and leaves out `started_at` and
`ends_at` for a sensor that hasn't started.

## Notes
- **Demo mode:** the Simulator has no NFC. A Debug build launched with the
  argument `-demo` (Xcode: Product → Scheme → Edit Scheme → Run → Arguments)
  shows a made-up sensor (patch info `84 0E 30 01`, a 303 sensor), as in the
  screenshot above; add `-demoTab readings` or `-demoTab technical` to open that
  tab, `-demoSaved` to show it as a saved scan, or `-demoBadCRC` to see how a
  memory that fails its CRCs looks. Demo scans aren't saved.
- **Changing the project:** `project.yml` is the source of the Xcode project;
  after editing it run `brew install xcodegen && xcodegen`.
- FRAM decryption and parsing are ported from LoopKit/LibreTransmitter (MIT, see
  LICENSE); no Abbott software is included.
