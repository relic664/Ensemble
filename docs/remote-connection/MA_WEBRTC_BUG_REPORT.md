# WebRTC Data Channel Failure on Android - Bug Report

## Summary

When connecting to Music Assistant via WebRTC remote access (Nabu Casa), the `ma-api` data channel becomes **one-way** (can send, cannot receive) after 1-3 minutes of use, while the `sendspin` channel continues working normally.

## Environment

- **MA Server**: 2.8.0b7 (Home Assistant add-on)
- **Client**: Android app (Flutter) connecting via Nabu Casa remote access
- **Remote Access**: WebRTC via `wss://signaling.music-assistant.io/ws`

## Reproduction Steps

1. Connect to MA server via WebRTC remote access (not local network)
2. Use the app normally - browse library, view players
3. After 1-3 minutes, the connection degrades
4. Commands time out, but signaling ping/pong continues working

## Observed Behavior

### Timeline from logs:

```
07:14:20 - Working normally
           Health: API sent:51 recv:54 (balanced)

07:15:57 - Receive stops
           Health: API sent:97 recv:97, lastRecv:12s ago

07:16:02 - Timeouts begin
           "TimeoutException: Command timeout: players/all"

07:16:17 - Sendspin still works!
           "Sendspin: Received server/time response"
           Health: API sent:114 recv:97, lastRecv:27s ago

07:17:30 - Forced reconnect
           Health: API sent:137 recv:97, lastRecv:42s ago
           "Health check detected stale connection"
```

### Key Observation

| Channel | Traffic Pattern | Status |
|---------|-----------------|--------|
| `ma-api` | High (10+ msg/s, large payloads) | **FAILS** - stops receiving |
| `sendspin` | Low (~1 msg/5s, small payloads) | **SURVIVES** - continues working |
| Signaling | Ping/pong every 15s | **SURVIVES** - continues working |

The WebRTC peer connection remains in "connected" state. ICE connection shows "completed". Only the ma-api data channel stops receiving.

## Testing Performed

### Test 1: flutter_webrtc (Native WebRTC)
- **Result**: ma-api channel dies after 1-3 minutes
- **Sendspin**: Continues working

### Test 2: WebView-based WebRTC (Browser engine)
- **Hypothesis**: Use Android WebView's browser-native WebRTC, since MA Web UI works
- **Implementation**: Hidden InAppWebView running JavaScript WebRTC engine
- **Result**: **Same failure mode** - ma-api dies, sendspin survives
- **Conclusion**: Not a flutter_webrtc bug

### Test 3: Various Data Channel Settings
- Tried `ordered: false` with `maxRetransmits: 3`
- Tried letting server create channels (failed - server expects client to create)
- No improvement

## Analysis

The identical failure in both native and WebView WebRTC implementations suggests the issue is:

1. **Server-side** - Different handling of ma-api vs sendspin channels
2. **TURN relay** - High-traffic channel may hit limits
3. **Not client-specific** - Both implementations fail identically

### Questions for MA Team

1. Are the two data channels (`ma-api`, `sendspin`) created with different settings?
2. Is there any server-side buffering or rate limiting that could affect high-traffic channels?
3. Does the MA Web UI use different data channel configurations?
4. Are there known issues with the TURN relay for sustained high-traffic channels?

## Comparison: MA Web UI vs Android App

| Aspect | MA Web UI | Android App |
|--------|-----------|-------------|
| Platform | Browser tab (visible, active) | Background-capable app |
| WebRTC | Browser native | flutter_webrtc / WebView |
| Result | Works | Fails after 1-3 min |

The MA Web UI runs in a **visible, active browser tab**. Android may throttle background apps differently, but this doesn't explain why sendspin survives while ma-api dies on the same connection.

## Logs

### Health Check Pattern (shows channel death)
```
07:14:25 API sent:51 recv:54, lastRecv:2s ago   <- Working
07:15:35 API sent:87 recv:91, lastRecv:2s ago   <- Working
07:16:05 API sent:108 recv:97, lastRecv:17s ago <- DYING (gap growing)
07:16:15 API sent:114 recv:97, lastRecv:27s ago <- DEAD
07:16:45 API sent:130 recv:97, lastRecv:27s ago <- Still sending, no receive
07:17:30 API sent:137 recv:97, lastRecv:42s ago <- Forced reconnect
```

### Sendspin Still Working During Failure
```
07:16:17 Sendspin: Received server/time response  <- Still alive!
07:16:47 Sendspin: Received server/time response  <- Still alive!
```

## Requested Information

1. Data channel creation code/settings for both channels
2. Any server-side differences in channel handling
3. TURN server configuration details
4. Whether this has been reported by other Android/mobile clients

## Workaround

Currently using local WebSocket connection when on same network. Remote access via WebRTC is unusable for sustained use.

---

**Reporter**: Ensemble Android App Developer
**Date**: 2026-01-24
