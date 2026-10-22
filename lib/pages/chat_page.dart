import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/chat_client.dart';
import '../core/conversations.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _Msg {
  _Msg(this.role, [String initial = '']) : text = ValueNotifier(initial);

  final String role;
  final ValueNotifier<String> text;
  final ValueNotifier<ChatStats?> stats = ValueNotifier(null);

  void dispose() {
    text.dispose();
    stats.dispose();
  }
}

class _Session {
  _Session(this.conversation) {
    for (final message in conversation.messages) {
      messages.add(
        _Msg(message.role, message.content)..stats.value = message.stats,
      );
      if (message.content.trim().isNotEmpty) {
        history.add({'role': message.role, 'content': message.content});
      }
    }
  }

  final Conversation conversation;
  final List<_Msg> messages = [];
  final List<Map<String, String>> history = [];

  void persistMessages() {
    conversation.messages
      ..clear()
      ..addAll(
        messages
            .where((m) => m.text.value.trim().isNotEmpty)
            .map(
              (m) => ChatMessage(
                role: m.role,
                content: m.text.value,
                stats: m.stats.value,
              ),
            ),
      );
  }

  void dispose() {
    for (final message in messages) {
      message.dispose();
    }
  }
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  final List<_Session> _sessions = [];
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final ChatClient _client = ChatClient();
  final StringBuffer _buffer = StringBuffer();

  int _active = 0;
  bool _loaded = false;
  Timer? _flushTimer;
  Timer? _saveTimer;
  _Msg? _activeMsg;
  String? _streamingId;

  _Session? get _session =>
      _active >= 0 && _active < _sessions.length ? _sessions[_active] : null;

  bool get _streaming => _streamingId != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    var conversations = await ConversationStore.load();
    if (conversations.isEmpty) {
      conversations = [
        Conversation(id: newConversationId(), title: 'New chat'),
      ];
    }
    if (!mounted) return;
    setState(() {
      _sessions.addAll(conversations.map(_Session.new));
      _active = _sessions.length - 1;
      _loaded = true;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _persistNow();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flushTimer?.cancel();
    _saveTimer?.cancel();
    _client.cancel();
    _persistNow();
    _input.dispose();
    _scroll.dispose();
    for (final session in _sessions) {
      session.dispose();
    }
    super.dispose();
  }

  void _select(int index) {
    if (index == _active || index < 0 || index >= _sessions.length) return;
    setState(() => _active = index);
    _scrollToBottom();
  }

  void _newConversation() {
    setState(() {
      _sessions.add(
        _Session(Conversation(id: newConversationId(), title: 'New chat')),
      );
      _active = _sessions.length - 1;
    });
    _persist();
  }

  Future<void> _rename() async {
    final session = _session;
    if (session == null) return;
    final controller = TextEditingController(text: session.conversation.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename chat'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(labelText: 'Title'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    final next = title?.trim();
    if (next == null || next.isEmpty) return;
    setState(() => session.conversation.title = next);
    _persist();
  }

  Future<void> _delete() async {
    final session = _session;
    if (session == null) return;
    if (session.messages.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete chat?'),
          content: Text(
            '“${session.conversation.title}” will be removed from this device.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    if (!mounted) return;
    if (_streaming) {
      _client.cancel();
      _finish();
    }
    setState(() {
      _sessions.removeAt(_active);
      session.dispose();
      if (_sessions.isEmpty) {
        _sessions.add(
          _Session(Conversation(id: newConversationId(), title: 'New chat')),
        );
      }
      _active = _active.clamp(0, _sessions.length - 1);
    });
    _persist();
  }

  void _clear() {
    final session = _session;
    if (session == null) return;
    if (_streaming) {
      _client.cancel();
      _finish();
    }
    setState(() {
      for (final message in session.messages) {
        message.dispose();
      }
      session.messages.clear();
      session.history.clear();
    });
    _persist();
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || _streaming) return;
    if (!widget.controller.server.ready) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Start the server first (Server tab).')),
      );
      return;
    }
    final session = _session;
    if (session == null) return;
    _input.clear();
    final assistant = _Msg('assistant');
    setState(() {
      session.messages.add(_Msg('user', text));
      session.messages.add(assistant);
      session.history.add({'role': 'user', 'content': text});
      if (session.conversation.title == 'New chat') {
        session.conversation.title = _titleFrom(text);
      }
      _activeMsg = assistant;
      _streamingId = session.conversation.id;
    });
    _scrollToBottom();
    _persist();

    _client.send(
      messages: List.unmodifiable(session.history),
      apiKey: widget.controller.settings.apiKey.trim(),
      onToken: _onToken,
      onStats: _onStats,
      onDone: _finish,
      onError: (message) => _finish(error: message),
    );
  }

  String _titleFrom(String text) {
    final line = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return line.length > 32 ? '${line.substring(0, 32)}…' : line;
  }

  void _onToken(String token) {
    _buffer.write(token);
    _flushTimer ??= Timer(const Duration(milliseconds: 50), () {
      _flushTimer = null;
      _flushBuffer();
      _scrollToBottom();
    });
  }

  void _onStats(ChatStats stats) {
    _activeMsg?.stats.value = stats;
  }

  void _flushBuffer() {
    final active = _activeMsg;
    if (active == null || _buffer.isEmpty) return;
    active.text.value += _buffer.toString();
    _buffer.clear();
  }

  void _finish({String? error}) {
    _flushTimer?.cancel();
    _flushTimer = null;
    _flushBuffer();
    final active = _activeMsg;
    _Session? session;
    for (final candidate in _sessions) {
      if (candidate.conversation.id == _streamingId) {
        session = candidate;
        break;
      }
    }
    if (active != null && session != null) {
      var content = active.text.value.trim();
      if (content.isEmpty) {
        active.text.value = error ?? '(no output)';
        active.stats.value = null;
      } else {
        if (error != null) {
          active.text.value += '\n\n⚠ $error';
          content = active.text.value.trim();
        }
        session.history.add({'role': 'assistant', 'content': content});
      }
    }
    if (!mounted) return;
    setState(() {
      _activeMsg = null;
      _streamingId = null;
    });
    _persist();
    _scrollToBottom();
  }

  void _stop() {
    _client.cancel();
    _finish();
  }

  void _persist() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 700), _persistNow);
  }

  Future<void> _persistNow() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_sessions.isEmpty) return;
    for (final session in _sessions) {
      session.persistMessages();
    }
    await ConversationStore.save(
      _sessions.map((session) => session.conversation).toList(),
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final server = widget.controller.server;
    final statusText = switch (server.state) {
      'ready' => 'ready on port ${server.port}',
      'starting' => 'starting…',
      'error' => server.message ?? 'error',
      _ => 'server stopped',
    };
    final session = _session;
    final canSend = server.ready && !_streaming;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Chat'),
            Text(
              statusText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: server.ready ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _newConversation,
            tooltip: 'New chat',
            icon: const Icon(Icons.add_comment_outlined),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'rename':
                  _rename();
                case 'clear':
                  _clear();
                case 'delete':
                  _delete();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'rename', child: Text('Rename chat')),
              if (session?.messages.isNotEmpty ?? false)
                const PopupMenuItem(value: 'clear', child: Text('Clear chat')),
              const PopupMenuItem(value: 'delete', child: Text('Delete chat')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_loaded)
            _ChatTabs(
              sessions: _sessions,
              active: _active,
              onSelected: _select,
              onNew: _newConversation,
            ),
          Expanded(
            child: !_loaded
                ? const Center(child: CircularProgressIndicator())
                : session == null || session.messages.isEmpty
                ? _EmptyChat(ready: server.ready)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    itemCount: session.messages.length,
                    itemBuilder: (context, index) {
                      final message = session.messages[index];
                      return _Bubble(
                        message: message,
                        streaming: _streaming && message == _activeMsg,
                      );
                    },
                  ),
          ),
          _InputBar(
            controller: _input,
            streaming: _streaming,
            enabled: canSend,
            onSend: _send,
            onStop: _stop,
          ),
        ],
      ),
    );
  }
}

class _ChatTabs extends StatelessWidget {
  const _ChatTabs({
    required this.sessions,
    required this.active,
    required this.onSelected,
    required this.onNew,
  });

  final List<_Session> sessions;
  final int active;
  final ValueChanged<int> onSelected;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: sessions.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (index == sessions.length) {
            return IconButton(
              onPressed: onNew,
              tooltip: 'New chat',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add),
            );
          }
          final session = sessions[index];
          return ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 170),
            child: ChoiceChip(
              selected: index == active,
              onSelected: (_) => onSelected(index),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              label: Text(
                session.conversation.title,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.ready});

  final bool ready;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 56, color: scheme.primary),
            const SizedBox(height: 16),
            Text(
              ready ? 'Ask anything' : 'No server running',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              ready
                  ? 'Messages are generated on this device.'
                  : 'Pick a GGUF model and start the server on the Server tab.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.streaming});

  final _Msg message;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final user = message.role == 'user';
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.85,
        ),
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: user ? scheme.primaryContainer : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(user ? 18 : 4),
            bottomRight: Radius.circular(user ? 4 : 18),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<String>(
              valueListenable: message.text,
              builder: (context, value, _) {
                final showHint = value.isEmpty && streaming;
                return Text(
                  showHint ? '…' : value,
                  style: TextStyle(
                    color: user ? scheme.onPrimaryContainer : scheme.onSurface,
                    height: 1.4,
                    fontStyle: showHint ? FontStyle.italic : FontStyle.normal,
                  ),
                );
              },
            ),
            if (!user)
              ValueListenableBuilder<ChatStats?>(
                valueListenable: message.stats,
                builder: (context, stats, _) {
                  if (stats == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      streaming ? '${stats.footer} · generating' : stats.footer,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.streaming,
    required this.enabled,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool streaming;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled || streaming,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(hintText: 'Message'),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 52,
              height: 52,
              child: IconButton.filled(
                tooltip: streaming ? 'Stop' : 'Send',
                onPressed: streaming ? onStop : (enabled ? onSend : null),
                icon: Icon(streaming ? Icons.stop : Icons.arrow_upward),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
