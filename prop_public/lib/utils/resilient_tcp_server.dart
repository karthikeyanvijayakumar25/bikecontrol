// Simplified implementation (the full one lives in the private package).
//
// A TCP server with dual-stack listening, port fallback, single-client
// reconnect-supersede (or a capped set of concurrent clients), owner-based
// supersede of a previous server, and self-probe filtering for the network
// self-test.

import 'dart:async';
import 'dart:io';

class ResilientTcpServer {
  ResilientTcpServer({
    required this.preferredPort,
    this.portAttempts = 5,
    this.forceIPv4 = false,
    this.allowConcurrentClients = false,
    this.maxConcurrentClients = 8,
    this.label,
    this.owner,
    required this.onClientConnected,
    required this.onData,
    required this.onClientDisconnected,
    this.onClientLeft,
  }) : assert(portAttempts >= 1),
       assert(maxConcurrentClients >= 1);

  final int preferredPort;
  final int portAttempts;
  final bool forceIPv4;
  final bool allowConcurrentClients;
  final int maxConcurrentClients;
  final String? label;

  /// Whoever this server serves on behalf of — the emulator instance, or a
  /// stable key. Compared with `==`.
  final Object? owner;

  /// Every currently-running server, for the diagnostics block.
  static final List<ResilientTcpServer> activeServers = [];

  final void Function(Socket socket) onClientConnected;
  final void Function(Socket socket, List<int> data) onData;
  final void Function() onClientDisconnected;

  /// One client went away, while others may remain.
  final void Function(Socket socket)? onClientLeft;

  ServerSocket? _serverSocket;
  StreamSubscription<Socket>? _acceptSub;
  final List<Socket> _clients = [];
  final List<_ExpectedProbe> _probes = [];
  int? _boundPort;

  bool get isRunning => _serverSocket != null;
  bool get hasClient => _clients.isNotEmpty;
  Socket? get client => _clients.isEmpty ? null : _clients.last;
  int get boundPort => _boundPort ?? preferredPort;

  Future<void> start() async {
    if (_serverSocket != null) return;

    // A previous server of the same owner (still closing, or lost track of)
    // gives up its port so this one rebinds the preferred port.
    if (owner != null) {
      for (final other in List.of(activeServers)) {
        if (!identical(other, this) && other.owner == owner) {
          await other.stop();
        }
      }
    }

    Object? lastError;
    for (var i = 0; i < portAttempts; i++) {
      final port = preferredPort + i;
      try {
        _serverSocket = await _bind(port);
        _boundPort = port;
        break;
      } on SocketException catch (e) {
        lastError = e;
      }
    }
    final serverSocket = _serverSocket;
    if (serverSocket == null) {
      throw lastError ?? SocketException('Could not bind port $preferredPort');
    }

    activeServers.add(this);
    _acceptSub = serverSocket.listen(
      _handleAccept,
      onError: (Object _) {},
      onDone: () {
        if (identical(_serverSocket, serverSocket)) {
          _serverSocket = null;
          activeServers.remove(this);
        }
      },
    );
  }

  Future<ServerSocket> _bind(int port) async {
    if (forceIPv4) return ServerSocket.bind(InternetAddress.anyIPv4, port);
    try {
      // Dual stack: one socket accepts IPv4 (as mapped) and IPv6 clients.
      return await ServerSocket.bind(InternetAddress.anyIPv6, port, v6Only: false);
    } on SocketException {
      return ServerSocket.bind(InternetAddress.anyIPv4, port);
    }
  }

  void _handleAccept(Socket socket) {
    if (_consumeProbe(socket)) {
      // The self-test's own throwaway connection: not a client.
      socket.listen((_) {}, onError: (Object _) {}, onDone: socket.destroy, cancelOnError: true);
      return;
    }

    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}

    if (allowConcurrentClients) {
      if (_clients.length >= maxConcurrentClients) {
        socket.destroy();
        return;
      }
    } else if (_clients.isNotEmpty) {
      // Reconnect-supersede: the newest client wins. The old one is dropped
      // from the list first so its close does not report a disconnect.
      final old = List.of(_clients);
      _clients.clear();
      for (final s in old) {
        s.destroy();
      }
    }

    _clients.add(socket);
    onClientConnected(socket);

    var closed = false;
    void handleClosed() {
      if (closed) return;
      closed = true;
      final wasTracked = _clients.remove(socket);
      socket.destroy();
      if (!wasTracked) return; // superseded or server stopped
      if (allowConcurrentClients) {
        onClientLeft?.call(socket);
        if (_clients.isEmpty) onClientDisconnected();
      } else {
        onClientDisconnected();
      }
    }

    socket.listen(
      (data) => onData(socket, data),
      onError: (Object _) => handleClosed(),
      onDone: handleClosed,
      cancelOnError: true,
    );
  }

  static String _normalize(String address) =>
      address.toLowerCase().startsWith('::ffff:') ? address.substring(7) : address;

  bool _consumeProbe(Socket socket) {
    final now = DateTime.now();
    _probes.removeWhere((p) => p.expires.isBefore(now));
    final String remote;
    try {
      remote = _normalize(socket.remoteAddress.address);
    } catch (_) {
      return false;
    }
    final index = _probes.indexWhere(
      (p) => p.sourcePort == socket.remotePort && _normalize(p.address) == remote,
    );
    if (index < 0) return false;
    _probes.removeAt(index);
    return true;
  }

  /// Announces that this process is about to open a throwaway TCP connection
  /// to its own server, so the next matching accepted socket is ignored.
  void expectProbe({
    required String address,
    required int sourcePort,
    Duration validity = const Duration(seconds: 5),
  }) {
    _probes.add(_ExpectedProbe(address, sourcePort, DateTime.now().add(validity)));
  }

  /// Disconnects the current client(s); the server keeps listening.
  void dropClient() {
    for (final s in List.of(_clients)) {
      s.destroy();
    }
  }

  Future<void> stop() async {
    activeServers.remove(this);
    final serverSocket = _serverSocket;
    _serverSocket = null;
    final hadClients = _clients.isNotEmpty;
    final clients = List.of(_clients);
    _clients.clear();
    for (final s in clients) {
      s.destroy();
    }
    await _acceptSub?.cancel();
    _acceptSub = null;
    await serverSocket?.close();
    if (hadClients) onClientDisconnected();
  }
}

class _ExpectedProbe {
  final String address;
  final int sourcePort;
  final DateTime expires;

  _ExpectedProbe(this.address, this.sourcePort, this.expires);
}
