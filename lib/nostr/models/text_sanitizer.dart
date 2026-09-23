/// Replaces unpaired UTF-16 surrogates with U+FFFD to keep the text valid.
String sanitizeUtf16(String input) {
  final buffer = StringBuffer();
  for (var i = 0; i < input.length; i++) {
    final unit = input.codeUnitAt(i);
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      final next = i + 1 < input.length ? input.codeUnitAt(i + 1) : null;
      if (next != null && next >= 0xDC00 && next <= 0xDFFF) {
        buffer.writeCharCode(unit);
        buffer.writeCharCode(next);
        i++;
      } else {
        buffer.writeCharCode(0xFFFD);
      }
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      buffer.writeCharCode(0xFFFD);
    } else {
      buffer.writeCharCode(unit);
    }
  }
  return buffer.toString();
}

/// At most the first [length] UTF-16 units of [input], never ending on the
/// first half of a surrogate pair, which text layout would reject.
String safePrefix(String input, int length) {
  if (input.length <= length) return input;
  final end = length > 0 && _isHighSurrogate(input.codeUnitAt(length - 1))
      ? length - 1
      : length;
  return input.substring(0, end);
}

/// At most the last [length] UTF-16 units of [input], never starting on the
/// second half of a surrogate pair.
String safeSuffix(String input, int length) {
  if (input.length <= length) return input;
  final start = input.length - length;
  return input.substring(
    _isLowSurrogate(input.codeUnitAt(start)) ? start + 1 : start,
  );
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;
