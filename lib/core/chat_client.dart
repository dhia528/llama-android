import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'conversations.dart';
import 'sse.dart';

typedef ChatStatsCallback = void Function(ChatStats stats);

class ChatClient {
  http.Client? _client;

  bool get active => _client != null;

  Future<void> send({
    required List<Map<String, String>> messages,
    required void Function(String token) onToken,
    required void Function() onDone,
    required void Function(String error) onError,
    ChatStatsCallback? onStats,
    String apiKey = '',
  }) async {
    cancel();
    final client = http.Client();
    _client = client;
    try {
      final request =
          http.Request(
              'POST',
              Uri.parse('http://127.0.0.1:8080/v1/chat/completions'),
            )
            ..headers['content-type'] = 'application/json'
            ..body = jsonEncode({
              'messages': messages,
              'stream': true,
              'cache_prompt': true,
              'timings_per_token': true,
            });
      if (apiKey.isNotEmpty) {
        request.headers['authorization'] = 'Bearer $apiKey';
      }

      final response = await client.send(request);
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        onError('HTTP ${response.statusCode}: ${body.trim()}');
        return;
      }

      final decoder = SseDecoder();
      var finished = false;
      await for (final chunk in response.stream.transform(utf8.decoder)) {
        for (final data in decoder.add(chunk)) {
          if (data == '[DONE]') {
            finished = true;
            break;
          }
          if (!data.startsWith('{')) continue;
          final json = jsonDecode(data);
          final token = _content(json);
          if (token != null && token.isNotEmpty) onToken(token);
          final stats = parseChatStats(json);
          if (stats != null) onStats?.call(stats);
        }
        if (finished) break;
      }
      if (_client == client) onDone();
    } on http.ClientException {
      if (_client == client) {
        onError('Connection lost. Is the server still running?');
      }
    } catch (error) {
      if (_client == client) onError(error.toString());
    } finally {
      if (_client == client) _client = null;
      client.close();
    }
  }

  void cancel() {
    _client?.close();
    _client = null;
  }

  String? _content(Object? json) {
    if (json is! Map) return null;
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final delta = choices.first is Map ? (choices.first as Map)['delta'] : null;
    final content = delta is Map ? delta['content'] : null;
    return content is String ? content : null;
  }
}

ChatStats? parseChatStats(Object? json) {
  if (json is! Map) return null;
  final timings = json['timings'];
  final usage = json['usage'];
  if (timings is! Map && usage is! Map) return null;
  int count(Object? map, String key) =>
      map is Map ? (map[key] as num?)?.toInt() ?? 0 : 0;
  double? rate(Object? map, String key) =>
      map is Map ? (map[key] as num?)?.toDouble() : null;
  return ChatStats(
    tokens: count(timings, 'predicted_n') != 0
        ? count(timings, 'predicted_n')
        : count(usage, 'completion_tokens'),
    promptTokens: count(timings, 'prompt_n') != 0
        ? count(timings, 'prompt_n')
        : count(usage, 'prompt_tokens'),
    cachedTokens: count(timings, 'cache_n'),
    genTps: rate(timings, 'predicted_per_second'),
    promptTps: rate(timings, 'prompt_per_second'),
  );
}
