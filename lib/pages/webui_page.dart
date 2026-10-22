import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/app_controller.dart';

class WebUiPage extends StatefulWidget {
  const WebUiPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<WebUiPage> createState() => _WebUiPageState();
}

class _WebUiPageState extends State<WebUiPage> {
  WebViewController? _web;
  String? _error;

  @override
  void initState() {
    super.initState();
    final server = widget.controller.server;
    if (server.ready) _create(server.port);
  }

  @override
  void didUpdateWidget(covariant WebUiPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ready = widget.controller.server.ready;
    if (ready && _web == null) {
      _create(widget.controller.server.port);
    } else if (!ready && _web != null) {
      _web = null;
      _error = null;
    }
  }

  void _create(int port) {
    late final WebViewController web;
    web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onWebResourceError: (error) {
            if (!mounted) return;
            setState(() => _error = error.description);
          },
          onPageFinished: (_) async {
            if (mounted) setState(() => _error = null);
            final key = widget.controller.settings.apiKey.trim();
            if (key.isEmpty) return;
            await web.runJavaScript('''
(function () {
  try {
    var name = 'LlamaUi.config';
    var config = JSON.parse(localStorage.getItem(name) || '{}');
    if (config.apiKey !== ${jsonEncode(key)}) {
      config.apiKey = ${jsonEncode(key)};
      localStorage.setItem(name, JSON.stringify(config));
      location.reload();
    }
  } catch (e) {}
})();''');
          },
        ),
      )
      ..loadRequest(Uri.parse('http://127.0.0.1:$port/'));
    _web = web;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final server = widget.controller.server;
    final web = _web;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Web UI'),
        actions: [
          if (web != null)
            IconButton(
              tooltip: 'Reload',
              onPressed: () => web.reload(),
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: web == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.public_off,
                      size: 56,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Start the server to open llama.cpp\'s built-in web UI.',
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'The page is served locally on port ${server.port}.',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : Column(
              children: [
                if (_error != null)
                  Container(
                    width: double.infinity,
                    color: scheme.errorContainer,
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: scheme.onErrorContainer,
                        fontSize: 12,
                      ),
                    ),
                  ),
                Expanded(child: WebViewWidget(controller: web)),
              ],
            ),
    );
  }
}
