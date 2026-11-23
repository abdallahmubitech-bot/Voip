# Wire protocol — ESP32 WebSocket router

One TCP/WebSocket connection per handset carries **three** kinds of traffic:
registration, call signalling, and raw PCM audio. Keep that in mind when writing
the firmware: a single `WebSocketsClient` per peer.

- URL: `ws://192.168.4.1:81` (SoftAP gateway address, port is configurable in the app)
- Text frames: UTF-8 JSON control signals
- Binary frames: raw audio packets (never JSON, never base64)
- Server-side ping interval: 10 s (the app also lets `web_socket_channel` ping)

## 1. Registration

| Direction | Frame |
| --- | --- |
| app → router | `{"type":"register","from":"User_A"}` |
| router → app (ok) | `{"type":"registered","from":"User_A","id":3}` |
| router → app (fail) | `{"type":"error","message":"Username already taken"}` |

`id` is the **routing byte** (0–255, 0 reserved for broadcast). The router must
echo it in every call signal so both sides can prefix outbound audio frames.

## 2. Call signalling

| Direction | Frame | Meaning |
| --- | --- | --- |
| app → router | `{"type":"make_call","from":"User_A","to":"User_B"}` | dial |
| router → caller | `{"type":"call_ringing","to":"User_A"}` | optional ack |
| router → callee | `{"type":"incoming_call","from":"User_A","id":3}` | ring `User_B` |
| callee → router | `{"type":"call_accept","from":"User_B","to":"User_A"}` | answer |
| router → caller | `{"type":"call_answered","from":"User_B","id":5}` | bridge audio |
| callee → router | `{"type":"call_reject","from":"User_B","to":"User_A"}` | decline |
| either → router | `{"type":"end_call","from":"User_A","to":"User_B"}` | hang up |
| router → peer | `{"type":"call_ended","from":"User_A"}` | peer hung up |
| router → caller | `{"type":"line_busy","message":"Please wait, the user is on another call."}` | **busy line** |
| router → caller | `{"type":"peer_unavailable","message":"User_B is not online."}` | unknown/offline user |
| router → app | `{"type":"error","message":"..."}` | anything else |

Rules the app relies on:

1. `line_busy` **must** be sent to the *caller* when the callee is already
   bridged in a call. The app stops its ringback tone and shows a blocking
   dialog with the router's `message` (falling back to the canonical string).
2. `call_answered` and `incoming_call` **must** carry the peer's `id`; without
   it the receiver cannot address outbound audio and ends the call with an
   explicit error instead of streaming into the void.
3. Any other `type` is ignored gracefully, so the firmware can add signals
   without breaking older builds.

## 3. Binary audio packets

```text
 byte 0        byte 1 .. N
┌───────────┬──────────────────────────────────────────┐
│ targetId  │  PCM 16-bit signed little-endian, mono   │
└───────────┴──────────────────────────────────────────┘
```

| Parameter | Value |
| --- | --- |
| Sample rate | 16 000 Hz |
| Channels | 1 (mono) |
| Bit depth | 16-bit signed LE |
| Frame duration | 40 ms |
| Payload per frame | **1280 bytes** |
| Packet on the wire | 1281 bytes (1-byte header + payload) |
| Bitrate (one direction) | 256 kbps ≈ 32 kB/s |

The router strips the header and writes the payload to the peer's socket; the
receiver may keep the header (the app checks it and discards frames addressed to
someone else, treating `0` as broadcast).

## 4. Suggested firmware sketch (Arduino-ESP32)

```cpp
// Pseudocode — routing table keyed by the routing id, 1 byte header.
struct Peer { WebSocketsServer* ws; uint8_t num; uint8_t id; bool busy; String user; };
Peer peers[MAX_PEERS];

void onText(uint8_t num, String msg) {
  JsonDocument doc; deserializeJson(doc, msg);
  String type = doc["type"];
  if (type == "register")   { peers[num].user = doc["from"]; peers[num].id = allocateId(num);
                              sendTo(num, "{\"type\":\"registered\",\"from\":\"" + peers[num].user + "\",\"id\":" + String(peers[num].id) + "}"); }
  else if (type == "make_call") {
      Peer* b = findByUser(doc["to"]);
      if (!b)      sendTo(num, "{\"type\":\"peer_unavailable\",\"message\":\"User is not online.\"}");
      else if (b->busy) sendTo(num, "{\"type\":\"line_busy\",\"message\":\"Please wait, the user is on another call.\"}");
      else { b->busy = true; peers[num].busy = true;
             sendTo(b->num, "{\"type\":\"incoming_call\",\"from\":\"" + peers[num].user + "\",\"id\":" + String(peers[num].id) + "}");
             sendTo(num,    "{\"type\":\"call_ringing\"}"); }
  }
  else if (type == "call_accept") { /* mark bridged; inform caller with call_answered + callee id */ }
  else if (type == "call_reject" || type == "end_call") { /* clear busy flags, notify peer */ }
}

void onBinary(uint8_t num, uint8_t* payload, size_t len) {
  uint8_t targetId = payload[0];
  Peer* p = findById(targetId);
  if (p) p->ws->sendBIN(p->num, payload, len); // header included, receiver checks it
}
```

## 5. Latency budget (one direction)

```text
 capture block (10–20 ms) → chunker (≤40 ms) → Wi-Fi (~5–15 ms) → jitter buffer (120 ms) → speaker
 ≈ 150–200 ms mouth-to-ear on a healthy 2.4 GHz link
```
