import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

class ServerSettings {
  ServerSettings({
    required this.backend,
    required this.contextSize,
    required this.threads,
    required this.ngl,
    required this.ub,
    required this.flashAttention,
    this.lanAccess = false,
    this.apiKey = '',
  });

  String backend;
  int contextSize;
  int threads;
  int ngl;
  int ub;
  String flashAttention;
  bool lanAccess;
  String apiKey;

  static ServerSettings defaults(String backend) => switch (backend) {
    'adreno' || 'hexagon' => ServerSettings(
      backend: backend,
      contextSize: 4096,
      threads: 4,
      ngl: 99,
      ub: 1024,
      flashAttention: 'on',
    ),
    _ => ServerSettings(
      backend: backend,
      contextSize: 4096,
      threads: 4,
      ngl: 0,
      ub: 512,
      flashAttention: 'auto',
    ),
  };

  static Future<ServerSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final backend = prefs.getString('backend') ?? 'cpu';
    final fallback = defaults(backend);
    return ServerSettings(
      backend: backend,
      contextSize: prefs.getInt('ctx') ?? fallback.contextSize,
      threads: prefs.getInt('threads') ?? fallback.threads,
      ngl: prefs.getInt('ngl') ?? fallback.ngl,
      ub: prefs.getInt('ub') ?? fallback.ub,
      flashAttention: prefs.getString('fa') ?? fallback.flashAttention,
      lanAccess: prefs.getBool('lan') ?? false,
      apiKey: prefs.getString('apiKey') ?? '',
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('backend', backend);
    await prefs.setInt('ctx', contextSize);
    await prefs.setInt('threads', threads);
    await prefs.setInt('ngl', ngl);
    await prefs.setInt('ub', ub);
    await prefs.setString('fa', flashAttention);
    await prefs.setBool('lan', lanAccess);
    await prefs.setString('apiKey', apiKey);
  }

  Map<String, Object?> toConfig(String modelPath) => {
    'backend': backend,
    'model': modelPath,
    'ctx': contextSize,
    'threads': threads,
    'ngl': ngl,
    'ub': ub,
    'fa': flashAttention,
    'lan': lanAccess,
    'apiKey': apiKey,
  };
}

String newApiKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(24, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

String backendLabel(String id) => switch (id) {
  'adreno' => 'Adreno GPU (OpenCL)',
  'hexagon' => 'Hexagon NPU (HTP)',
  _ => 'CPU (arm64)',
};
