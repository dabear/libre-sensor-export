# Libre Export

A tiny ad-hoc iOS app that scans a FreeStyle Libre 2 sensor over NFC, shows its
data on-device for verification, and shares a base64 export for offline analysis.
Not a medical device; for your own data research only.

## What it does
- **Scan** your sensor over NFC (hold it to the top of the phone).
- **Verify on-device:** serial, generation, sensor age, the three FRAM CRCs,
  calibration (i2/i3/i4/i6), a trend sparkline, and the current glucose computed
  from the raw records — compare it against your Libre reader.
- **Export:** a base64 string (JSON) with UID, patch info, the raw + decrypted
  FRAM, the calibration, and the trend records. Copy or Share it.

## Build & install (real iPhone)
NFC needs a **paid Apple Developer** membership and a real device (NFC does not
work in the Simulator).
1. `brew install xcodegen && xcodegen` (regenerates the project from `project.yml`),
   or just open `LibreSensorExport.xcodeproj`.
2. In Xcode: target **LibreSensorExport → Signing & Capabilities** → check
   *Automatically manage signing* and pick your Team (add your Apple ID if asked).
   The *Near Field Communication Tag Reading* capability is already declared.
3. Select your iPhone as the destination and press **Run** (⌘R). First run: on the
   phone, enable *Developer Mode* (Settings → Privacy & Security) and trust the app
   (Settings → General → VPN & Device Management).

## Export format (`libre2-fram-export-v1`)
Base64 of a JSON object: `uid`, `patch_info`, `generation`, `fram_encrypted_hex`,
`fram_decrypted_hex`, `minutes_since_start`, `calibration{i1..i6}`, and
`trend_records[{minute, raw_glucose, raw_temperature, raw_temperature_adjustment}]`.
The `trend_records` feed directly into the independent-implementation harness.

## Notes
- **Gen2 sensors:** the app captures UID + patch info; the FRAM needs the
  authenticated read, so no values are shown for Gen2 yet (the export still carries
  the identity).
- Clean-room: FRAM decrypt/parse ported from MIT LibreTransmitter; no Abbott binary.
