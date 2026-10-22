import 'package:flutter_test/flutter_test.dart';
import 'package:llama_android/core/sse.dart';

void main() {
  test('decodes complete events', () {
    final decoder = SseDecoder();
    expect(decoder.add('data: {"a":1}\n\ndata: [DONE]\n\n'), [
      '{"a":1}',
      '[DONE]',
    ]);
  });

  test('survives chunks split mid-line and mid-event', () {
    final decoder = SseDecoder();
    expect(decoder.add('data: he'), isEmpty);
    expect(decoder.add('llo\n'), isEmpty);
    expect(decoder.add('\n'), ['hello']);
    expect(decoder.add('data: a\r\ndata: b\r\n\r\n'), ['a\nb']);
  });

  test('accepts bare json lines and ignores comments', () {
    final decoder = SseDecoder();
    expect(decoder.add(': keep-alive\n{"x":1}\n'), ['{"x":1}']);
  });
}
