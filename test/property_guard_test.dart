import 'package:flutter_test/flutter_test.dart';
import 'package:vector_signal_flutter/vector_signal_flutter.dart';

// Same cases as tests/VectorSignal.Tests/PrivacyAndIngestTests.cs (PropertyGuardTests),
// so the device and the server agree on what is removed.
void main() {
  group('PropertyGuard.isDenied', () {
    for (final key in [
      'password',
      'userPassword',
      'wallet_balance',
      'amount',
      'accountNo',
      'pin',
      'pinCode',
      'card_number',
      'OTP',
      'phoneNumber',
      'access-token',
    ]) {
      test('denies $key', () => expect(PropertyGuard.isDenied(key), isTrue));
    }

    for (final key in [
      'screen',
      'mapping',
      'spinner',
      'durationMs',
      'label',
      'statusCode',
      'discard',
    ]) {
      test('allows $key', () => expect(PropertyGuard.isDenied(key), isFalse));
    }
  });

  test('sanitize removes sensitive and nested values, truncates long text', () {
    final result = PropertyGuard.sanitize({
      'label': 'Create',
      'balance': 1234.5,
      'nested': {'a': 1},
      'note': 'x' * 900,
    });

    expect(result.removed, 2);
    expect(result.clean.containsKey('label'), isTrue);
    expect(result.clean.containsKey('balance'), isFalse);
    expect(
        (result.clean['note'] as String).length, PropertyGuard.maxStringLength);
  });

  test('sanitize caps the number of properties', () {
    final props = {for (var i = 0; i < 60; i++) 'k$i': i};
    final result = PropertyGuard.sanitize(props);
    expect(result.clean.length, PropertyGuard.maxProperties);
    expect(result.removed, 10);
  });

  test('splitWords handles camelCase, snake_case and acronyms', () {
    expect(PropertyGuard.splitWords('cardNumber'), ['card', 'number']);
    expect(PropertyGuard.splitWords('card_number'), ['card', 'number']);
    expect(PropertyGuard.splitWords('OTPCode'), ['otpcode']);
  });
}
