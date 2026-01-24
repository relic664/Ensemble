# WebRTC Data Channel Disconnect Fixes

## Document Purpose
Track all fixes attempted for the WebRTC data channel disconnection issues in Ensemble's remote connection feature. This document should be referenced when debugging future disconnection problems.

---

## Problem Summary

The WebRTC data channel between the Ensemble mobile app and Music Assistant server can fail in several ways:

1. **One-way failure**: Data channel appears "open" but only sends work, receives stop
2. **Silent disconnect**: No error events fire, channel just stops working
3. **ICE failure**: ICE connection fails, properly detected but causes disconnect
4. **Signaling disconnect**: Signaling WebSocket closes, causing ICE/WebRTC to fail

---

## Key Files

| File | Purpose |
|------|---------|
| `lib/services/remote/webrtc_connection.dart` | WebRTC peer connection, data channel management |
| `lib/services/remote/remote_bridge.dart` | WebSocket bridge, health monitoring, reconnection logic |
| `lib/services/remote/signaling_client.dart` | Signaling server WebSocket connection |

---

## Implemented Fixes (Chronological)

### Fix 1: Data Channel Keepalive (Original)
**Problem**: Data channel could silently die without any error events firing.

**Solution**: Added periodic keepalive ping/pong on the data channel itself.

**Code** (`webrtc_connection.dart`):
- `_keepaliveTimer`: Runs every 10 seconds
- `_checkKeepalive()`: Checks time since last data received
- `_sendKeepalivePing()`: Sends JSON ping message
- `_recordDataReceived()`: Called on every message receipt

**Constants**:
```dart
static const _keepaliveInterval = Duration(seconds: 10);
static const _keepaliveTimeout = Duration(seconds: 20);  // Reduced from 30
static const _maxKeepaliveMisses = 2;  // Reduced from 3
```

### Fix 2: ICE Recovery
**Problem**: ICE connection could temporarily disconnect and might auto-recover.

**Solution**: Added ICE recovery timer before declaring failure.

**Code** (`webrtc_connection.dart`):
- `_startIceRecovery()`: Starts 5-second timer when ICE disconnects
- `_cancelIceRecovery()`: Cancels if ICE recovers on its own
- `_attemptIceRestart()`: Calls `restartIce()` if recovery timer expires

### Fix 3: Flow Control (Buffer Overflow Prevention)
**Problem**: Fire-and-forget sends could overflow the 16MB SCTP buffer, causing silent channel death.

**Solution**: Added send-side flow control with buffering.

**Code** (`webrtc_connection.dart`):
```dart
static const _maxBufferedAmount = 1048576;  // 1MB threshold
static const _bufferLowThreshold = 65536;   // 64KB resume threshold
bool _sendPaused = false;
final _sendQueue = <String>[];
```

**Modified `sendRaw()`**:
- Checks `bufferedAmount` before sending
- Queues messages if buffer > 1MB
- `onBufferedAmountLow` callback drains queue

### Fix 4: Health Check Stale Detection
**Problem**: Health check could see "30s since last data" but not trigger reconnection.

**Solution**: Reduced stale detection threshold from 45s to 30s.

**Code** (`remote_bridge.dart`):
```dart
if (_state == RemoteBridgeState.connected && timeSinceLastData > 30 && !_isReconnecting) {
  // Force reconnection
}
```

### Fix 5: Reduced Keepalive Timeouts
**Problem**: 30s timeout × 3 misses = 90s minimum before detection.

**Solution**: Reduced to 20s timeout × 2 misses = ~40s detection.

### Fix 6: Recv Stagnation Detection
**Problem**: One-way failure where recv stops but sent continues not detected quickly enough.

**Solution**: Track recv count across health checks. If recv stuck while sent increases for 2 consecutive checks (20s), force reconnection.

**Code** (`remote_bridge.dart`):
```dart
// Track across health checks
int _lastHealthCheckRecvCount = 0;
int _lastHealthCheckSentCount = 0;
int _recvStagnationCount = 0;

// In health check:
if (recvStuck && sentIncreased) {
  _recvStagnationCount++;
  if (_recvStagnationCount >= 2) {
    // Force reconnection - channel is one-way
  }
}
```

**Detection time**: ~20 seconds (2 × 10s health check interval)

---

## Log Patterns to Watch For

### Healthy Connection
```
Health check - API sent:93 recv:88 ... lastRecv:0s ago
```
- `sent` and `recv` both increasing
- `lastRecv` low (< 5s typically)

### One-Way Failure (CRITICAL)
```
Health check - API sent:206 recv:163 ... lastRecv:30s ago
Health check - API sent:218 recv:163 ... lastRecv:40s ago
```
- `sent` increases, `recv` STUCK
- `lastRecv` keeps increasing
- Data channel still shows "open"

### Signaling Disconnect
```
WebRTC: Signaling disconnected
... (6-16 seconds later) ...
WebRTC: ICE connection state: RTCIceConnectionStateDisconnected
WebRTC: ICE connection state: RTCIceConnectionStateFailed
```

### Network Failure (DNS)
```
Signaling: WebSocket closed
... (reconnection attempt) ...
Signaling: Failed to connect: SocketException: Failed host lookup: 'signaling.music-assistant.io'
```
This indicates the phone lost network connectivity entirely.

### Reconnection Storm (Signaling Instability)
```
Signaling: Connecting to wss://signaling.music-assistant.io/ws
Signaling: Sending connect-request
Signaling: WebSocket closed  ← Closes within 100-500ms
WebRTC: Signaling disconnected
RemoteBridge: Scheduling reconnect attempt X/10 in Ys
```
Rapid reconnection loop - signaling never stays connected long enough.

### Flow Control Engaged
```
WebRTC: ⚠️ Buffer full (1234567 bytes) or paused - queueing message
WebRTC: Buffer drained to 12345 bytes - draining 5 queued messages
WebRTC: ✅ Send queue drained (5 messages) - resuming normal sends
```

### Keepalive Detection
```
WebRTC: ⚠️ Keepalive timeout! No data for 22s (missed: 1/2)
WebRTC: ❌ Data channel appears dead - triggering reconnection
```

---

## Known Issues / Limitations

### 1. flutter_webrtc Limitations
- `RTCDataChannel.state` may show "open" when actually dead (Issue #843)
- `bufferedAmount` may not be accurate on all platforms
- `onBufferedAmountLow` callback support varies

### 2. SCTP Receive Window
- If server sends faster than client processes, receive window fills
- This causes server-side to stop sending, client sees no data
- No way to monitor receive-side buffer from client

### 3. TURN Server Issues
- aiortc (server-side) has known issues with TURN + DataChannel (#1156)
- Data channel may fail silently when using TURN relay

### 4. Network Transitions
- WiFi → Cellular or vice versa can cause ICE to fail
- App backgrounding on mobile can close WebSocket/WebRTC

---

## Root Cause Categories

### Category A: Network Issues (Not Code Bugs)
These are environmental issues, not bugs in our code:
- **DNS failure**: `Failed host lookup` - Phone lost internet
- **WiFi/Cellular switch**: Network changed, connections dropped
- **Server unreachable**: Signaling server down or blocked
- **Firewall/NAT issues**: TURN relay needed but unavailable

**Evidence**: Signaling WebSocket closes, DNS lookups fail, reconnection attempts fail repeatedly.

### Category B: WebRTC/SCTP Issues (Partial Code Control)
These can be mitigated but not fully prevented:
- **One-way channel death**: Channel appears open but data stops flowing
- **Buffer overflow**: Too much data sent, SCTP buffer exceeded
- **ICE failure**: Network path lost, no recovery possible

**Evidence**: Data channel shows "open" but `recv` stuck, `lastRecv` increasing.

### Category C: Code Bugs (Fixable)
Issues in our implementation:
- **Detection too slow**: Timeouts too long, misses too many
- **Recovery not triggered**: State checks wrong, reconnection not started
- **Resource leaks**: Timers not cancelled, connections not cleaned up

**Evidence**: Logs show problem but no action taken, or wrong action taken.

---

## Debugging Checklist

When investigating a disconnect:

1. **Find the last successful response**:
   ```
   grep "WebRTC API → WS" logs.txt | head -5
   ```

2. **Check health check progression**:
   ```
   grep "Health check" logs.txt
   ```
   Look for `recv` getting stuck while `sent` increases.

3. **Check for signaling issues**:
   ```
   grep -i "signaling" logs.txt
   ```

4. **Check ICE state changes**:
   ```
   grep "ICE connection state" logs.txt
   ```

5. **Check for keepalive detection**:
   ```
   grep -i "keepalive" logs.txt
   ```

6. **Check buffer status**:
   ```
   grep -E "(buffer|queue|paused)" logs.txt
   ```

---

## Potential Future Improvements

### 1. Server-Side Backpressure
MA protocol doesn't have explicit backpressure. Could add:
- Client-side request throttling
- Application-level ACKs for critical messages

### 2. More Aggressive Detection
- Track recv count across health checks, detect stagnation
- Shorter keepalive interval (5s instead of 10s)

### 3. Proactive Health Signals
- Monitor `bufferedAmount` trend (increasing = problem)
- Track round-trip latency of keepalive pings

### 4. Connection Quality Metrics
- Expose packet loss, jitter from WebRTC stats
- Use to predict imminent failure

---

## Test Scenarios

| Scenario | How to Test | Expected Behavior |
|----------|-------------|-------------------|
| Normal usage | Browse library, play music | No warnings |
| Heavy sync | Pull-to-refresh library | Buffer may queue, should drain |
| Long session | Leave connected 2+ hours | Should stay connected |
| Rapid navigation | Quick tab switching | Brief queue usage, recovers |
| Network change | WiFi → Cellular | Should detect and reconnect |
| App background | Background for 5+ min | May disconnect, should reconnect |

---

## Observed Failure Patterns

### Pattern 1: One-Way Death After Library Sync
**Observed**: 2026-01-23 (multiple times)

```
17:13:06.175 - Last response (playlists sync)
17:13:06.264 - Local batch save
-- 5 seconds silence --
17:13:11.005 - Send players/all → NO RESPONSE
17:13:13.914 - ICE state: completed (looks healthy!)
17:13:28 - Keepalive detects timeout
17:13:38 - Reconnection triggered
```

**Characteristics**:
- Often happens after library sync (large batch responses)
- ICE shows "completed" even though data channel is dead
- Signaling ping/pong continues working
- Only data channel receive is affected

**Hypothesis**:
- Server-side SCTP buffer exhausted from sending large responses?
- Client receive window full, server blocks?
- flutter_webrtc onMessage callback stops firing?

### Pattern 2: Reconnection Storm / Signaling Instability
**Observed**: 2026-01-23 17:30-17:31

```
17:31:05.093 - Signaling: Connecting
17:31:05.216 - Signaling: Sending connect-request
17:31:05.218 - Signaling: WebSocket closed (123ms later!)
17:31:05.218 - WebRTC: Signaling disconnected
```

**Characteristics**:
- Signaling WebSocket closes almost immediately after connect
- Multiple rapid reconnection attempts (storm)
- Connection never stable long enough for data flow
- Often happens after network instability
- Artist detail, albums etc don't load because connection keeps failing

**Possible Causes**:
- Network instability (WiFi/cellular issues)
- Signaling server rate limiting
- DNS resolution failures
- Server rejecting rapid reconnection attempts

**Side Effects**:
- UI shows errors like "Not connected to Music Assistant server"
- Artist/album detail screens fail to load
- Players list empty or stale

### Pattern 3: API Channel Dies While Sendspin Lives
**Observed**: 2026-01-23 17:53

```
17:53:35.755 - Send album_tracks request → NO RESPONSE
17:53:40.596 - Health check: recv stuck at 197, sent increased
17:53:55.204 - Sendspin channel RECEIVES server/time response!
17:54:02.790 - Keepalive detects dead API channel
```

**Characteristics**:
- API data channel (ma-api) stops receiving
- Sendspin data channel continues working normally
- Same WebRTC peer connection, different data channels
- This proves it's NOT a network issue - Sendspin traffic flows fine

**Hypothesis**:
- flutter_webrtc bug where `onMessage` callback stops firing for one channel
- Possible memory/GC issue with the callback
- Server-side might be sending to wrong channel?

**Key Evidence**:
- Recv count stays at 197 for API
- Sendspin recv count increases (7→8)
- Both channels use same peer connection

---

## Version History

| Date | Build | Changes |
|------|-------|---------|
| 2026-01-23 | ~v49 | Initial flow control implementation |
| 2026-01-23 | ~v49 | Reduced keepalive timeout 30→20s, misses 3→2 |
| 2026-01-23 | ~v49 | Reduced health check stale threshold 45→30s |
| 2026-01-23 | ~v49 | Fixed excessive "queue drained" logging |
| 2026-01-23 | ~v49 | Created WEBRTC_DISCONNECT_FIXES.md documentation |
| 2026-01-23 | ~v49 | Added recv stagnation detection (20s detection) |
| 2026-01-23 | ~v49 | Documented Pattern 2: Reconnection storm / signaling instability |
| 2026-01-23 | ~v49 | Fixed race condition in _scheduleReconnect (multiple simultaneous calls) |
| 2026-01-23 | ~v49 | Added WebSocket close code/reason logging to signaling |
| 2026-01-23 | ~v49 | **CRITICAL FIX**: _reconnectWebRTC() was returning immediately due to _isReconnecting already being true |
| 2026-01-23 | ~v49 | Fixed old WebRTC callbacks firing during reconnection cleanup (clear callbacks before disconnect) |
| 2026-01-23 | ~v49 | Fixed onStateChanged handler calling _handleWebRTCDisconnection during active reconnection |

---

## References

- flutter_webrtc Issue #843: Data channel state unreliable
- aiortc Issue #1156: TURN + DataChannel bugs
- WebRTC SCTP: Max buffer is 16MB, recommended threshold 1MB
- Music Assistant remote protocol: No explicit flow control
