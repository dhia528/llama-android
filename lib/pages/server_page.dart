import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_controller.dart';
import '../core/models.dart';
import '../core/settings.dart';

class ServerPage extends StatefulWidget {
  const ServerPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<ServerPage> createState() => _ServerPageState();
}

class _ServerPageState extends State<ServerPage> {
  late final TextEditingController _ctx;
  late final TextEditingController _threads;
  late final TextEditingController _ngl;
  late final TextEditingController _ub;
  late String _backend;
  late String _flashAttention;
  late bool _lanAccess;
  late final TextEditingController _apiKey;
  Timer? _saveTimer;
  final ScrollController _logScroll = ScrollController();

  AppController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    final settings = _controller.settings;
    _backend = settings.backend;
    _flashAttention = settings.flashAttention;
    _lanAccess = settings.lanAccess;
    _ctx = TextEditingController(text: settings.contextSize.toString());
    _threads = TextEditingController(text: settings.threads.toString());
    _ngl = TextEditingController(text: settings.ngl.toString());
    _ub = TextEditingController(text: settings.ub.toString());
    _apiKey = TextEditingController(text: settings.apiKey);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _persist();
    _ctx.dispose();
    _threads.dispose();
    _ngl.dispose();
    _ub.dispose();
    _apiKey.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  int _int(TextEditingController controller, int fallback, int min, int max) {
    final value = int.tryParse(controller.text.trim());
    return (value ?? fallback).clamp(min, max);
  }

  ServerSettings _settings() => ServerSettings(
    backend: _backend,
    contextSize: _int(_ctx, 4096, 128, 131072),
    threads: _int(_threads, 4, 1, 32),
    ngl: _int(_ngl, 0, 0, 999),
    ub: _int(_ub, 512, 32, 4096),
    flashAttention: _flashAttention,
    lanAccess: _lanAccess,
    apiKey: _apiKey.text.trim(),
  );

  void _persist() {
    _controller.saveSettings(_settings());
  }

  void _touch() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _persist);
  }

  void _selectBackend(String? backend) {
    if (backend == null || backend == _backend) return;
    final defaults = ServerSettings.defaults(backend);
    setState(() {
      _backend = backend;
      _ctx.text = defaults.contextSize.toString();
      _threads.text = defaults.threads.toString();
      _ngl.text = defaults.ngl.toString();
      _ub.text = defaults.ub.toString();
      _flashAttention = defaults.flashAttention;
    });
    _persist();
  }

  Future<void> _start() async {
    _saveTimer?.cancel();
    await _controller.saveSettings(_settings());
    await _controller.startServer();
  }

  bool _supported(String backend, AppStatus? status) {
    if (backend != 'adreno' && backend != 'hexagon') return true;
    return status?.socQualcomm ?? false;
  }

  String _backendHint(AppStatus? status) {
    if (!_supported(_backend, status)) {
      return 'This backend needs a Qualcomm Snapdragon SoC. Detected: ${status?.socName ?? 'unknown'}. Use CPU instead.';
    }
    return switch (_backend) {
      'adreno' => 'Runs on the Adreno GPU through OpenCL. If the server fails to start, switch back to CPU.',
      'hexagon' => 'Experimental: offloads to the Hexagon NPU (HTP0). Needs a Snapdragon with a recent HTP stack; falls back to CPU otherwise.',
      _ => 'Runs on the CPU with llama.cpp ARM optimizations. Works on every arm64 device.',
    };
  }

  Future<void> _copy(String text, String message) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _toggleLan(bool value) {
    setState(() {
      _lanAccess = value;
      if (value && _apiKey.text.trim().length < 8) _apiKey.text = newApiKey();
    });
    _touch();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final status = controller.status;
    final server = controller.server;
    final backend = status?.backends[_backend];
    final installed = backend?.installed ?? false;
    final busy = server.busy || server.ready;
    final scheme = Theme.of(context).colorScheme;
    final supported = _supported(_backend, status);
    final lanKeyOk = _apiKey.text.trim().length >= 8;
    final canStart =
        installed &&
        status?.model != null &&
        !controller.isInstalling(_backend) &&
        supported &&
        (!_lanAccess || lanKeyOk);

    return Scaffold(
      appBar: AppBar(title: const Text('Server')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          if (controller.error != null) ...[
            _Banner(
              text: controller.error!,
              color: scheme.errorContainer,
              onColor: scheme.onErrorContainer,
              icon: Icons.error_outline,
              onClose: controller.clearError,
            ),
            const SizedBox(height: 12),
          ],
          if (controller.notice != null) ...[
            _Banner(
              text: controller.notice!,
              color: scheme.secondaryContainer,
              onColor: scheme.onSecondaryContainer,
              icon: Icons.info_outline,
              onClose: controller.clearNotice,
            ),
            const SizedBox(height: 12),
          ],
          _Section(
            title: 'Status',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      server.ready
                          ? Icons.check_circle
                          : server.state == 'error'
                          ? Icons.error
                          : Icons.pause_circle_outline,
                      color: server.ready
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(switch (server.state) {
                        'ready' => 'Running on port ${server.port}',
                        'starting' => 'Loading model…',
                        'error' => server.message ?? 'Error',
                        'stopped' => 'Stopped',
                        _ => 'Not running',
                      }, style: Theme.of(context).textTheme.titleSmall),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  [
                    if (status != null) '${status.abi} · Android ${status.sdk}',
                    if (status != null) status.freeSpaceLabel,
                  ].join(' · '),
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                if (status != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${status.socName}${status.socQualcomm ? ' · Snapdragon' : ''}'
                    ' · Vulkan hardware ${status.vulkan ? 'available' : 'unavailable'}',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: server.ready
                      ? OutlinedButton.icon(
                          onPressed: controller.stopServer,
                          icon: const Icon(Icons.stop),
                          label: const Text('Stop server'),
                        )
                      : FilledButton.icon(
                          onPressed: canStart ? _start : null,
                          icon: server.busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.play_arrow),
                          label: Text(
                            server.busy ? 'Starting…' : 'Start server',
                          ),
                        ),
                ),
                if (busy) const SizedBox(height: 8),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _Section(
            title: 'Model',
            trailing: TextButton(
              onPressed: controller.pickModel,
              child: Text(status?.model == null ? 'Choose' : 'Change'),
            ),
            child: status?.model == null
                ? Text(
                    'No GGUF model selected. Files are copied into app storage and never leave the device.',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        status!.model!.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        status.model!.sizeLabel,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          _Section(
            title: 'Backend',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _backend,
                  items: [
                    for (final id in status?.backends.keys ?? const ['cpu'])
                      DropdownMenuItem(
                        value: id,
                        enabled: _supported(id, status),
                        child: Text(
                          _supported(id, status)
                              ? backendLabel(id)
                              : '${backendLabel(id)} · Snapdragon only',
                          style: _supported(id, status)
                              ? null
                              : TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
                  ],
                  onChanged: busy ? null : _selectBackend,
                ),
                const SizedBox(height: 8),
                Text(
                  _backendHint(status),
                  style: TextStyle(
                    color: supported ? scheme.onSurfaceVariant : scheme.error,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 12),
                if (controller.isInstalling(_backend))
                  Column(
                    children: [
                      LinearProgressIndicator(
                        value: controller.downloadProgress,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        controller.downloadProgress == null
                            ? 'Extracting…'
                            : 'Downloading ${(controller.downloadProgress! * 100).toStringAsFixed(0)}%',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          installed
                              ? 'Installed · ${_size(backend?.bytes ?? 0)}'
                              : 'Not installed · ${_size(backend?.bytes ?? 0)}',
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      if (installed)
                        TextButton.icon(
                          onPressed: server.ready || server.busy
                              ? null
                              : () => controller.deleteBackend(_backend),
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text('Remove'),
                        )
                      else
                        FilledButton.tonalIcon(
                          onPressed: _supported(_backend, status)
                              ? () => controller.downloadBackend(_backend)
                              : null,
                          icon: const Icon(Icons.download, size: 18),
                          label: const Text('Download'),
                        ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _Section(
            title: 'OpenAI-compatible API',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _UrlLine(
                  label: 'This device',
                  url: 'http://127.0.0.1:${server.port}/v1',
                  onCopy: () => _copy(
                    'http://127.0.0.1:${server.port}/v1',
                    'Local API URL copied',
                  ),
                ),
                if (_lanAccess) ...[
                  const SizedBox(height: 8),
                  _UrlLine(
                    label: status?.wifiIp == null
                        ? 'LAN (connect to Wi-Fi)'
                        : 'LAN',
                    url: status?.wifiIp == null
                        ? ''
                        : 'http://${status!.wifiIp}:${server.port}/v1',
                    onCopy: () => _copy(
                      'http://${status?.wifiIp}:${server.port}/v1',
                      'LAN API URL copied',
                    ),
                  ),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Allow LAN access'),
                  subtitle: Text(
                    busy ? 'Restart the server to apply this change.' : 'Listens on all network interfaces. An API key is required.',
                    style: const TextStyle(fontSize: 12),
                  ),
                  value: _lanAccess,
                  onChanged: busy ? null : _toggleLan,
                ),
                if (_lanAccess) ...[
                  TextField(
                    controller: _apiKey,
                    readOnly: busy,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'API key',
                      helperText: lanKeyOk
                          ? 'Clients send Authorization: Bearer <key>.'
                          : 'At least 8 characters.',
                      errorText: lanKeyOk ? null : 'Too short',
                      suffixIcon: IconButton(
                        tooltip: 'Copy key',
                        onPressed: () =>
                            _copy(_apiKey.text.trim(), 'API key copied'),
                        icon: const Icon(Icons.copy, size: 18),
                      ),
                    ),
                    onChanged: (_) {
                      setState(() {});
                      _touch();
                    },
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: busy
                          ? null
                          : () {
                              setState(() => _apiKey.text = newApiKey());
                              _touch();
                            },
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Generate new key'),
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  'POST /v1/chat/completions\nPOST /v1/completions\nGET  /v1/models',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Use the URL above as the OpenAI base URL in other apps. When a key is set, send it as a Bearer token and keep it secret.',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                if (_lanAccess)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'LAN traffic is plain HTTP. Only enable this on a trusted network; anyone who can sniff it can capture the key.',
                      style: TextStyle(color: scheme.error, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _Section(
            title: 'Options',
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _NumberField(
                        label: 'Context',
                        controller: _ctx,
                        onChanged: _touch,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _NumberField(
                        label: 'Threads',
                        controller: _threads,
                        onChanged: _touch,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _NumberField(
                        label: 'GPU layers',
                        controller: _ngl,
                        onChanged: _touch,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _NumberField(
                        label: 'Batch',
                        controller: _ub,
                        onChanged: _touch,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  key: ValueKey('fa-$_backend'),
                  initialValue: _flashAttention,
                  decoration: const InputDecoration(
                    labelText: 'Flash attention',
                  ),
                  items: const [
                    DropdownMenuItem(value: 'auto', child: Text('Auto')),
                    DropdownMenuItem(value: 'on', child: Text('On')),
                    DropdownMenuItem(value: 'off', child: Text('Off')),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _flashAttention = value);
                    _touch();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _LogCard(controller: controller, scroll: _logScroll),
        ],
      ),
    );
  }
}

String _size(int bytes) {
  if (bytes <= 0) return '0 MB';
  final mb = bytes / (1024 * 1024);
  return mb >= 1024
      ? '${(mb / 1024).toStringAsFixed(1)} GB'
      : '${mb.toStringAsFixed(0)} MB';
}

class _UrlLine extends StatelessWidget {
  const _UrlLine({
    required this.label,
    required this.url,
    required this.onCopy,
  });

  final String label;
  final String url;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 2),
              SelectableText(
                url.isEmpty ? '—' : url,
                maxLines: 1,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Copy URL',
          onPressed: url.isEmpty ? null : onCopy,
          icon: const Icon(Icons.copy, size: 18),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.label,
    required this.controller,
    required this.onChanged,
  });

  final String label;
  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(labelText: label),
      onChanged: (_) => onChanged(),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.text,
    required this.color,
    required this.onColor,
    required this.icon,
    required this.onClose,
  });

  final String text;
  final Color color;
  final Color onColor;
  final IconData icon;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: onColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(color: onColor, fontSize: 13)),
          ),
          IconButton(
            onPressed: onClose,
            icon: Icon(Icons.close, size: 18, color: onColor),
          ),
        ],
      ),
    );
  }
}

class _LogCard extends StatelessWidget {
  const _LogCard({required this.controller, required this.scroll});

  final AppController controller;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final logs = controller.logs;
    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          title: const Text('Server log'),
          subtitle: Text(
            '${logs.length} lines',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          children: [
            Container(
              height: 220,
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: logs.isEmpty
                  ? Text(
                      'Nothing yet.',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    )
                  : ListView.builder(
                      controller: scroll,
                      itemCount: logs.length,
                      itemBuilder: (context, index) => Text(
                        logs[index],
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          height: 1.35,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
