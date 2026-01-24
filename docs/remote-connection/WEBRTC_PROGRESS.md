# WebRTC Remote Connection Progress

## Problem Statement
The flutter_webrtc library has reliability issues causing data channel failures during remote connections via Nabu Casa. The ma-api data channel becomes one-way (can send, but receives stop) after some time, while the sendspin channel continues working.

## Approaches Tried

### 1. Original Implementation (flutter_webrtc)
- **Status**: Fails
- **Issue**: ma-api data channel goes one-way after some time
- **Files**: `lib/services/remote/webrtc_connection.dart`

### 2. WebView-based WebRTC Implementation
- **Status**: Same failure mode
- **Hypothesis**: Use browser-native WebRTC via InAppWebView, since MA Web UI works
- **Result**: Same one-way channel death occurs
- **Key Finding**: This proves the issue is NOT specific to flutter_webrtc

## Key Observations

From the logs:
```
lastRecv:26s ago          <- No messages received in 26 seconds
API sent:674 recv:618     <- Gap growing, responses stopped
```

- Signaling ping/pong continues working
- Sendspin channel continues receiving (`server/time` responses)
- Only ma-api channel becomes one-way
- WebRTC peer connection itself remains "connected"

## Differences from Working MA Web UI

The MA Web UI runs in a **visible, active browser tab**. Our implementations:
1. flutter_webrtc: Native WebRTC in background app
2. WebView: Browser WebRTC in **hidden 1x1 pixel WebView**

Android aggressively throttles hidden WebViews to save battery.

## Current Implementation (WebView)

### Files Created
| File | Purpose |
|------|---------|
| `lib/services/remote/webview_webrtc_connection.dart` | Dart WebView wrapper |
| `assets/webrtc_engine.js` | JavaScript WebRTC engine |

### Files Modified
| File | Changes |
|------|---------|
| `pubspec.yaml` | Added `flutter_inappwebview: ^6.0.0` |
| `lib/services/remote/remote_bridge.dart` | Uses `WebViewWebRTCConnection` |
| `lib/providers/music_assistant_provider.dart` | Exposes WebView widget |
| `lib/main.dart` | Adds WebView to widget tree |

### Architecture
```
MusicAssistantAPI -> localhost WebSocket -> RemoteBridge
                                              |
                                   WebViewWebRTCConnection
                                              |
                                   Hidden InAppWebView
                                              |
                                   JavaScript WebRTC Engine
                                              |
                                   MA Server via TURN
```

## Current Fixes Being Tested

### 1. Prevent WebView Throttling
- Changed WebView position from off-screen (-10,-10) to on-screen (0,0) with Opacity(0)
- Added various InAppWebViewSettings to prevent background throttling

### 2. Data Channel Settings
- Changed from `ordered: true` to `ordered: false` with `maxRetransmits: 3`
- Hypothesis: Ordered delivery may cause buffer bloat issues

### 3. Buffer Monitoring
- Added `bufferedAmount` checking in JavaScript
- Logs warning when buffer exceeds 1MB
- Added `getChannelHealth()` function for diagnostics

### 4. Reduced Logging
- Removed per-message logging (was filling logs too fast)
- Keep only state changes, errors, and warnings

## Experiments Completed

### 5. Server-Created Channels (Failed)
- **Hypothesis**: Let server create data channels to avoid ID collisions
- **Result**: Connection timeout - server expects CLIENT to create channels
- **Learning**: Client must create channels before sending offer

## Next Steps to Try

1. **Make WebView actually visible** - Android may still throttle Opacity(0) WebView
2. **Single data channel** - Use only ma-api, disable sendspin
3. **Periodic channel recreation** - Detect stale channel and recreate
4. **Report to MA team** - Browser WebRTC also fails, suggesting server-side issue

## Test APK Location
`/home/chris/Ensemble/ensemble-webview-webrtc.apk`

## Useful Debug Commands

Check channel health (in JS console or via Dart):
```javascript
getChannelHealth()
// Returns: { peerConnection, iceConnection, apiChannel, apiBuffered, sendspinChannel, sendspinBuffered, signalingConnected }
```

## Open Questions

1. Why does sendspin channel survive when ma-api dies?
2. Is there a difference in how MA server handles the two channels?
3. Does MA Web UI use different data channel settings?
4. Is there a TURN relay issue specific to high-traffic channels?
