class ModelInfo {
  const ModelInfo({required this.path, required this.name, required this.size});

  final String path;
  final String name;
  final int size;

  factory ModelInfo.fromJson(Map<String, dynamic> json) => ModelInfo(
    path: json['path'] as String? ?? '',
    name: json['name'] as String? ?? 'model',
    size: (json['size'] as num?)?.toInt() ?? 0,
  );

  String get sizeLabel {
    final mb = size / (1024 * 1024);
    return mb >= 1024
        ? '${(mb / 1024).toStringAsFixed(2)} GB'
        : '${mb.toStringAsFixed(1)} MB';
  }
}

class BackendInfo {
  const BackendInfo({
    required this.id,
    required this.installed,
    required this.bytes,
  });

  final String id;
  final bool installed;
  final int bytes;

  factory BackendInfo.fromJson(String id, Map<String, dynamic> json) =>
      BackendInfo(
        id: id,
        installed: json['installed'] as bool? ?? false,
        bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      );
}

class ServerInfo {
  const ServerInfo({
    this.state = 'idle',
    this.message,
    this.backend,
    this.port = 8080,
    this.model,
  });

  final String state;
  final String? message;
  final String? backend;
  final int port;
  final String? model;

  bool get ready => state == 'ready';
  bool get busy => state == 'starting';

  factory ServerInfo.fromJson(Map<String, dynamic> json) => ServerInfo(
    state: json['state'] as String? ?? 'idle',
    message: json['message'] as String?,
    backend: json['backend'] as String?,
    port: (json['port'] as num?)?.toInt() ?? 8080,
    model: json['model'] as String?,
  );
}

class AppStatus {
  const AppStatus({
    required this.abi,
    required this.sdk,
    required this.freeSpace,
    required this.backends,
    required this.server,
    this.model,
    this.downloading,
    this.socQualcomm = false,
    this.socName = 'unknown',
    this.vulkan = false,
    this.wifiIp,
  });

  final String abi;
  final int sdk;
  final int freeSpace;
  final Map<String, BackendInfo> backends;
  final ServerInfo server;
  final ModelInfo? model;
  final String? downloading;
  final bool socQualcomm;
  final String socName;
  final bool vulkan;
  final String? wifiIp;

  factory AppStatus.fromJson(Map<String, dynamic> json) {
    final backends = <String, BackendInfo>{};
    final raw = json['backends'] as Map?;
    raw?.forEach((key, value) {
      backends[key as String] = BackendInfo.fromJson(
        key,
        Map<String, dynamic>.from(value as Map),
      );
    });
    final model = json['model'];
    return AppStatus(
      abi: json['abi'] as String? ?? 'unknown',
      sdk: (json['sdk'] as num?)?.toInt() ?? 0,
      freeSpace: (json['freeSpace'] as num?)?.toInt() ?? 0,
      backends: backends,
      server: ServerInfo.fromJson(
        Map<String, dynamic>.from(json['server'] as Map? ?? {}),
      ),
      model: model is Map
          ? ModelInfo.fromJson(Map<String, dynamic>.from(model))
          : null,
      downloading: json['downloading'] as String?,
      socQualcomm: json['socQualcomm'] as bool? ?? false,
      socName: json['socName'] as String? ?? 'unknown',
      vulkan: json['vulkan'] as bool? ?? false,
      wifiIp: json['wifiIp'] as String?,
    );
  }

  String get freeSpaceLabel {
    final gb = freeSpace / (1024 * 1024 * 1024);
    return '${gb.toStringAsFixed(1)} GB free';
  }
}
