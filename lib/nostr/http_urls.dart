/// Matches an HTTP(S) URL, including any trailing punctuation.
final httpUrlPattern = RegExp(r'https?://[^\s<>"]+', caseSensitive: false);

const _urlTrailingPunctuation = '.,;:!?\'*';
const _urlClosers = {')': '(', ']': '[', '}': '{'};

/// Sentence punctuation and unmatched closers after a URL belong to the text.
String trimUrlEnd(String url) {
  // Counted once up front, so a long run of closers stays linear.
  final counts = <String, int>{};
  for (var i = 0; i < url.length; i++) {
    final char = url[i];
    if (_urlClosers.containsKey(char) || _urlClosers.containsValue(char)) {
      counts[char] = (counts[char] ?? 0) + 1;
    }
  }

  var end = url.length;
  while (end > 0) {
    final last = url[end - 1];
    final opener = _urlClosers[last];
    final unmatched =
        opener != null && (counts[last] ?? 0) > (counts[opener] ?? 0);
    if (!_urlTrailingPunctuation.contains(last) && !unmatched) break;
    // Only closers are counted; openers are never trimmed.
    if (opener != null) counts[last] = counts[last]! - 1;
    end--;
  }
  return url.substring(0, end);
}

/// [text] without the URLs in [urls], and without any line they empty out.
String withoutUrls(String text, Set<String> urls) {
  final lines = <String>[];
  for (final line in text.split('\n')) {
    var removed = false;
    final kept = line.replaceAllMapped(httpUrlPattern, (match) {
      final url = trimUrlEnd(match[0]!);
      if (!urls.contains(url)) return match[0]!;
      removed = true;
      return match[0]!.substring(url.length);
    });
    if (!removed) {
      lines.add(line);
    } else if (kept.trim().isNotEmpty) {
      lines.add(kept.trimRight());
    }
  }
  return lines.join('\n').trimRight();
}
