import 'dart:convert';

import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:app_subscription_core/src/subscription_entitlement_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('快照仅在六小时内使用，损坏、未来时间和超时快照不可用', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final cache = SubscriptionEntitlementCache(
      preferences: prefs,
      storageKey: 'cache',
    );
    final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    expect(await cache.read(now: now), isNull);
    for (final age in [0, const Duration(hours: 6).inMilliseconds]) {
      await cache.write(
        SubscriptionAccessState(
          status: SubscriptionAccessStatus.active,
          evaluatedAtMs: now.millisecondsSinceEpoch - age,
        ),
      );
      expect((await cache.read(now: now))?.shouldGrantAccess, isTrue);
    }
    for (final age in [-1, const Duration(hours: 6).inMilliseconds + 1]) {
      await cache.write(
        SubscriptionAccessState(
          status: SubscriptionAccessStatus.active,
          evaluatedAtMs: now.millisecondsSinceEpoch - age,
        ),
      );
      expect(await cache.read(now: now), isNull);
    }
    for (final value in [
      '{bad',
      '[]',
      jsonEncode({'evaluatedAtMs': 'wrong'}),
    ]) {
      await prefs.setString('cache', value);
      expect(await cache.read(now: now), isNull);
    }
  });
}
