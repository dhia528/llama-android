import 'package:flutter_test/flutter_test.dart';
import 'package:llama_android/core/chat_client.dart';
import 'package:llama_android/core/conversations.dart';

void main() {
  test('parses llama.cpp timings and usage fallback', () {
    final stats = parseChatStats({
      'timings': {
        'prompt_n': 12,
        'cache_n': 8,
        'predicted_n': 40,
        'prompt_per_second': 120.5,
        'predicted_per_second': 17.25,
      },
    })!;
    expect(stats.tokens, 40);
    expect(stats.promptTokens, 12);
    expect(stats.cachedTokens, 8);
    expect(stats.genTps, 17.25);
    expect(stats.promptTps, 120.5);

    final usageOnly = parseChatStats({
      'usage': {'prompt_tokens': 5, 'completion_tokens': 9},
    })!;
    expect(usageOnly.tokens, 9);
    expect(usageOnly.promptTokens, 5);
    expect(usageOnly.genTps, isNull);
    expect(parseChatStats({'choices': []}), isNull);
  });

  test('round-trips conversations', () {
    final conversation = Conversation(id: 'c1', title: 'Hello')
      ..messages.add(const ChatMessage(role: 'user', content: 'hi'))
      ..messages.add(
        const ChatMessage(
          role: 'assistant',
          content: 'hey',
          stats: ChatStats(tokens: 3, genTps: 12.5),
        ),
      );

    final loaded = Conversation.fromJson(conversation.toJson());
    expect(loaded.id, 'c1');
    expect(loaded.title, 'Hello');
    expect(loaded.messages, hasLength(2));
    expect(loaded.messages.first.content, 'hi');
    expect(loaded.messages.last.stats!.tokens, 3);
    expect(loaded.messages.last.stats!.genTps, 12.5);
    expect(loaded.messages.last.stats!.footer, '12.5 t/s · 3 tok');
  });
}
