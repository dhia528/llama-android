import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'native.dart';
import 'settings.dart';

class AppController extends ChangeNotifier {
  AppController() {
    _subscription = Native.events().listen(_onEvent);
  }

  late final StreamSubscription<Map<String, dynamic>> _subscription;
  AppStatus? status;
  ServerInfo server = const ServerInfo();
  List<String> logs = [];
  String? notice;
  String? error;
  double? downloadProgress;
  String? downloadingBackend;
  ServerSettings settings = ServerSettings.defaults('cpu');
  bool loading = true;
  final Set<String> _installing = {};

  bool isInstalling(String backend) =>
      downloadingBackend == backend || _installing.contains(backend);

  Future<void> init() async {
    try {
      settings = await ServerSettings.load().timeout(
        const Duration(seconds: 5),
      );
      logs = await Native.logs().timeout(const Duration(seconds: 5));
      await refresh();
    } catch (e) {
      error = 'Startup failed: $e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    try {
      status = await Native.status().timeout(const Duration(seconds: 5));
      server = status!.server;
      downloadingBackend = status!.downloading;
      notifyListeners();
    } catch (e) {
      error = 'Native bridge unavailable: $e';
      notifyListeners();
    }
  }

  Future<void> saveSettings(ServerSettings next) async {
    settings = next;
    await next.save();
    notifyListeners();
  }

  Future<void> startServer() async {
    final model = status?.model;
    if (model == null) {
      error = 'Choose a GGUF model first';
      notifyListeners();
      return;
    }
    error = null;
    notice = null;
    await Native.start(settings.toConfig(model.path));
    notifyListeners();
  }

  Future<void> stopServer() async {
    await Native.stop();
    await refresh();
  }

  Future<void> downloadBackend(String backend) async {
    error = null;
    downloadingBackend = backend;
    downloadProgress = 0;
    notifyListeners();
    await Native.download(backend);
  }

  Future<void> deleteBackend(String backend) async {
    await Native.deleteBackend(backend);
    await refresh();
  }

  Future<void> pickModel() async {
    error = null;
    await Native.pickModel();
  }

  void clearError() {
    error = null;
    notifyListeners();
  }

  void clearNotice() {
    notice = null;
    notifyListeners();
  }

  void _onEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'log':
        final lines =
            (event['lines'] as List?)?.map((e) => e.toString()).toList() ?? [];
        logs = [...logs, ...lines];
        if (logs.length > 2000) logs = logs.sublist(logs.length - 2000);
        notifyListeners();
      case 'state':
        server = ServerInfo(
          state: event['state'] as String? ?? server.state,
          message: event['message'] as String?,
          backend: event['backend'] as String? ?? server.backend,
          port: (event['port'] as num?)?.toInt() ?? server.port,
          model: server.model,
        );
        notifyListeners();
        refresh();
      case 'download':
        final backend = event['backend'] as String?;
        if (event['done'] == true) {
          downloadingBackend = null;
          downloadProgress = null;
          if (backend != null) _installing.remove(backend);
          notice = 'Backend "$backend" installed';
          refresh();
        } else {
          downloadingBackend = backend;
          final received = (event['received'] as num?)?.toDouble() ?? 0;
          final total = (event['total'] as num?)?.toDouble() ?? 0;
          downloadProgress = total > 0 ? (received / total).clamp(0, 1) : null;
          notifyListeners();
        }
      case 'model':
        if (event['done'] == true) {
          notice = 'Model loaded: ${event['name']}';
          refresh();
        }
      case 'error':
        _installing.clear();
        downloadingBackend = null;
        downloadProgress = null;
        error = event['message'] as String? ?? 'Unknown native error';
        notifyListeners();
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
