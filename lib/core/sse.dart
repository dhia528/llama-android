/// Incremental Server-Sent Events decoder.
///
/// Feed it decoded text chunks (chunk boundaries may fall anywhere) and it
/// returns the complete `data` payloads seen so far.
class SseDecoder {
  String _buffer = '';
  final List<String> _data = [];

  List<String> add(String chunk) {
    _buffer += chunk;
    final out = <String>[];
    while (true) {
      final newline = _buffer.indexOf('\n');
      if (newline < 0) break;
      var line = _buffer.substring(0, newline);
      _buffer = _buffer.substring(newline + 1);
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);

      if (line.isEmpty) {
        _emit(out);
      } else if (line.startsWith('data:')) {
        var value = line.substring(5);
        if (value.startsWith(' ')) value = value.substring(1);
        _data.add(value);
      } else if (line.startsWith('{') || line.startsWith('[')) {
        _emit(out);
        out.add(line);
      }
    }
    return out;
  }

  void _emit(List<String> out) {
    if (_data.isEmpty) return;
    out.add(_data.join('\n'));
    _data.clear();
  }
}
