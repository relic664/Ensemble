/**
 * WebRTC Engine for Music Assistant
 *
 * This JavaScript runs inside a WebView and provides browser-native WebRTC
 * connectivity to the MA server. It communicates with Dart via flutter_inappwebview
 * JavaScript handlers.
 */

(function() {
  'use strict';

  const SIGNALING_URL = 'wss://signaling.music-assistant.io/ws';

  // State
  let signalingWs = null;
  let peerConnection = null;
  let apiDataChannel = null;
  let sendspinDataChannel = null;
  let sessionId = null;
  let remoteId = null;
  let iceServers = [];
  let pingTimer = null;
  let serverHelloReceived = false;
  let apiKeepAliveTimer = null;

  // Logging helper that also sends to Dart
  function log(message) {
    console.log('[WebRTC-JS] ' + message);
    callDart('onLog', message);
  }

  // Call Dart handler safely
  function callDart(handler, data) {
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler(handler, data);
    }
  }

  // Notify Dart of state changes
  function notifyState(state) {
    log('State: ' + state);
    callDart('onStateChanged', state);
  }

  // Notify Dart of errors
  function notifyError(error) {
    log('Error: ' + error);
    callDart('onError', error);
  }

  // ============ Signaling ============

  function connectSignaling(targetRemoteId) {
    remoteId = targetRemoteId.replace(/-/g, '').toUpperCase();
    log('Connecting to signaling server for remote ID: ' + remoteId);
    notifyState('connecting');

    try {
      signalingWs = new WebSocket(SIGNALING_URL);

      signalingWs.onopen = function() {
        log('Signaling WebSocket connected');
        startPingTimer();

        // Send connect request
        signalingWs.send(JSON.stringify({
          type: 'connect-request',
          remoteId: remoteId
        }));
      };

      signalingWs.onmessage = function(event) {
        handleSignalingMessage(JSON.parse(event.data));
      };

      signalingWs.onerror = function(error) {
        log('Signaling WebSocket error: ' + error);
        notifyError('Signaling connection error');
      };

      signalingWs.onclose = function() {
        log('Signaling WebSocket closed');
        stopPingTimer();
      };

    } catch (e) {
      log('Failed to connect to signaling: ' + e);
      notifyError('Failed to connect to signaling server');
    }
  }

  function handleSignalingMessage(message) {
    const type = message.type;
    log('Signaling message: ' + type);

    switch (type) {
      case 'ping':
        signalingWs.send(JSON.stringify({ type: 'pong' }));
        break;

      case 'pong':
        // Ignore
        break;

      case 'connected':
        sessionId = message.sessionId;
        iceServers = message.iceServers || [];
        log('Connected to signaling, session: ' + sessionId);
        log('Received ' + iceServers.length + ' ICE servers');
        createPeerConnection();
        break;

      case 'answer':
        handleAnswer(message.data);
        break;

      case 'ice-candidate':
        handleRemoteIceCandidate(message.data);
        break;

      case 'peer-disconnected':
        log('Remote peer disconnected');
        notifyState('disconnected');
        notifyError('Remote server disconnected');
        break;

      case 'error':
        log('Signaling error: ' + message.error);
        notifyError(message.error);
        break;

      default:
        log('Unknown signaling message: ' + type);
    }
  }

  function startPingTimer() {
    stopPingTimer();
    pingTimer = setInterval(function() {
      if (signalingWs && signalingWs.readyState === WebSocket.OPEN) {
        signalingWs.send(JSON.stringify({ type: 'ping' }));
      }
    }, 15000);
  }

  function stopPingTimer() {
    if (pingTimer) {
      clearInterval(pingTimer);
      pingTimer = null;
    }
  }

  // ============ WebRTC ============

  function createPeerConnection() {
    log('Creating peer connection with ' + iceServers.length + ' ICE servers');

    try {
      // Format ICE servers for browser API
      const config = {
        iceServers: iceServers.map(function(server) {
          const iceServer = { urls: server.urls };
          if (server.username) iceServer.username = server.username;
          if (server.credential) iceServer.credential = server.credential;
          return iceServer;
        }),
        sdpSemantics: 'unified-plan'
      };

      log('ICE config: ' + JSON.stringify(config));

      peerConnection = new RTCPeerConnection(config);

      peerConnection.onicecandidate = function(event) {
        if (event.candidate) {
          log('Local ICE candidate: ' + event.candidate.candidate.substring(0, 50) + '...');
          signalingWs.send(JSON.stringify({
            type: 'ice-candidate',
            remoteId: remoteId,
            sessionId: sessionId,
            data: {
              candidate: event.candidate.candidate,
              sdpMid: event.candidate.sdpMid,
              sdpMLineIndex: event.candidate.sdpMLineIndex
            }
          }));
        }
      };

      peerConnection.oniceconnectionstatechange = function() {
        log('ICE connection state: ' + peerConnection.iceConnectionState);
        if (peerConnection.iceConnectionState === 'failed') {
          notifyError('ICE connection failed');
        }
      };

      peerConnection.onconnectionstatechange = function() {
        log('Peer connection state: ' + peerConnection.connectionState);
        if (peerConnection.connectionState === 'failed') {
          notifyError('Peer connection failed');
        } else if (peerConnection.connectionState === 'closed') {
          notifyState('disconnected');
        }
      };

      peerConnection.ondatachannel = function(event) {
        log('Remote data channel received: ' + event.channel.label);
        // Server might send additional channels
      };

      // Create ONLY the API data channel initially
      // Sendspin channel will be created LATER after API is working (like MA Web App does)
      log('Creating API data channel...');

      // ma-api channel for JSON-RPC API messages (reliable, ordered)
      apiDataChannel = peerConnection.createDataChannel('ma-api', {
        ordered: true
      });
      setupApiDataChannel(apiDataChannel);

      // Create and send offer
      peerConnection.createOffer()
        .then(function(offer) {
          return peerConnection.setLocalDescription(offer);
        })
        .then(function() {
          log('Sending offer');
          signalingWs.send(JSON.stringify({
            type: 'offer',
            remoteId: remoteId,
            sessionId: sessionId,
            data: {
              type: peerConnection.localDescription.type,
              sdp: peerConnection.localDescription.sdp
            }
          }));
        })
        .catch(function(error) {
          log('Failed to create offer: ' + error);
          notifyError('Failed to create WebRTC offer');
        });

    } catch (e) {
      log('Failed to create peer connection: ' + e);
      notifyError('Failed to create peer connection');
    }
  }

  function handleAnswer(answer) {
    log('Received answer');
    const desc = new RTCSessionDescription(answer);
    peerConnection.setRemoteDescription(desc)
      .catch(function(error) {
        log('Failed to set remote description: ' + error);
        notifyError('Failed to set remote description');
      });
  }

  function handleRemoteIceCandidate(candidateData) {
    log('Received remote ICE candidate');
    const candidate = new RTCIceCandidate({
      candidate: candidateData.candidate,
      sdpMid: candidateData.sdpMid,
      sdpMLineIndex: candidateData.sdpMLineIndex
    });
    peerConnection.addIceCandidate(candidate)
      .catch(function(error) {
        log('Failed to add ICE candidate: ' + error);
      });
  }

  // ============ Data Channels ============

  function setupApiDataChannel(channel) {
    channel.onopen = function() {
      log('API data channel open - waiting for server hello');
    };

    channel.onclose = function() {
      log('API data channel closed');
      notifyState('disconnected');
    };

    channel.onerror = function(error) {
      log('API data channel error: ' + error);
      notifyError('Data channel error');
    };

    channel.onmessage = function(event) {
      const data = event.data;

      // Debug: log data type and first 100 chars
      const dataType = typeof data;
      const isBlob = data instanceof Blob;
      const isArrayBuffer = data instanceof ArrayBuffer;
      log('API msg received - type:' + dataType + ' isBlob:' + isBlob + ' isAB:' + isArrayBuffer + ' len:' + (data.length || data.byteLength || 'N/A'));

      // Handle Blob data (convert to text first)
      if (isBlob) {
        const reader = new FileReader();
        reader.onload = function() {
          log('API Blob->text: ' + reader.result.substring(0, 100));
          processApiMessage(reader.result);
        };
        reader.readAsText(data);
        return;
      }

      // Handle ArrayBuffer data
      if (isArrayBuffer) {
        const textDecoder = new TextDecoder('utf-8');
        const text = textDecoder.decode(data);
        log('API ArrayBuffer->text: ' + text.substring(0, 100));
        processApiMessage(text);
        return;
      }

      // Handle string data
      if (dataType === 'string') {
        log('API string: ' + data.substring(0, 100));
      }

      processApiMessage(data);
    };
  }

  function processApiMessage(data) {
    try {
      const message = JSON.parse(data);

      // Check for server hello (has server_id but no message_id)
      if (message.server_id && !message.message_id && !serverHelloReceived) {
        log('Server hello received - server_version: ' + message.server_version);
        serverHelloReceived = true;
        notifyState('connected');
        callDart('onServerHello', data);
        return;
      }

      // Forward all other messages to Dart
      callDart('onApiMessage', data);

    } catch (e) {
      log('API parse error: ' + e.message + ' data: ' + String(data).substring(0, 50));
      // Non-JSON message, forward as-is
      callDart('onApiMessage', data);
    }
  }

  function setupSendspinDataChannel(channel) {
    channel.binaryType = 'arraybuffer';

    channel.onopen = function() {
      log('Sendspin data channel open');
      callDart('onSendspinStateChanged', 'open');
    };

    channel.onclose = function() {
      log('Sendspin data channel closed');
      callDart('onSendspinStateChanged', 'closed');
    };

    channel.onerror = function(error) {
      log('Sendspin data channel error: ' + error);
    };

    channel.onmessage = function(event) {
      if (event.data instanceof ArrayBuffer) {
        // Binary audio data - convert to base64 for transfer to Dart
        const bytes = new Uint8Array(event.data);
        const base64 = arrayBufferToBase64(bytes);
        callDart('onSendspinBinary', base64);
      } else {
        // Text message (JSON control)
        callDart('onSendspinText', event.data);
      }
    };
  }

  // ============ Dart-callable Functions ============

  // Connect to a remote MA server
  window.connect = function(targetRemoteId) {
    log('Connect called with remoteId: ' + targetRemoteId);
    serverHelloReceived = false;
    connectSignaling(targetRemoteId);
  };

  // Send a message on the API data channel
  window.sendApiMessage = function(jsonString) {
    if (apiDataChannel && apiDataChannel.readyState === 'open') {
      // Check buffer status before sending
      const buffered = apiDataChannel.bufferedAmount;
      if (buffered > 1048576) { // 1MB buffer warning
        log('WARNING: API channel buffer high: ' + buffered + ' bytes');
        callDart('onBufferWarning', 'api:' + buffered);
      }
      apiDataChannel.send(jsonString);
    } else {
      log('Cannot send API message - channel not open, state: ' +
          (apiDataChannel ? apiDataChannel.readyState : 'null'));
      callDart('onError', 'API channel not open');
    }
  };

  // Send binary data on the sendspin channel (base64 encoded)
  window.sendSendspinBinary = function(base64String) {
    if (sendspinDataChannel && sendspinDataChannel.readyState === 'open') {
      const bytes = base64ToArrayBuffer(base64String);
      sendspinDataChannel.send(bytes);
    } else {
      log('Cannot send sendspin binary - channel not open');
    }
  };

  // Send text data on the sendspin channel
  window.sendSendspinText = function(text) {
    if (sendspinDataChannel && sendspinDataChannel.readyState === 'open') {
      sendspinDataChannel.send(text);
    } else {
      log('Cannot send sendspin text - channel not open');
    }
  };

  // Disconnect and clean up
  window.disconnect = function() {
    log('Disconnect called');

    stopPingTimer();

    if (apiDataChannel) {
      apiDataChannel.close();
      apiDataChannel = null;
    }

    if (sendspinDataChannel) {
      sendspinDataChannel.close();
      sendspinDataChannel = null;
    }

    if (peerConnection) {
      peerConnection.close();
      peerConnection = null;
    }

    if (signalingWs) {
      signalingWs.close();
      signalingWs = null;
    }

    sessionId = null;
    remoteId = null;
    serverHelloReceived = false;

    notifyState('disconnected');
  };

  // Check if API channel is open
  window.isApiChannelOpen = function() {
    return apiDataChannel && apiDataChannel.readyState === 'open';
  };

  // Check if sendspin channel is open
  window.isSendspinChannelOpen = function() {
    return sendspinDataChannel && sendspinDataChannel.readyState === 'open';
  };

  // Get detailed channel health info
  window.getChannelHealth = function() {
    const health = {
      peerConnection: peerConnection ? peerConnection.connectionState : 'null',
      iceConnection: peerConnection ? peerConnection.iceConnectionState : 'null',
      apiChannel: apiDataChannel ? apiDataChannel.readyState : 'null',
      apiBuffered: apiDataChannel ? apiDataChannel.bufferedAmount : -1,
      sendspinChannel: sendspinDataChannel ? sendspinDataChannel.readyState : 'null',
      sendspinBuffered: sendspinDataChannel ? sendspinDataChannel.bufferedAmount : -1,
      signalingConnected: signalingWs && signalingWs.readyState === WebSocket.OPEN
    };
    return JSON.stringify(health);
  };

  // ============ Utilities ============

  function arrayBufferToBase64(buffer) {
    let binary = '';
    const bytes = new Uint8Array(buffer);
    for (let i = 0; i < bytes.byteLength; i++) {
      binary += String.fromCharCode(bytes[i]);
    }
    return btoa(binary);
  }

  function base64ToArrayBuffer(base64) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes.buffer;
  }

  // Signal that the engine is ready
  log('WebRTC engine initialized');
  callDart('onEngineReady', 'ready');

})();
