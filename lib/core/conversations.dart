import 'dart:convert';
import 'dart:math';

import 'native.dart';

class ChatStats {
  const ChatStats({
    this.tokens = 0,
    this.promptTokens = 0,
    this.cachedTokens = 0,
    this.genTps,
    this.promptTps,
  });

  final int tokens;
  final int promptTokens;
  final int cachedTokens;
  final double? genTps;
  final double? promptTps;

  factory ChatStats.fromJson(Map<String, dynamic> json) => ChatStats(
    tokens: (json['tokens'] as num?)?.toInt() ?? 0,
    promptTokens: (json['promptTokens'] as num?)?.toInt() ?? 0,
    cachedTokens: (json['cachedTokens'] as num?)?.toInt() ?? 0,
    genTps: (json['genTps'] as num?)?.toDouble(),
    promptTps: (json['promptTps'] as num?)?.toDouble(),
  );

  Map<String, Object?> toJson() => {
    'tokens': tokens,
    'promptTokens': promptTokens,
    'cachedTokens': cachedTokens,
    if (genTps != null) 'genTps': genTps,
    if (promptTps != null) 'promptTps': promptTps,
  };

  String get footer {
    final parts = <String>[
      if (genTps != null) '${genTps!.toStringAsFixed(1)} t/s',
      '$tokens tok',
      if (promptTps != null) 'prompt ${promptTps!.toStringAsFixed(0)} t/s',
    ];
    return parts.join(' · ');
  }
}

class ChatMessage {
  const ChatMessage({required this.role, required this.content, this.stats});

  final String role;
  final String content;
  final ChatStats? stats;

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    role: json['role'] as String? ?? 'assistant',
    content: json['content'] as String? ?? '',
    stats: json['stats'] is Map
        ? ChatStats.fromJson(Map<String, dynamic>.from(json['stats'] as Map))
        : null,
  );

  Map<String, Object?> toJson() => {
    'role': role,
    'content': content,
    if (stats != null) 'stats': stats!.toJson(),
  };
}

class Conversation {
  Conversation({
    required this.id,
    required this.title,
    List<ChatMessage>? messages,
  }) : messages = messages ?? [];

  final String id;
  String title;
  final List<ChatMessage> messages;
  int updatedAt = DateTime.now().millisecondsSinceEpoch;

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    id: json['id'] as String? ?? newConversationId(),
    title: json['title'] as String? ?? 'New chat',
    messages: (json['messages'] as List? ?? [])
        .whereType<Map>()
        .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'updatedAt': updatedAt,
    'messages': messages.map((m) => m.toJson()).toList(),
  };
}

String newConversationId() {
  final random = Random.secure();
  return '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
      '${random.nextInt(1 << 32).toRadixString(36)}';
}

class ConversationStore {
  // shortcut: generous caps keep chats.json under the native 8 MB limit.
  static const _maxConversations = 100;
  static const _maxMessages = 400;

  static Future<List<Conversation>> load() async {
    final raw = await Native.loadChats();
    if (raw == null || raw.isEmpty) return [];
    try {
      final data = jsonDecode(raw);
      if (data is! List) return [];
      final conversations = data
          .whereType<Map>()
          .map((e) => Conversation.fromJson(Map<String, dynamic>.from(e)))
          .take(_maxConversations)
          .toList();
      for (final conversation in conversations) {
        if (conversation.messages.length > _maxMessages) {
          conversation.messages.removeRange(
            0,
            conversation.messages.length - _maxMessages,
          );
        }
      }
      return conversations;
    } catch (_) {
      return [];
    }
  }

  static Future<bool> save(List<Conversation> conversations) async {
    final trimmed = conversations.length > _maxConversations
        ? conversations.sublist(conversations.length - _maxConversations)
        : conversations;
    final data = trimmed.map((c) {
      if (c.messages.length > _maxMessages) {
        c.messages.removeRange(0, c.messages.length - _maxMessages);
      }
      c.updatedAt = DateTime.now().millisecondsSinceEpoch;
      return c.toJson();
    }).toList();
    return Native.saveChats(jsonEncode(data));
  }
}
