/// Client-side privacy guard. Same rules as the server's `PropertyGuard`
/// (VectorSignal.Core/PropertyGuard.cs), so sensitive values are removed on
/// the device before they are ever sent. The server applies them again.
class PropertyGuard {
  PropertyGuard._();

  /// Blocked when they appear anywhere in the key ("userPassword", "wallet_balance").
  static const List<String> deniedSubstrings = [
    'password',
    'passwd',
    'secret',
    'token',
    'balance',
    'amount',
    'account',
    'phone',
    'mobile',
    'email',
    'address',
    'passport',
    'idnumber',
  ];

  /// Short words blocked only as a whole word ("pin", "pinCode"), so
  /// "mapping" or "spinner" pass.
  static const List<String> deniedWords = [
    'pin',
    'pwd',
    'otp',
    'cvv',
    'cvc',
    'card',
    'iban',
    'bank',
    'ssn',
    'nric',
  ];

  static const int maxProperties = 50;
  static const int maxStringLength = 500;
  static const int maxKeyLength = 100;

  static bool isDenied(String key) {
    final flat = key
        .replaceAll('_', '')
        .replaceAll('-', '')
        .replaceAll('.', '')
        .toLowerCase();
    if (deniedSubstrings.any(flat.contains)) {
      return true;
    }
    return splitWords(key).any(deniedWords.contains);
  }

  /// "cardNumber" / "card_number" / "CardNumber" -> ["card", "number"].
  static List<String> splitWords(String key) {
    final words = <String>[];
    final word = StringBuffer();
    for (var i = 0; i < key.length; i++) {
      final c = key[i];
      if (!_isLetterOrDigit(c)) {
        if (word.isNotEmpty) {
          words.add(word.toString().toLowerCase());
          word.clear();
        }
        continue;
      }
      if (_isUpper(c) && word.isNotEmpty && !_isUpper(key[i - 1])) {
        words.add(word.toString().toLowerCase());
        word.clear();
      }
      word.write(c);
    }
    if (word.isNotEmpty) {
      words.add(word.toString().toLowerCase());
    }
    return words;
  }

  /// Returns the allowed properties and how many keys were removed.
  /// Only flat String / num / bool / null values are kept; maps and lists are
  /// removed (they can hide sensitive keys), other objects become strings.
  static ({Map<String, Object?> clean, int removed}) sanitize(
      Map<String, Object?>? properties) {
    final clean = <String, Object?>{};
    if (properties == null) {
      return (clean: clean, removed: 0);
    }

    var removed = 0;
    for (final entry in properties.entries) {
      final key = entry.key;
      var value = entry.value;
      if (clean.length >= maxProperties ||
          key.trim().isEmpty ||
          key.length > maxKeyLength ||
          isDenied(key)) {
        removed++;
        continue;
      }
      if (value is Map || value is Iterable) {
        removed++;
        continue;
      }
      if (value != null &&
          value is! String &&
          value is! num &&
          value is! bool) {
        value = value.toString();
      }
      if (value is String && value.length > maxStringLength) {
        value = value.substring(0, maxStringLength);
      }
      if (value is double && (value.isNaN || value.isInfinite)) {
        removed++;
        continue;
      }
      clean[key] = value;
    }
    return (clean: clean, removed: removed);
  }

  static bool _isUpper(String c) =>
      c.toUpperCase() == c && c.toLowerCase() != c;

  static bool _isLetterOrDigit(String c) {
    final code = c.codeUnitAt(0);
    return (code >= 48 && code <= 57) || c.toUpperCase() != c.toLowerCase();
  }
}
