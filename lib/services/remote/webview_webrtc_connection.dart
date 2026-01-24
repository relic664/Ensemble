import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:uuid/uuid.dart';
import 'package:ensemble/services/debug_logger.dart';

/// WebRTC connection state (same as WebRTCConnection)
enum WebViewWebRTCConnectionState {
  disconnected,
  connecting,
  connected,
  failed,
}

/// WebView-based WebRTC connection that uses browser-native WebRTC
/// via an embedded InAppWebView running JavaScript.
///
/// This provides the same interface as WebRTCConnection but uses
/// the more reliable browser WebRTC implementation instead of flutter_webrtc.
class WebViewWebRTCConnection {
  InAppWebViewController? _webViewController;
  final _uuid = const Uuid();

  WebViewWebRTCConnectionState _state = WebViewWebRTCConnectionState.disconnected;
  Completer<bool>? _connectionCompleter;
  bool _engineReady = false;
  Completer<void>? _engineReadyCompleter;

  // Message handling for MA API
  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  final _rawMessageController = StreamController<String>.broadcast();
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};

  // Sendspin message handling (text and binary)
  final _sendspinTextController = StreamController<String>.broadcast();
  final _sendspinBinaryController = StreamController<Uint8List>.broadcast();

  // Server info
  Map<String, dynamic>? serverInfo;

  // Callbacks
  Function(WebViewWebRTCConnectionState state)? onStateChanged;
  Function(String error)? onError;

  // Sendspin channel state
  bool _sendspinChannelOpen = false;

  WebViewWebRTCConnectionState get state => _state;
  Stream<Map<String, dynamic>> get messages => _messageController.stream;
  Stream<String> get rawMessages => _rawMessageController.stream;
  bool get isConnected => _state == WebViewWebRTCConnectionState.connected;

  // Sendspin channel streams
  Stream<String> get sendspinTextMessages => _sendspinTextController.stream;
  Stream<Uint8List> get sendspinBinaryMessages => _sendspinBinaryController.stream;
  bool get isSendspinConnected => _sendspinChannelOpen;

  /// Build the WebView widget that must be added to the widget tree.
  /// Parent widget controls size - should be small but visible to avoid Android throttling.
  Widget buildWebView() {
    return InAppWebView(
        initialData: InAppWebViewInitialData(
          data: _buildHtmlContent(),
          mimeType: 'text/html',
          encoding: 'utf-8',
        ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          mediaPlaybackRequiresUserGesture: false,
          allowsInlineMediaPlayback: true,
          // Prevent WebView throttling for hidden/background operation
          useHybridComposition: true,
          // Keep JavaScript running even when WebView is not visible
          javaScriptCanOpenWindowsAutomatically: true,
          // Disable caching to ensure fresh connections
          cacheEnabled: false,
          // Android: prevent throttling of timers/network
          useOnLoadResource: true,
          useShouldInterceptRequest: true,
          // Keep WebView active
          disableContextMenu: true,
          supportZoom: false,
          // iOS: allow background execution
          allowsBackForwardNavigationGestures: false,
          allowsLinkPreview: false,
        ),
        onWebViewCreated: (controller) {
          _webViewController = controller;
          _setupJavaScriptHandlers(controller);
          DebugLogger().log('WebView-WebRTC: WebView created');
        },
        onLoadStop: (controller, url) async {
          DebugLogger().log('WebView-WebRTC: Page loaded, injecting JS engine');
          await _injectWebRTCEngine(controller);
        },
        onConsoleMessage: (controller, consoleMessage) {
          // Only log errors, not routine messages
          if (consoleMessage.message.contains('error') ||
              consoleMessage.message.contains('Error') ||
              consoleMessage.message.contains('failed')) {
            DebugLogger().log('WebView-WebRTC: Console: ${consoleMessage.message}');
          }
        },
      );
  }

  String _buildHtmlContent() {
    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>WebRTC Engine</title>
</head>
<body>
  <div id="status">WebRTC Engine Loading...</div>
</body>
</html>
''';
  }

  Future<void> _injectWebRTCEngine(InAppWebViewController controller) async {
    try {
      // Load the JS engine from assets
      final jsCode = await rootBundle.loadString('assets/webrtc_engine.js');
      await controller.evaluateJavascript(source: jsCode);
      DebugLogger().log('WebView-WebRTC: JS engine injected');
    } catch (e) {
      DebugLogger().log('WebView-WebRTC: Failed to inject JS engine: $e');
      onError?.call('Failed to load WebRTC engine');
    }
  }

  void _setupJavaScriptHandlers(InAppWebViewController controller) {
    // Engine ready notification
    controller.addJavaScriptHandler(
      handlerName: 'onEngineReady',
      callback: (args) {
        DebugLogger().log('WebView-WebRTC: Engine ready');
        _engineReady = true;
        _engineReadyCompleter?.complete();
      },
    );

    // State change notifications
    controller.addJavaScriptHandler(
      handlerName: 'onStateChanged',
      callback: (args) {
        final stateStr = args[0] as String;
        DebugLogger().log('WebView-WebRTC: State changed to: $stateStr');
        _handleStateChange(stateStr);
      },
    );

    // Server hello received
    controller.addJavaScriptHandler(
      handlerName: 'onServerHello',
      callback: (args) {
        final jsonStr = args[0] as String;
        DebugLogger().log('WebView-WebRTC: Server hello received');
        _handleServerHello(jsonStr);
      },
    );

    // API messages from MA server
    controller.addJavaScriptHandler(
      handlerName: 'onApiMessage',
      callback: (args) {
        final jsonStr = args[0] as String;
        _handleApiMessage(jsonStr);
      },
    );

    // Error notifications
    controller.addJavaScriptHandler(
      handlerName: 'onError',
      callback: (args) {
        final error = args[0] as String;
        DebugLogger().log('WebView-WebRTC: Error: $error');
        onError?.call(error);
      },
    );

    // Sendspin state changes
    controller.addJavaScriptHandler(
      handlerName: 'onSendspinStateChanged',
      callback: (args) {
        final stateStr = args[0] as String;
        DebugLogger().log('WebView-WebRTC: Sendspin state: $stateStr');
        _sendspinChannelOpen = stateStr == 'open';
      },
    );

    // Sendspin text messages
    controller.addJavaScriptHandler(
      handlerName: 'onSendspinText',
      callback: (args) {
        final text = args[0] as String;
        // Don't log every sendspin message - too verbose
        if (!_sendspinTextController.isClosed) {
          _sendspinTextController.add(text);
        }
      },
    );

    // Sendspin binary messages (base64 encoded)
    controller.addJavaScriptHandler(
      handlerName: 'onSendspinBinary',
      callback: (args) {
        final base64Str = args[0] as String;
        final bytes = base64Decode(base64Str);
        if (!_sendspinBinaryController.isClosed) {
          _sendspinBinaryController.add(bytes);
        }
      },
    );

    // Log messages from JS - only log important ones
    controller.addJavaScriptHandler(
      handlerName: 'onLog',
      callback: (args) {
        final message = args[0] as String;
        // Only log state changes, errors, and warnings - not routine messages
        if (message.contains('State:') ||
            message.contains('error') ||
            message.contains('Error') ||
            message.contains('failed') ||
            message.contains('WARNING') ||
            message.contains('ICE')) {
          DebugLogger().log('WebView-WebRTC: [JS] $message');
        }
      },
    );
  }

  void _handleStateChange(String stateStr) {
    switch (stateStr) {
      case 'connecting':
        _setState(WebViewWebRTCConnectionState.connecting);
        break;
      case 'connected':
        _setState(WebViewWebRTCConnectionState.connected);
        _safeCompleteConnection(true);
        break;
      case 'disconnected':
        _setState(WebViewWebRTCConnectionState.disconnected);
        break;
      case 'failed':
        _setState(WebViewWebRTCConnectionState.failed);
        _safeCompleteConnection(false);
        break;
    }
  }

  void _handleServerHello(String jsonStr) {
    try {
      serverInfo = jsonDecode(jsonStr) as Map<String, dynamic>;
      DebugLogger().log('WebView-WebRTC: Server info cached: ${serverInfo!['server_version']}');
    } catch (e) {
      DebugLogger().log('WebView-WebRTC: Failed to parse server hello: $e');
    }
  }

  void _handleApiMessage(String jsonStr) {
    try {
      // Don't log every API message - too verbose
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final messageId = data['message_id']?.toString();

      // Check if this is a response to a pending request
      if (messageId != null && _pendingRequests.containsKey(messageId)) {
        _pendingRequests.remove(messageId)?.complete(data);
        return;
      }

      // Forward to raw messages stream (for bridge passthrough)
      _rawMessageController.add(jsonStr);

      // Also broadcast parsed message for internal listeners
      _messageController.add(data);
    } catch (e) {
      DebugLogger().log('WebView-WebRTC: Failed to parse API message: $e');
      // Forward non-JSON as-is
      _rawMessageController.add(jsonStr);
    }
  }

  /// Connect to a remote MA server using the Remote Access ID
  Future<bool> connect(String remoteId) async {
    if (_state == WebViewWebRTCConnectionState.connecting) {
      DebugLogger().log('WebView-WebRTC: Already connecting');
      return false;
    }

    if (_webViewController == null) {
      DebugLogger().log('WebView-WebRTC: WebView not initialized - must add buildWebView() to widget tree first');
      return false;
    }

    // Wait for engine to be ready if needed
    if (!_engineReady) {
      DebugLogger().log('WebView-WebRTC: Waiting for engine to be ready...');
      _engineReadyCompleter = Completer<void>();
      await _engineReadyCompleter!.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          DebugLogger().log('WebView-WebRTC: Engine ready timeout');
        },
      );
    }

    _setState(WebViewWebRTCConnectionState.connecting);
    _connectionCompleter = Completer<bool>();
    serverInfo = null;

    try {
      // Call JavaScript connect function
      DebugLogger().log('WebView-WebRTC: Calling JS connect($remoteId)');
      await _webViewController!.evaluateJavascript(
        source: "connect('$remoteId');",
      );

      // Wait for connection to complete (with timeout)
      final result = await _connectionCompleter!.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          DebugLogger().log('WebView-WebRTC: Connection timeout');
          onError?.call('Connection timeout');
          return false;
        },
      );

      return result;
    } catch (e) {
      DebugLogger().log('WebView-WebRTC: Connection error: $e');
      _setState(WebViewWebRTCConnectionState.failed);
      onError?.call(e.toString());
      return false;
    }
  }

  /// Send a JSON-RPC request and wait for response
  Future<Map<String, dynamic>> sendRequest(
    String command, [
    Map<String, dynamic>? params,
  ]) async {
    if (_webViewController == null || _state != WebViewWebRTCConnectionState.connected) {
      throw Exception('WebView not connected');
    }

    final messageId = _uuid.v4();
    final request = {
      'message_id': messageId,
      'command': command,
      if (params != null) 'args': params,
    };

    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[messageId] = completer;

    final jsonStr = jsonEncode(request);
    // Don't log every request - too verbose

    // Escape the JSON string for JavaScript
    final escapedJson = jsonStr.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
    await _webViewController!.evaluateJavascript(
      source: "sendApiMessage('$escapedJson');",
    );

    // Timeout after 30 seconds
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pendingRequests.remove(messageId);
        throw TimeoutException('Request timed out: $command');
      },
    );
  }

  /// Send a raw message without waiting for response (for bridge passthrough)
  void sendRaw(String message) {
    if (_webViewController == null) {
      DebugLogger().log('WebView-WebRTC: Cannot send raw - WebView is null');
      return;
    }

    if (_state != WebViewWebRTCConnectionState.connected) {
      return;
    }

    // Don't log every raw message - too verbose
    // Escape the JSON string for JavaScript
    final escapedJson = message.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
    _webViewController!.evaluateJavascript(
      source: "sendApiMessage('$escapedJson');",
    );
  }

  /// Check if the data channel is healthy
  bool get isDataChannelHealthy {
    return _state == WebViewWebRTCConnectionState.connected;
  }

  /// Get data channel state for debugging
  String get dataChannelStateDebug {
    return _state.toString();
  }

  /// Send a text message to Sendspin channel (JSON control messages)
  void sendSendspinText(String message) {
    if (_webViewController == null || !_sendspinChannelOpen) {
      DebugLogger().log('WebView-WebRTC: Cannot send sendspin text - channel not open');
      return;
    }

    final escapedJson = message.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
    _webViewController!.evaluateJavascript(
      source: "sendSendspinText('$escapedJson');",
    );
  }

  /// Send binary data to Sendspin channel (audio data from local player)
  void sendSendspinBinary(Uint8List data) {
    if (_webViewController == null || !_sendspinChannelOpen) {
      DebugLogger().log('WebView-WebRTC: Cannot send sendspin binary - channel not open');
      return;
    }

    final base64Str = base64Encode(data);
    _webViewController!.evaluateJavascript(
      source: "sendSendspinBinary('$base64Str');",
    );
  }

  /// Disconnect from the remote server
  Future<void> disconnect() async {
    DebugLogger().log('WebView-WebRTC: Disconnecting');

    if (_webViewController != null) {
      await _webViewController!.evaluateJavascript(source: "disconnect();");
    }

    // Complete all pending requests with an error
    _completePendingRequestsWithError('WebRTC connection disconnected');

    serverInfo = null;
    _sendspinChannelOpen = false;

    _setState(WebViewWebRTCConnectionState.disconnected);
  }

  void _completePendingRequestsWithError(String reason) {
    for (final entry in _pendingRequests.entries) {
      if (!entry.value.isCompleted) {
        entry.value.completeError(Exception(reason));
      }
    }
    _pendingRequests.clear();
  }

  void _setState(WebViewWebRTCConnectionState newState) {
    if (_state != newState) {
      DebugLogger().log('WebView-WebRTC: State changed: $_state -> $newState');
      _state = newState;
      onStateChanged?.call(newState);
    }
  }

  void _safeCompleteConnection(bool success) {
    if (_connectionCompleter != null && !_connectionCompleter!.isCompleted) {
      _connectionCompleter!.complete(success);
    }
  }

  void dispose() {
    _messageController.close();
    _rawMessageController.close();
    _sendspinTextController.close();
    _sendspinBinaryController.close();
    disconnect();
  }
}
