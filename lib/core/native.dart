import 'package:flutter/services.dart';

import 'models.dart';

class Native {
  static const MethodChannel _control = MethodChannel('llama/control');
  static const EventChannel _events = EventChannel('llama/events');

  static Stream<Map<String, dynamic>> events() => _events
      .receiveBroadcastStream()
      .map((event) => Map<String, dynamic>.from(event as Map));

  static Future<AppStatus> status() async {
    final raw = await _control.invokeMethod<Map>('status');
    return AppStatus.fromJson(Map<String, dynamic>.from(raw ?? {}));
  }

  static Future<void> download(String backend) =>
      _control.invokeMethod('download', {'backend': backend});

  static Future<void> deleteBackend(String backend) =>
      _control.invokeMethod('deleteBackend', {'backend': backend});

  static Future<void> start(Map<String, Object?> config) =>
      _control.invokeMethod('start', config);

  static Future<void> stop() => _control.invokeMethod('stop');

  static Future<void> pickModel() => _control.invokeMethod('pickModel');

  static Future<List<String>> logs() async {
    final raw = await _control.invokeMethod<List>('logs');
    return raw?.map((line) => line.toString()).toList() ?? <String>[];
  }

  static Future<String?> loadChats() =>
      _control.invokeMethod<String>('loadChats');

  static Future<bool> saveChats(String json) async =>
      await _control.invokeMethod<bool>('saveChats', {'json': json}) ?? false;
}
