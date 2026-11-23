# ESP32 call router firmware

`esp32_voip_router/esp32_voip_router.ino` — the WebSocket routing server the
Flutter app talks to. It pairs with `docs/protocol.md` in the app repository.

## What it implements

| Concern | Implementation |
| --- | --- |
| Network | Raises its own SoftAP (`ESP32-VOIP` / `voip12345`), so no external router is needed |
| Transport | `WebSocketsServer` on port **81**, one socket per handset, up to 8 peers |
| Registration | `username → routing id` (1–254, `0` = broadcast); a reconnecting username **takes over** its identity and the stale socket is closed |
| Routing | Binary frames forwarded verbatim to the `targetId` in byte 0 |
| Busy line | `line_busy` returned to the caller when the callee is already `ringing` or bridged |
| Bridging | `call_accept` links both peers and returns `call_answered` with the callee's routing id |
| Cleanup | 45 s ring timeout, call teardown on socket loss, partner notification |
| Safety | Audio is only forwarded between two peers that are bridged with *each other* |
| No JSON lib | A ~30-line field extractor reads `type` / `from` / `to`, so the sketch can't break on ArduinoJson 6 vs 7 |

## Library

Install via **Tools → Manage Libraries**:

- **WebSockets** by Markus Sattler (`Links2004/arduinoWebSockets`)

`WiFi.h` ships with the ESP32 core. Board: **ESP32 Dev Module** (any Wi-Fi ESP32).

## Flash & run

1. Open `esp32_voip_router/esp32_voip_router.ino` in the Arduino IDE
   (the folder name must match the sketch name — it does).
2. Select your ESP32 board and port, then Upload.
3. Open the Serial Monitor at **115200**. You should see:

   ```
   [ap] ESP32-VOIP  ip=192.168.4.1  (ok)
   [ws] listening on ws://192.168.4.1:81
   [stat] peers=0 fwd=0 drop=0 heap=...
   ```

4. On each handset: join Wi-Fi **ESP32-VOIP** / `voip12345`, then open the app and
   register a username. Run the app with the default URL
   (`ws://192.168.4.1:81`) — no `--dart-define` needed.

Live log during a call:

```
[reg] socket 2 -> User_A (id=1)
[reg] socket 3 -> User_B (id=2)
[call] User_A -> User_B ringing
[call] User_A <-> User_B bridged
[stat] peers=2 fwd=1250 drop=0 heap=180000   # ~50 frames/s per direction
```

## Endpoints & tuning

Everything worth changing is a `#define` / `static const` at the top of the sketch:

| Constant | Default | Purpose |
| --- | --- | --- |
| `AP_SSID` / `AP_PASSWORD` | `ESP32-VOIP` / `voip12345` | SoftAP credentials (≥ 8 chars, or `""` for open) |
| `WS_PORT` | `81` | Must match the app's `VOIP_SERVER_URL` |
| `MAX_PEERS` | `8` | Concurrent handsets |
| `RING_TIMEOUT_MS` | `45000` | Matches the app's 45 s ring timer |
| `IDLE_TIMEOUT_MS` | `120000` | Reap half-dead sockets |
| `DEBUG_SERIAL` | `1` | Set `0` for silence |

## Field notes

- **Two handsets is the sweet spot.** Three or more concurrent *calls* will start
  to strain the SoftAP and the ESP32's ~180 kB free heap at 256 kbps/direction.
  In this build only one call per handset is possible anyway (that is what
  produces `line_busy`).
- **2.4 GHz only.** Isolate the AP channel (`WiFi.softAP(ssid, pass, channel)`)
  if neighbouring networks cause dropouts.
- **Power** the board from a proper 5 V supply; brown-outs show up as random
  socket drops mid-call.
- The default `webSocketServer` buffer handles our 1281-byte frames comfortably.
  If you raise the frame size above ~4 kB, define
  `WEBSOCKETS_MAX_DATA_SIZE` before including the library.
