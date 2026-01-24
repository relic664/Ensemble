# Plan B: Single Data Channel Multiplexing

## Why This Might Be Needed

If upgrading flutter_webrtc doesn't fix the one-way channel failure, the root cause is likely a bug in how flutter_webrtc (or underlying libwebrtc) handles **multiple data channels**.

Evidence:
- MA Web UI works fine with local playback (same server, browser WebRTC)
- Our app uses flutter_webrtc which has known issues:
  - [Issue #1428](https://github.com/flutter-webrtc/flutter-webrtc/issues/1428): Threading issues causing data loss
  - [Issue #974](https://github.com/flutter-webrtc/flutter-webrtc/issues/974): EventChannel intermittently fails
- Pattern matches: second channel survives while first dies

## Current Architecture

```
┌─────────────────────────────────────────────────┐
│              WebRTC Peer Connection             │
├────────────────────┬────────────────────────────┤
│   ma-api channel   │     sendspin channel       │
│   (JSON API)       │   (JSON + binary audio)    │
│   SCTP stream 0    │     SCTP stream 1          │
└────────────────────┴────────────────────────────┘
```

## Proposed Architecture

```
┌─────────────────────────────────────────────────┐
│              WebRTC Peer Connection             │
├─────────────────────────────────────────────────┤
│              unified channel                     │
│    (multiplexed: API + Sendspin text + binary)  │
│              SCTP stream 0                       │
└─────────────────────────────────────────────────┘
```

## Multiplexing Protocol

### Message Framing

Each message has a 1-byte type prefix:

| Prefix | Type | Content |
|--------|------|---------|
| 0x00 | API | JSON text (MA API request/response) |
| 0x01 | Sendspin Text | JSON text (Sendspin control messages) |
| 0x02 | Sendspin Binary | Raw bytes (PCM audio data) |

### Implementation

#### Sending (Client → Server)

```dart
void sendApiMessage(String json) {
  final prefix = Uint8List.fromList([0x00]);
  final payload = utf8.encode(json);
  final message = Uint8List(1 + payload.length);
  message[0] = 0x00;
  message.setRange(1, message.length, payload);
  _dataChannel.send(RTCDataChannelMessage.fromBinary(message));
}

void sendSendspinText(String json) {
  final prefix = Uint8List.fromList([0x01]);
  final payload = utf8.encode(json);
  final message = Uint8List(1 + payload.length);
  message[0] = 0x01;
  message.setRange(1, message.length, payload);
  _dataChannel.send(RTCDataChannelMessage.fromBinary(message));
}

void sendSendspinBinary(Uint8List audio) {
  final message = Uint8List(1 + audio.length);
  message[0] = 0x02;
  message.setRange(1, message.length, audio);
  _dataChannel.send(RTCDataChannelMessage.fromBinary(message));
}
```

#### Receiving (Server → Client)

```dart
void _onMessage(RTCDataChannelMessage message) {
  final data = message.binary;
  if (data == null || data.isEmpty) return;

  final type = data[0];
  final payload = data.sublist(1);

  switch (type) {
    case 0x00: // API
      final json = utf8.decode(payload);
      _handleApiMessage(json);
      break;
    case 0x01: // Sendspin text
      final json = utf8.decode(payload);
      _handleSendspinText(json);
      break;
    case 0x02: // Sendspin binary
      _handleSendspinBinary(payload);
      break;
  }
}
```

## Server-Side Changes Required

The Music Assistant server would need to:
1. Accept a single "unified" data channel instead of separate ma-api and sendspin channels
2. Multiplex responses using the same framing protocol
3. This requires changes to the MA remote connection code

**Alternative**: Keep server unchanged, do multiplexing in a proxy layer on the client.

## Client-Only Approach (No Server Changes)

If we can't change the server, we could:

1. Still create two channels to the server (ma-api + sendspin)
2. But internally route them through a single "virtual" channel for flutter_webrtc
3. This is more complex and may not avoid the underlying bug

## Files to Modify

| File | Changes |
|------|---------|
| `webrtc_connection.dart` | Single channel creation, multiplexing logic |
| `remote_bridge.dart` | Route messages based on type prefix |

## Risks

1. **Server compatibility**: Requires MA server changes or complex client proxy
2. **Performance**: Extra byte per message, decode overhead
3. **Binary handling**: Must handle all messages as binary (not text)

## Testing Plan

1. Implement client-side changes
2. Test with modified server (if available) or mock
3. Verify both API and Sendspin traffic flows correctly
4. Long-duration stability test

## Decision Point

Try this approach if:
- flutter_webrtc 0.14.x doesn't fix the issue
- The one-way failure pattern continues
- We've confirmed the issue is multi-channel specific
