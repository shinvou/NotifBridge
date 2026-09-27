#pragma once
// Mirrors shared/DemoGATT.swift. Must stay in sync with iOS + macOS.

#define SVC_UUID         "D5E12B7A-7D8E-4F12-9B5C-3F0A1E6D8C44"

// iPhone → ESP32 (WRITE, chunked + sentinel-bracketed).
#define CHAR_KEYS_WRITE  "D5E12B7A-7D8E-4F12-9B5C-3F0A1E6D8C46"
#define CHAR_NOTIF_WRITE "D5E12B7A-7D8E-4F12-9B5C-3F0A1E6D8C47"

// ESP32 → Mac (NOTIFY, chunked + sentinel-bracketed).
#define CHAR_KEYS_NOTIFY  "D5E12B7A-7D8E-4F12-9B5C-3F0A1E6D8C48"
#define CHAR_NOTIF_NOTIFY "D5E12B7A-7D8E-4F12-9B5C-3F0A1E6D8C49"

// Reverse channel: Mac → ESP32 (WRITE), ESP32 → iPhone (NOTIFY).
#define CHAR_REV_WRITE    "D5E12B7A-7D8E-4F12-9B5C-3F0A1E6D8C4A"
#define CHAR_REV_NOTIFY   "D5E12B7A-7D8E-4F12-9B5C-3F0A1E6D8C4B"

// Substring iPhone's ASDiscoveryDescriptor + Mac scan use to identify us.
#define ADV_NAME         "NotifBdg"

// Chunk framing sentinels mirror iOS AccessoryBLEWriter.
#define FRAME_START      "--START--"
#define FRAME_END        "--END--"
