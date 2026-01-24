# Remote Connection - Future Implementation Guide

## Overview

This document provides guidance for implementing remote connection to Music Assistant servers via WebRTC. Remote connection allows the Ensemble app to connect to MA servers outside the local network using Nabu Casa's WebRTC signaling infrastructure.

## Current Status: On Hold

Remote connection was partially implemented but put on hold due to a critical bug where the `ma-api` data channel becomes one-way after 1-3 minutes. See `MA_WEBRTC_BUG_REPORT.md` for details.

---

## Architecture

### How It Works

```
┌─────────────────┐     WebSocket      ┌──────────────────────────┐
│  Ensemble App   │◄──────────────────►│  MA Server (local WS)    │
└─────────────────┘                    └──────────────────────────┘
        │                                         │
        │ (when local unavailable)                │
        ▼                                         ▼
┌─────────────────┐                    ┌──────────────────────────┐
│  SignalingClient│◄──── WebSocket ───►│ signaling.music-assistant│
└─────────────────┘                    │        .io/ws            │
        │                              └──────────────────────────┘
        │ ICE candidates, SDP                     │
        ▼                                         ▼
┌─────────────────┐                    ┌──────────────────────────┐
│  WebRTC Peer    │◄═══ Data Channel ══►│  MA Server WebRTC       │
│  Connection     │    (ma-api)         │  Endpoint               │
└─────────────────┘                    └──────────────────────────┘
```

### Components

1. **SignalingClient** - WebSocket connection to `wss://signaling.music-assistant.io/ws`
2. **WebRTCConnection** - Manages RTCPeerConnection and data channels
3. **RemoteBridge** - Bridges local WebSocket API to remote WebRTC connection

### Data Channels

| Channel | Purpose | Traffic Pattern |
|---------|---------|-----------------|
| `ma-api` | JSON API requests/responses | High volume, large payloads |
| `sendspin` | Audio streaming + control | Low JSON, binary audio data |

---

## Key Files to Create/Modify

### New Files

| File | Purpose |
|------|---------|
| `lib/services/remote/signaling_client.dart` | WebSocket client for signaling server |
| `lib/services/remote/webrtc_connection.dart` | WebRTC peer connection management |
| `lib/services/remote/remote_bridge.dart` | Bridges API calls to WebRTC |

### Files to Modify

| File | Changes |
|------|---------|
| `lib/services/music_assistant_api.dart` | Add remote connection fallback |
| `lib/providers/music_assistant_provider.dart` | Expose remote connection state |
| `pubspec.yaml` | Add `flutter_webrtc` dependency |

---

## Implementation Steps

### Step 1: Add Dependencies

```yaml
# pubspec.yaml
dependencies:
  flutter_webrtc: ^0.12.0  # or latest
```

### Step 2: Implement SignalingClient

The signaling client connects to Music Assistant's signaling server and exchanges WebRTC offers/answers.

```dart
class SignalingClient {
  WebSocket? _socket;

  Future<void> connect(String serverId) async {
    _socket = await WebSocket.connect('wss://signaling.music-assistant.io/ws');

    // Send connect request
    _send({
      'type': 'connect-request',
      'server_id': serverId,
    });

    // Listen for messages
    _socket!.listen(_handleMessage);
  }

  void _handleMessage(dynamic data) {
    final message = jsonDecode(data);
    switch (message['type']) {
      case 'answer':
        onAnswer?.call(message['sdp']);
        break;
      case 'ice-candidate':
        onIceCandidate?.call(message['candidate']);
        break;
    }
  }
}
```

### Step 3: Implement WebRTCConnection

```dart
class WebRTCConnection {
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _apiChannel;
  RTCDataChannel? _sendspinChannel;

  Future<void> connect(SignalingClient signaling) async {
    // Create peer connection with STUN/TURN servers
    _peerConnection = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        // TURN servers provided by signaling
      ],
    });

    // Create data channels BEFORE creating offer
    _apiChannel = await _peerConnection!.createDataChannel(
      'ma-api',
      RTCDataChannelInit()..ordered = true,
    );

    _sendspinChannel = await _peerConnection!.createDataChannel(
      'sendspin',
      RTCDataChannelInit()..ordered = true,
    );

    // Create and send offer
    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);
    signaling.sendOffer(offer.sdp!);

    // Handle answer from server
    signaling.onAnswer = (sdp) async {
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(sdp, 'answer'),
      );
    };
  }
}
```

### Step 4: Implement RemoteBridge

The bridge translates between the local WebSocket API format and WebRTC data channel messages.

```dart
class RemoteBridge {
  final WebRTCConnection _webrtc;
  final StreamController<String> _messageController;

  void sendCommand(String json) {
    _webrtc.sendToApiChannel(json);
  }

  Stream<String> get messages => _messageController.stream;
}
```

### Step 5: Integrate with MusicAssistantAPI

```dart
class MusicAssistantAPI {
  WebSocket? _localSocket;
  RemoteBridge? _remoteBridge;

  Future<void> connect(String host, {String? serverId}) async {
    try {
      // Try local connection first
      _localSocket = await WebSocket.connect('ws://$host/ws');
    } catch (e) {
      // Fall back to remote if serverId provided
      if (serverId != null) {
        _remoteBridge = RemoteBridge();
        await _remoteBridge!.connect(serverId);
      }
    }
  }
}
```

---

## Critical Implementation Details

### 1. Channel Creation Order

The client MUST create data channels BEFORE sending the WebRTC offer. The server expects the client to create:
- `ma-api` - for API traffic
- `sendspin` - for audio streaming (optional)

### 2. Health Monitoring

Implement aggressive health checks because data channels can silently die:

```dart
// Track message counts
int _sentCount = 0;
int _recvCount = 0;
DateTime _lastRecvTime = DateTime.now();

// Health check every 10 seconds
void _healthCheck() {
  final timeSinceRecv = DateTime.now().difference(_lastRecvTime);
  if (timeSinceRecv.inSeconds > 30) {
    // Channel is dead, trigger reconnection
    _reconnect();
  }
}
```

### 3. Keepalive Messages

Send periodic keepalive on the data channel itself (not just signaling):

```dart
void _sendKeepalive() {
  _apiChannel?.send(RTCDataChannelMessage(
    jsonEncode({'type': 'ping', 'timestamp': DateTime.now().toIso8601String()}),
  ));
}
```

### 4. Flow Control

Monitor buffer to prevent overflow:

```dart
void sendMessage(String json) {
  if (_apiChannel!.bufferedAmount > 1048576) {  // 1MB
    // Queue message, don't send
    _sendQueue.add(json);
    return;
  }
  _apiChannel!.send(RTCDataChannelMessage(json));
}
```

---

## Known Issues & Pitfalls

### 1. One-Way Channel Death (CRITICAL - UNSOLVED)

The `ma-api` channel stops receiving after 1-3 minutes while `sendspin` continues working. This occurs in both flutter_webrtc and WebView implementations.

**Workaround options:**
- Detect via health check and force reconnection
- Try single-channel multiplexing (see `PLAN_B_SINGLE_CHANNEL.md`)
- Report to MA team and wait for server-side fix

### 2. flutter_webrtc Quirks

- `RTCDataChannel.state` may show "open" when actually dead
- `bufferedAmount` accuracy varies by platform
- `onBufferedAmountLow` callback support inconsistent

### 3. Android Background Throttling

Android aggressively throttles background WebRTC. Consider:
- Foreground service for sustained connections
- Reconnection on app resume

### 4. ICE/TURN Issues

- aiortc (server-side) has known TURN + DataChannel bugs
- May need ICE restart on network changes

---

## Testing Checklist

- [ ] Connect via remote when local unavailable
- [ ] Verify API commands work (players/all, library queries)
- [ ] Test sustained connection (30+ minutes)
- [ ] Test app backgrounding and resume
- [ ] Test network transitions (WiFi ↔ cellular)
- [ ] Verify reconnection after channel death
- [ ] Test sendspin audio streaming (if implemented)

---

## Useful Resources

- [Music Assistant Remote Access Docs](https://music-assistant.io/docs/remote-access/)
- [flutter_webrtc Package](https://pub.dev/packages/flutter_webrtc)
- [WebRTC Data Channel MDN](https://developer.mozilla.org/en-US/docs/Web/API/RTCDataChannel)
- Signaling server: `wss://signaling.music-assistant.io/ws`

---

## Files in This Directory

| File | Description |
|------|-------------|
| `FUTURE_IMPLEMENTATION_GUIDE.md` | This file - implementation guide |
| `MA_WEBRTC_BUG_REPORT.md` | Bug report for MA team |
| `WEBRTC_DISCONNECT_FIXES.md` | All fixes attempted |
| `WEBRTC_PROGRESS.md` | Progress log |
| `PLAN_B_SINGLE_CHANNEL.md` | Alternative single-channel approach |
| `webrtc-failure-logs.txt` | Raw failure logs |
| `console-export-*.log` | Browser console exports |

---

## Quick Start for Future Implementation

1. Read this guide fully
2. Review `WEBRTC_DISCONNECT_FIXES.md` for all attempted fixes
3. Check if MA team has fixed server-side issues
4. Start with basic implementation, add health monitoring early
5. Test extensively before shipping - the failure mode is subtle
