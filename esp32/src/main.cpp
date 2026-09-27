// NotifBridge ESP32 firmware: BLE bridge between iPhone (ASK accessory) and Mac.
//
//   iPhone (central, ASK) ──WRITE chars──▶ ESP32 (peripheral)
//                                              │
//                                              └──NOTIFY chars──▶ Mac (central, CB)
//
// Bonds persist:
//   - iPhone side bond stored in ESP32 NVS via NimBLE.
//   - Mac side bond stored in macOS bluetoothd (system-wide, AirPods model).
//
// One GATT service, four characteristics — two WRITE (iPhone) + two NOTIFY (Mac).
// Same chunked framing iOS uses (`--START--` / `--END--`) is preserved end-to-end:
// ESP32 receives chunks from iPhone, immediately re-emits them as NOTIFY indications
// to Mac. Mac reassembles using existing logic (unchanged from prior PeripheralManager).

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <vector>
#include "demo_gatt.h"

// ─────────────────────────── globals ───────────────────────────

static NimBLECharacteristic* g_keyWriteChar    = nullptr;
static NimBLECharacteristic* g_notifWriteChar  = nullptr;
static NimBLECharacteristic* g_keyNotifyChar   = nullptr;
static NimBLECharacteristic* g_notifNotifyChar = nullptr;
static NimBLECharacteristic* g_revWriteChar    = nullptr;
static NimBLECharacteristic* g_revNotifyChar   = nullptr;

// Binary semaphore. NimBLE-Arduino's `indicate()` is fire-and-queue: it returns
// immediately, and the ATT-layer confirmation lands later via the char's
// `onStatus` callback. Without waiting for that confirmation, back-to-back
// indicates overflow the host's mbuf pool → chunks silently drop → Mac
// reassembles either a truncated or two-message-concatenated buffer.
//
// Pattern: every indicate() is followed by a Take(timeout). NotifyDescCb's
// onStatus gives the semaphore on success-indicate.
//
// CRITICAL: the wait must NOT run inside the NimBLE host thread. onWrite is
// called by the host; blocking it prevents the host from processing the
// inbound ATT-confirmation that would Give the semaphore → deadlock-until-
// timeout. We therefore hand off the relay to a dedicated FreeRTOS task.
static SemaphoreHandle_t g_indicateDone = nullptr;
static bool g_indicateSucceeded = false;
// Match the negotiated supervision window; healthy confirmations have been
// observed after 1.5 seconds when both central links are busy.
static constexpr TickType_t INDICATE_TIMEOUT = pdMS_TO_TICKS(6000);

static int g_connectedCentrals = 0;

// Each iPhone WRITE becomes one RelayJob queued for the relay task. Heap copy
// of the payload because c->getValue()'s std::string lives only inside onWrite.
struct RelayJob {
    NimBLECharacteristic* dst;
    const char* tag;
    std::vector<uint8_t> data;
    std::vector<uint8_t> receipt;
};
static QueueHandle_t g_relayQueue = nullptr;
static constexpr size_t RELAY_QUEUE_DEPTH = 16;

// ─────────────────────────── BLE callbacks ───────────────────────────

class ServerCb : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer* s, ble_gap_conn_desc* d) override {
        g_connectedCentrals++;
        Serial.printf("[BLE] central connected handle=%u total=%d peer=%s\n",
                      d->conn_handle, g_connectedCentrals,
                      NimBLEAddress(d->peer_id_addr).toString().c_str());
        s->setDataLen(d->conn_handle, 251);
        // Request intervals after subscription, when security/discovery has
        // finished. Doing it here raced setup and returned BLE_HS_EALREADY.
        if (!NimBLEDevice::getAdvertising()->isAdvertising()) {
            NimBLEDevice::startAdvertising();
        }
    }
    void onDisconnect(NimBLEServer*) override {
        if (g_connectedCentrals > 0) g_connectedCentrals--;
        Serial.printf("[BLE] central disconnected total=%d — advertising\n", g_connectedCentrals);
        if (!NimBLEDevice::getAdvertising()->isAdvertising()) {
            NimBLEDevice::startAdvertising();
        }
    }
    uint32_t onPassKeyRequest() override { return 0; }
    bool onConfirmPIN(uint32_t) override { return true; }
    void onAuthenticationComplete(ble_gap_conn_desc* d) override {
        Serial.printf("[BLE] auth encrypted=%d bonded=%d peer=%s\n",
                      d->sec_state.encrypted, d->sec_state.bonded,
                      NimBLEAddress(d->peer_id_addr).toString().c_str());
    }
    void onMTUChange(uint16_t mtu, ble_gap_conn_desc* d) override {
        Serial.printf("[BLE] MTU=%u handle=%u\n", mtu, d->conn_handle);
    }
};

// Relays writes from iPhone (write char) to Mac (notify char). iOS uses Write Long
// for >MTU-3 payloads, so a single onWrite can deliver up to ~509 bytes in one chunk.
// INDICATE caps at MTU-3 (244B for MTU=247) — we re-chunk to a safe 200B before
// each indicate. Mac's reassembler looks for whole-frame `--START--` / `--END--`
// tokens; sentinels are 9 / 7 bytes and ride through intact, payload bytes append
// to the assembly buffer.
//
// **Why indicate instead of notify**: notify is fire-and-forget. Under load (large
// rich frames with embedded icons, two centrals connected) packets silently drop,
// the Mac sees `--START--` … (missing chunks) … `--END--`, JSON decode fails on
// the truncated buffer. Indicate has per-packet confirmation from the central, so
// `indicate()` returns false on drop and the BLE host won't overwhelm the link.
static constexpr size_t INDICATE_SLICE = 200;

// Producer: enqueues a heap-owned job; returns instantly so the NimBLE host
// thread stays free to dispatch ATT confirms from the Mac side.
class WriteRelay : public NimBLECharacteristicCallbacks {
public:
    NimBLECharacteristic** dst;
    const char* tag;
    WriteRelay(NimBLECharacteristic** d, const char* t) : dst(d), tag(t) {}
    void onWrite(NimBLECharacteristic* c) override {
        std::string v = c->getValue();
        if (v.empty()) return;
        Serial.printf("[REL] %s rx %u bytes  hex=", tag, (unsigned)v.size());
        size_t n = v.size() < 16 ? v.size() : 16;
        for (size_t i = 0; i < n; i++) Serial.printf("%02x", (uint8_t)v[i]);
        Serial.printf("%s\n", v.size() > 16 ? "…" : "");
        if (!*dst) return;
        auto* job = new RelayJob{
            *dst, tag,
            std::vector<uint8_t>(v.begin(), v.end()), {}
        };
        // Versioned flow-control wrapper from iPhone Transport. The receipt
        // echoes a unique chunk ID only after the Mac confirms every slice.
        if (*dst == g_notifNotifyChar && v.size() > 20 && v.compare(0, 4, "NBW1") == 0) {
            job->receipt.assign(v.begin(), v.begin() + 20);
            job->receipt[2] = 'A';
            job->data.assign(v.begin() + 20, v.end());
        }
        if (xQueueSend(g_relayQueue, &job, 0) != pdTRUE) {
            Serial.printf("[REL] %s queue FULL drop %u bytes\n", tag, (unsigned)v.size());
            delete job;
        }
    }
};

// Consumer: runs on its own task (pinned to core 0; NimBLE pinned to core 1).
// Can block on the indicate-done semaphore without starving the BLE host —
// confirmations from Mac flow through the host task and Give it freely.
static void relayTask(void*) {
    Serial.println("[relay] task running");
    RelayJob* job;
    for (;;) {
        if (xQueueReceive(g_relayQueue, &job, portMAX_DELAY) != pdTRUE) continue;
        size_t off = 0;
        const uint8_t* p = job->data.data();
        size_t total = job->data.size();
        bool delivered = true;
        while (off < total) {
            size_t slice = INDICATE_SLICE;
            auto* server = NimBLEDevice::getServer();
            for (auto peer : server->getPeerDevices()) {
                uint16_t mtu = server->getPeerMTU(peer);
                size_t capacity = mtu > 3 ? mtu - 3 : 20;
                if (capacity < slice) slice = capacity;
            }
            size_t take = (total - off) < slice ? (total - off) : slice;
            job->dst->setValue(p + off, take);
            xSemaphoreTake(g_indicateDone, 0);
            uint32_t t0 = millis();
            g_indicateSucceeded = false;
            job->dst->indicate();
            BaseType_t ok = xSemaphoreTake(g_indicateDone, INDICATE_TIMEOUT);
            uint32_t dt = millis() - t0;
            if (ok != pdTRUE || !g_indicateSucceeded) {
                delivered = false;
                Serial.printf("[relay] %s TIMEOUT off=%u dt=%ums\n",
                              job->tag, (unsigned)off, (unsigned)dt);
                break;
            } else if (dt > 100 || off == 0) {
                Serial.printf("[relay] %s off=%u size=%u ack=%ums\n",
                              job->tag, (unsigned)off, (unsigned)take, (unsigned)dt);
            }
            off += take;
        }
        if (delivered && !job->receipt.empty()) {
            g_revNotifyChar->setValue(job->receipt.data(), job->receipt.size());
            xSemaphoreTake(g_indicateDone, 0);
            g_indicateSucceeded = false;
            g_revNotifyChar->indicate();
            xSemaphoreTake(g_indicateDone, INDICATE_TIMEOUT);
        }
        delete job;
    }
}

class NotifyDescCb : public NimBLECharacteristicCallbacks {
public:
    const char* tag;
    NotifyDescCb(const char* t) : tag(t) {}
    void onSubscribe(NimBLECharacteristic* ch, ble_gap_conn_desc* d, uint16_t sub) override {
        Serial.printf("[BLE] subscribe %s sub=%u handle=%u\n", tag, sub, d->conn_handle);
        if (sub && (ch == g_notifNotifyChar || ch == g_revNotifyChar)) {
            // Different interval ranges leave airtime for both central roles.
            // A longer supervision window tolerates temporary scheduling gaps.
            const bool mac = ch == g_notifNotifyChar;
            NimBLEDevice::getServer()->updateConnParams(d->conn_handle,
                mac ? 24 : 12, mac ? 36 : 24, 0, 600);
        }
    }
    void onStatus(NimBLECharacteristic*, Status s, int code) override {
        // Unconditional log — verifying this callback actually fires.
        Serial.printf("[BLE] %s onStatus s=%d code=%d\n", tag, (int)s, code);
        g_indicateSucceeded = s == SUCCESS_INDICATE;
        xSemaphoreGive(g_indicateDone);
    }
};

// ─────────────────────────── setup ───────────────────────────

void setup() {
    Serial.begin(115200);
    delay(200);
    Serial.println("\n[boot] NotifBridge ESP32 — build " __DATE__ " " __TIME__);

    g_indicateDone = xSemaphoreCreateBinary();
    g_relayQueue   = xQueueCreate(RELAY_QUEUE_DEPTH, sizeof(RelayJob*));
    // Pin relay task to core 0; NimBLE host pinned to core 1 via build flag.
    // Two cores → BLE-host ATT confirms dispatch in parallel with our chunked
    // indicate loop blocking on the semaphore.
    xTaskCreatePinnedToCore(relayTask, "relay", 8192, nullptr, 5, nullptr, 0);

    NimBLEDevice::init(ADV_NAME);
    NimBLEDevice::setPower(ESP_PWR_LVL_P9);
    NimBLEDevice::setSecurityAuth(true, false, true);   // bond, no MITM, LE-SC
    NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
    NimBLEDevice::setMTU(247);

    auto* server = NimBLEDevice::createServer();
    server->setCallbacks(new ServerCb());

    auto* svc = server->createService(SVC_UUID);

    g_keyWriteChar = svc->createCharacteristic(
        CHAR_KEYS_WRITE,
        NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
    g_notifWriteChar = svc->createCharacteristic(
        CHAR_NOTIF_WRITE,
        NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);

    g_keyNotifyChar = svc->createCharacteristic(
        CHAR_KEYS_NOTIFY,
        NIMBLE_PROPERTY::INDICATE | NIMBLE_PROPERTY::READ);
    g_notifNotifyChar = svc->createCharacteristic(
        CHAR_NOTIF_NOTIFY,
        NIMBLE_PROPERTY::INDICATE | NIMBLE_PROPERTY::READ);

    g_revWriteChar = svc->createCharacteristic(
        CHAR_REV_WRITE,
        NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
    g_revNotifyChar = svc->createCharacteristic(
        CHAR_REV_NOTIFY,
        NIMBLE_PROPERTY::INDICATE | NIMBLE_PROPERTY::READ);

    g_keyWriteChar->setCallbacks(new WriteRelay(&g_keyNotifyChar, "keys"));
    g_notifWriteChar->setCallbacks(new WriteRelay(&g_notifNotifyChar, "notif"));
    g_revWriteChar->setCallbacks(new WriteRelay(&g_revNotifyChar, "rev"));
    g_keyNotifyChar->setCallbacks(new NotifyDescCb("keysN"));
    g_notifNotifyChar->setCallbacks(new NotifyDescCb("notifN"));
    g_revNotifyChar->setCallbacks(new NotifyDescCb("revN"));

    svc->start();

    auto* adv = NimBLEDevice::getAdvertising();
    adv->addServiceUUID(SVC_UUID);
    adv->setScanResponse(true);
    adv->setName(ADV_NAME);
    adv->start();

    Serial.printf("[BLE] advertising name=%s addr=%s\n",
                  ADV_NAME, NimBLEDevice::getAddress().toString().c_str());
    Serial.println("[boot] ready");
}

void loop() {
    delay(1000);
    static uint32_t lastBeat = 0;
    uint32_t now = millis();
    if (now - lastBeat > 10000) {
        lastBeat = now;
        Serial.printf("[hb] uptime=%us centrals=%d adv=%d\n",
                      (unsigned)(now / 1000), g_connectedCentrals,
                      NimBLEDevice::getAdvertising()->isAdvertising());
        // Dump negotiated conn-params for every live link. Helps diagnose
        // slow ATT confirmations: if a central pinned us to 100ms+ intervals
        // despite our 15–30ms request, that's the bottleneck.
        auto* server = NimBLEDevice::getServer();
        if (server) {
            size_t count = server->getConnectedCount();
            for (size_t i = 0; i < count; i++) {
                NimBLEConnInfo info = server->getPeerInfo(i);
                Serial.printf("[hb] peer=%s itvl=%u(=%ums) lat=%u to=%ums mtu=%u\n",
                              info.getAddress().toString().c_str(),
                              info.getConnInterval(),
                              (info.getConnInterval() * 125) / 100,
                              info.getConnLatency(),
                              info.getConnTimeout() * 10,
                              info.getMTU());
            }
        }
    }
}
