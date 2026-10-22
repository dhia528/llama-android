import 'package:flutter/material.dart';

import 'core/app_controller.dart';
import 'core/theme.dart';
import 'pages/chat_page.dart';
import 'pages/server_page.dart';
import 'pages/webui_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LlamaApp());
}

class LlamaApp extends StatefulWidget {
  const LlamaApp({super.key});

  @override
  State<LlamaApp> createState() => _LlamaAppState();
}

class _LlamaAppState extends State<LlamaApp> {
  final AppController _controller = AppController();

  @override
  void initState() {
    super.initState();
    _controller.init();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => MaterialApp(
        title: 'llama.cpp',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: _controller.loading
            ? const Scaffold(body: Center(child: CircularProgressIndicator()))
            : HomeShell(controller: _controller),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final ready = controller.server.ready;
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          ChatPage(controller: controller),
          ServerPage(controller: controller),
          WebUiPage(controller: controller),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.chat_bubble_outline),
            selectedIcon: const Icon(Icons.chat_bubble),
            label: 'Chat',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: controller.server.busy,
              child: const Icon(Icons.memory_outlined),
            ),
            selectedIcon: const Icon(Icons.memory),
            label: 'Server',
          ),
          NavigationDestination(
            icon: Icon(ready ? Icons.public : Icons.public_off),
            label: 'Web UI',
          ),
        ],
      ),
    );
  }
}
