/* =============================================================================
 *  esp32_voip_router.ino — ESP32 WebSocket call router for the Flutter client
 *  ---------------------------------------------------------------------------
 *  What it does
 *    · Raises a SoftAP ("ESP32-VOIP") so handsets can join with no router at all
 *    · Accepts ONE WebSocket per handset on port 81
 *    · Registration : username -> 1-byte routing id (1..254, 0 = broadcast)
 *    · Signalling   : make_call / call_accept / call_reject / end_call
 *    · Busy line    : the 3rd party gets {"type":"line_busy", ...}
 *    · Audio        : binary frames are forwarded verbatim, header included
 *                     [ targetId (1 byte) | PCM16 mono 16 kHz | ... ]
 *
 *  Wire format: see docs/protocol.md in the Flutter app (same repository)
 *
 *  Required library (Library Manager)
 *    "WebSockets" by Markus Sattler   (Links2004/arduinoWebSockets)
 *
 *  Board: "ESP32 Dev Module" (any ESP32 with Wi-Fi). No ArduinoJson needed —
 *  the few fields we care about are read by a tiny hand-rolled extractor so the
 *  sketch cannot break on ArduinoJson 6 vs 7 API changes.
 * ===========================================================================*/

#include <WiFi.h>
#include <WebSocketsServer.h>
#include <string.h>

// -----------------------------------------------------------------------------
// Configuration
// -----------------------------------------------------------------------------
#define DEBUG_SERIAL          1          // set to 0 to silence the serial log
#define AP_SSID               "ESP32-VOIP"
#define AP_PASSWORD           "voip12345"  // >= 8 chars; "" for an open AP
#define WS_PORT               81

static const uint8_t MAX_PEERS        = 8;      // handsets supported at once
static const uint8_t MAX_USER_LEN     = 23;
static const uint32_t RING_TIMEOUT_MS = 45000;  // matches the app's 45 s timer
static const uint32_t IDLE_TIMEOUT_MS = 120000; // drop silent sockets

// The single WebSocket server instance (declared early: every helper uses it).
WebSocketsServer webSocketServer(WS_PORT);

// -----------------------------------------------------------------------------
// Peer table
// -----------------------------------------------------------------------------
struct Peer {
  bool     used;
  uint8_t  num;            // WebSocket client number
  uint8_t  id;             // routing id (1..254)
  bool     ringing;        // outgoing or incoming ring in progress
  uint8_t  callWith;       // routing id of the bridged peer (0 = none)
  char     user[MAX_USER_LEN + 1];
  uint32_t lastSeen;
  uint32_t ringSince;
};

static Peer    peers[MAX_PEERS];
static uint32_t forwardedFrames = 0;
static uint32_t droppedFrames   = 0;

// -----------------------------------------------------------------------------
// Logger
// -----------------------------------------------------------------------------
#if DEBUG_SERIAL
  #define LOGF(...) Serial.printf(__VA_ARGS__)
#else
  #define LOGF(...) do {} while (0)
#endif

// -----------------------------------------------------------------------------
// Tiny JSON field reader (enough for our flat control frames)
// -----------------------------------------------------------------------------
static String jsonField(const String &json, const char *key) {
  const String pattern = String("\"") + key + "\"";
  int k = json.indexOf(pattern);
  if (k < 0) return String();

  int colon = json.indexOf(':', k + pattern.length());
  if (colon < 0) return String();

  int i = colon + 1;
  while (i < (int)json.length() &&
         (json[i] == ' ' || json[i] == '\t' || json[i] == '\n' || json[i] == '\r')) {
    i++;
  }
  if (i >= (int)json.length()) return String();

  if (json[i] == '"') {                     // quoted string
    const int start = ++i;
    while (i < (int)json.length() && json[i] != '"') i++;
    return json.substring(start, i);
  }
  const int start = i;                      // number / bool / null
  while (i < (int)json.length() && json[i] != ',' && json[i] != '}' &&
         json[i] != ' ' && json[i] != '\r' && json[i] != '\n') {
    i++;
  }
  return json.substring(start, i);
}

static bool isSafeName(const String &name) {
  if (name.length() == 0 || name.length() > MAX_USER_LEN) return false;
  for (size_t i = 0; i < name.length(); i++) {
    const char c = name[i];
    const bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                    (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.';
    if (!ok) return false;
  }
  return true;
}

// -----------------------------------------------------------------------------
// Peer table helpers
// -----------------------------------------------------------------------------
static Peer *peerByNum(uint8_t num) {
  for (uint8_t i = 0; i < MAX_PEERS; i++) {
    if (peers[i].used && peers[i].num == num) return &peers[i];
  }
  return nullptr;
}

static Peer *peerById(uint8_t id) {
  if (id == 0) return nullptr;
  for (uint8_t i = 0; i < MAX_PEERS; i++) {
    if (peers[i].used && peers[i].id == id) return &peers[i];
  }
  return nullptr;
}

static Peer *peerByUser(const String &user) {
  for (uint8_t i = 0; i < MAX_PEERS; i++) {
    if (peers[i].used && user.equalsIgnoreCase(peers[i].user)) return &peers[i];
  }
  return nullptr;
}

static Peer *freeSlot() {
  for (uint8_t i = 0; i < MAX_PEERS; i++) {
    if (!peers[i].used) return &peers[i];
  }
  return nullptr;
}

static uint8_t allocateId() {
  for (uint8_t id = 1; id < 255; id++) {
    if (peerById(id) == nullptr) return id;
  }
  return 0;                                  // table exhausted
}

static void sendTxt(uint8_t num, const String &payload) {
  webSocketServer.sendTXT(num, payload.c_str());
}

// -----------------------------------------------------------------------------
// Call state machine
// -----------------------------------------------------------------------------
static void clearCall(Peer *p, bool notifyPeer, const char *reason) {
  if (p == nullptr) return;
  Peer *other = peerById(p->callWith);
  p->callWith  = 0;
  p->ringing   = false;
  if (other != nullptr) {
    other->callWith = 0;
    other->ringing  = false;
    if (notifyPeer) {
      sendTxt(other->num,
              String("{\"type\":\"call_ended\",\"from\":\"") + p->user +
              "\",\"message\":\"" + (reason ? reason : "peer_hangup") + "\"}");
    }
  }
}

// -----------------------------------------------------------------------------
// Signalling handlers
// -----------------------------------------------------------------------------
static void handleRegister(uint8_t num, const String &from) {
  if (!isSafeName(from)) {
    sendTxt(num, "{\"type\":\"error\",\"message\":\"Invalid username.\"}");
    return;
  }

  Peer *existing = peerByUser(from);
  if (existing != nullptr && existing->num != num) {
    // Same username reconnecting (the app re-registers after every reconnect):
    // take over the identity and close the stale socket.
    LOGF("[reg] %s took over socket %u from %u\n", from.c_str(), num, existing->num);
    clearCall(existing, true, "connection_replaced");
    const uint8_t staleNum = existing->num;
    existing->num  = num;
    existing->lastSeen = millis();
    webSocketServer.disconnect(staleNum);
    sendTxt(num, String("{\"type\":\"registered\",\"from\":\"") + from +
                  "\",\"id\":" + String(existing->id) + "}");
    return;
  }
  if (existing != nullptr) {                 // same socket re-registering
    sendTxt(num, String("{\"type\":\"registered\",\"from\":\"") + from +
                  "\",\"id\":" + String(existing->id) + "}");
    return;
  }

  Peer *slot = peerByNum(num);
  if (slot == nullptr) slot = freeSlot();
  if (slot == nullptr) {
    sendTxt(num, "{\"type\":\"error\",\"message\":\"Router is full.\"}");
    return;
  }

  const uint8_t id = allocateId();
  if (id == 0) {
    sendTxt(num, "{\"type\":\"error\",\"message\":\"No routing ids left.\"}");
    return;
  }

  slot->used     = true;
  slot->num      = num;
  slot->id       = id;
  slot->ringing  = false;
  slot->callWith = 0;
  slot->lastSeen = millis();
  from.toCharArray(slot->user, sizeof(slot->user));

  LOGF("[reg] socket %u -> %s (id=%u)\n", num, slot->user, slot->id);
  sendTxt(num, String("{\"type\":\"registered\",\"from\":\"") + from +
                "\",\"id\":" + String(id) + "}");
}

static void handleMakeCall(uint8_t num, const String &from, const String &to) {
  Peer *caller = peerByNum(num);
  if (caller == nullptr) {
    sendTxt(num, "{\"type\":\"error\",\"message\":\"Register first.\"}");
    return;
  }
  if (to.length() == 0) {
    sendTxt(num, "{\"type\":\"error\",\"message\":\"Missing target.\"}");
    return;
  }
  if (to.equalsIgnoreCase(caller->user)) {
    sendTxt(num, "{\"type\":\"error\",\"message\":\"You cannot call yourself.\"}");
    return;
  }
  if (caller->callWith != 0) {
    sendTxt(num,
            "{\"type\":\"line_busy\",\"message\":\"Please wait, the user is on another call.\"}");
    return;
  }

  Peer *callee = peerByUser(to);
  if (callee == nullptr) {
    sendTxt(num, String("{\"type\":\"peer_unavailable\",\"message\":\"") + to +
                  " is not online.\"}");
    return;
  }
  if (callee->callWith != 0 || callee->ringing) {
    // >>> THE BUSY-LINE FEATURE <<<
    LOGF("[call] %s -> %s BUSY\n", caller->user, callee->user);
    sendTxt(num,
            "{\"type\":\"line_busy\",\"message\":\"Please wait, the user is on another call.\"}");
    return;
  }

  caller->ringing   = true;
  caller->ringSince = millis();
  callee->ringing   = true;
  callee->ringSince = millis();

  LOGF("[call] %s -> %s ringing\n", caller->user, callee->user);
  sendTxt(num, String("{\"type\":\"call_ringing\",\"to\":\"") + callee->user + "\"}");
  sendTxt(callee->num,
          String("{\"type\":\"incoming_call\",\"from\":\"") + caller->user +
          "\",\"id\":" + String(caller->id) + "}");
}

static void handleAccept(uint8_t num, const String &from, const String &to) {
  Peer *callee = peerByNum(num);
  Peer *caller = peerByUser(to);
  if (callee == nullptr || caller == nullptr) {
    // Caller vanished while we were ringing.
    if (callee != nullptr) {
      clearCall(callee, false, nullptr);
      sendTxt(num, "{\"type\":\"call_ended\",\"message\":\"Caller is no longer available.\"}");
    }
    return;
  }
  if (!callee->ringing || !caller->ringing) {
    sendTxt(num, "{\"type\":\"error\",\"message\":\"No ringing call to accept.\"}");
    return;
  }

  caller->callWith = callee->id;
  callee->callWith = caller->id;
  caller->ringing  = false;
  callee->ringing  = false;

  LOGF("[call] %s <-> %s bridged\n", caller->user, callee->user);
  sendTxt(caller->num,
          String("{\"type\":\"call_answered\",\"from\":\"") + callee->user +
          "\",\"id\":" + String(callee->id) + "}");
}

static void handleReject(uint8_t num, const String &from, const String &to) {
  Peer *callee = peerByNum(num);
  Peer *caller = peerByUser(to);
  if (caller != nullptr) {
    caller->ringing = false;
    caller->callWith = 0;
    sendTxt(caller->num,
            String("{\"type\":\"call_rejected\",\"from\":\"") +
            (callee ? callee->user : String("peer")) + "\"}");
  }
  if (callee != nullptr) {
    callee->ringing = false;
    callee->callWith = 0;
  }
  LOGF("[call] rejected (%s)\n", from.c_str());
}

static void handleEnd(uint8_t num, const String &from) {
  Peer *p = peerByNum(num);
  if (p == nullptr) return;
  LOGF("[call] %s hung up\n", p->user);
  clearCall(p, true, "peer_hangup");
}

// -----------------------------------------------------------------------------
// Binary audio forwarding
// -----------------------------------------------------------------------------
static void handleAudio(uint8_t num, uint8_t *payload, size_t length) {
  if (length < 2) return;                    // header + at least 1 PCM byte

  Peer *sender = peerByNum(num);
  if (sender == nullptr) {
    droppedFrames++;
    return;                                  // unregistered sockets cannot talk
  }

  const uint8_t targetId = payload[0];       // 0 = broadcast

  if (targetId == 0) {
    for (uint8_t i = 0; i < MAX_PEERS; i++) {
      if (peers[i].used && peers[i].num != num) {
        webSocketServer.sendBIN(peers[i].num, payload, length);
        forwardedFrames++;
      }
    }
    return;
  }

  Peer *target = peerById(targetId);
  if (target == nullptr) {
    droppedFrames++;
    return;
  }
  // Only bridge audio between two peers that are actually in a call with each
  // other; this stops a malicious/buggy client from injecting audio anywhere.
  if (sender->callWith != target->id || target->callWith != sender->id) {
    droppedFrames++;
    return;
  }

  webSocketServer.sendBIN(target->num, payload, length);
  forwardedFrames++;
}

// -----------------------------------------------------------------------------
// WebSocket events
// -----------------------------------------------------------------------------
static void onWebSocketEvent(uint8_t num, WStype_t type, uint8_t *payload,
                             size_t length) {
  switch (type) {
    case WStype_CONNECTED: {
      LOGF("[ws] client %u connected (%u total)\n", num,
           webSocketServer.connectedClients());
      Peer *slot = peerByNum(num);
      if (slot == nullptr) slot = freeSlot();
      if (slot != nullptr) {
        // Reserve the slot so audio can be rejected until `register` arrives.
        slot->used     = true;
        slot->num      = num;
        slot->id       = 0;
        slot->ringing  = false;
        slot->callWith = 0;
        slot->user[0]  = '\0';
        slot->lastSeen = millis();
      }
      break;
    }

    case WStype_DISCONNECTED: {
      Peer *p = peerByNum(num);
      if (p != nullptr) {
        LOGF("[ws] client %u (%s) disconnected\n", num, p->user);
        if (p->callWith != 0) {
          clearCall(p, true, "connection_lost");
        } else {
          // Was ringing: free the partner too.
          Peer *partner = nullptr;
          for (uint8_t i = 0; i < MAX_PEERS; i++) {
            if (peers[i].used && peers[i].ringing && peers[i].num != num) {
              partner = &peers[i];
              break;
            }
          }
          if (partner != nullptr && p->user[0] != '\0') {
            partner->ringing = false;
            sendTxt(partner->num,
                    String("{\"type\":\"call_ended\",\"from\":\"") + p->user +
                    "\",\"message\":\"Caller disconnected.\"}");
          }
          p->ringing = false;
        }
        p->used     = false;
        p->id       = 0;
        p->callWith = 0;
        p->user[0]  = '\0';
      }
      break;
    }

    case WStype_TEXT: {
      if (payload == nullptr || length == 0) break;
      String msg;
      msg.reserve(length + 1);
      for (size_t i = 0; i < length; i++) msg += (char)payload[i];

      const String type = jsonField(msg, "type");
      const String from = jsonField(msg, "from");
      const String to   = jsonField(msg, "to");

      Peer *p = peerByNum(num);
      if (p != nullptr) p->lastSeen = millis();

      if (type == "register")        handleRegister(num, from);
      else if (type == "make_call")  handleMakeCall(num, from, to);
      else if (type == "call_accept" || type == "answer_call") handleAccept(num, from, to);
      else if (type == "call_reject" || type == "reject_call") handleReject(num, from, to);
      else if (type == "end_call"    || type == "hangup")      handleEnd(num, from);
      else if (type == "ping")       sendTxt(num, "{\"type\":\"pong\"}");
      else {
        LOGF("[ws] unknown frame from %u: %s\n", num, msg.c_str());
        sendTxt(num, "{\"type\":\"error\",\"message\":\"Unknown frame type.\"}");
      }
      break;
    }

    case WStype_BIN:
      handleAudio(num, payload, length);
      break;

    case WStype_ERROR:
      LOGF("[ws] error on client %u\n", num);
      break;

    default:
      break;
  }
}

// -----------------------------------------------------------------------------
// Housekeeping: ring timeouts, idle sockets, call consistency
// -----------------------------------------------------------------------------
static void housekeeping() {
  const uint32_t now = millis();
  for (uint8_t i = 0; i < MAX_PEERS; i++) {
    Peer &p = peers[i];
    if (!p.used) continue;

    if (p.ringing && now - p.ringSince > RING_TIMEOUT_MS) {
      LOGF("[call] ring timeout for %s\n", p.user);
      p.ringing = false;
      // Cancel the partner's ring as well.
      for (uint8_t j = 0; j < MAX_PEERS; j++) {
        if (peers[j].used && peers[j].ringing && peers[j].num != p.num) {
          peers[j].ringing = false;
          sendTxt(peers[j].num, "{\"type\":\"call_ended\",\"message\":\"No answer.\"}");
          break;
        }
      }
    }

    if (p.callWith != 0 && peerById(p.callWith) == nullptr) {
      p.callWith = 0;                        // partner vanished
      p.ringing  = false;
    }

    if (now - p.lastSeen > IDLE_TIMEOUT_MS && !webSocketServer.clientIsConnected(p.num)) {
      p.used     = false;
      p.id       = 0;
      p.callWith = 0;
      p.user[0]  = '\0';
    }
  }
}

// -----------------------------------------------------------------------------
// Setup / loop
// -----------------------------------------------------------------------------
void setup() {
#if DEBUG_SERIAL
  Serial.begin(115200);
  delay(200);
#endif
  memset(peers, 0, sizeof(peers));

  WiFi.mode(WIFI_AP);
  const bool ok = (strlen(AP_PASSWORD) >= 8)
                      ? WiFi.softAP(AP_SSID, AP_PASSWORD)
                      : WiFi.softAP(AP_SSID);
  (void)ok;   // only reported by the serial log
  LOGF("\n[ap] %s  ip=%s  (%s)\n", AP_SSID,
       WiFi.softAPIP().toString().c_str(), ok ? "ok" : "FAILED");

  webSocketServer.begin();
  webSocketServer.onEvent(onWebSocketEvent);
  LOGF("[ws] listening on ws://%s:%u\n",
       WiFi.softAPIP().toString().c_str(), WS_PORT);
  LOGF("[ws] join \"%s\" / \"%s\" then open the app\n", AP_SSID, AP_PASSWORD);
}

void loop() {
  webSocketServer.loop();

  static uint32_t lastHousekeeping = 0;
  const uint32_t now = millis();
  if (now - lastHousekeeping > 1000) {
    lastHousekeeping = now;
    housekeeping();
#if DEBUG_SERIAL
    Serial.printf("[stat] peers=%u fwd=%lu drop=%lu heap=%u\n",
                  webSocketServer.connectedClients(),
                  (unsigned long)forwardedFrames,
                  (unsigned long)droppedFrames,
                  (unsigned)ESP.getFreeHeap());
#endif
  }
  yield();
}
