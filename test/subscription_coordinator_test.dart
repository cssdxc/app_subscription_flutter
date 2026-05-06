import 'dart:convert';

import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

ActiveSubscription _activeSubscription({
  String productId = 'subscribe_month_1',
  String transactionId = 'tx-active',
  RenewalInfoIOS? renewalInfoIOS,
}) {
  return ActiveSubscription(
    isActive: true,
    productId: productId,
    renewalInfoIOS: renewalInfoIOS,
    transactionDate: 1,
    transactionId: transactionId,
  );
}

SubscriptionCoordinator _coordinator({
  required SharedPreferences prefs,
  required ActiveSubscriptionQuery query,
}) {
  return SubscriptionCoordinator(
    sharedPreferences: prefs,
    config: SubscriptionCoordinatorConfig(
      products: const [
        SubscriptionProductConfig(
          id: 'subscribe_month_1',
          defaultPrice: '\$19.99',
        ),
      ],
      activeSubscriptionQuery: query,
    ),
  );
}

void main() {
  const String cacheKey = 'subscription_access_state';

  test('refreshAccessState updates accessState from active entitlements',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final SubscriptionCoordinator coordinator = _coordinator(
      prefs: prefs,
      query: (productIds) async {
        expect(productIds, <String>['subscribe_month_1']);
        return <ActiveSubscription>[
          _activeSubscription(),
        ];
      },
    );

    final SubscriptionAccessState resolvedState =
        await coordinator.refreshAccessState(source: 'test');

    expect(resolvedState.status, SubscriptionAccessStatus.active);
    expect(
        coordinator.accessState.value.status, SubscriptionAccessStatus.active);
    expect(coordinator.isSubscribed.value, isTrue);
    expect(prefs.getString(cacheKey), isNotNull);
  });

  test('refreshAccessState falls back to fresh cached snapshot on failure',
      () async {
    final int cachedAt = DateTime.now().millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues(<String, Object>{
      cacheKey: jsonEncode(
        SubscriptionAccessState(
          status: SubscriptionAccessStatus.active,
          evaluatedAtMs: cachedAt,
          effectiveUntilMs: cachedAt + 10000,
          productId: 'subscribe_month_1',
          transactionId: 'tx-cache',
        ).toJson(),
      ),
    });
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    int queryCalls = 0;
    final SubscriptionCoordinator coordinator = _coordinator(
      prefs: prefs,
      query: (productIds) async {
        queryCalls++;
        throw Exception('offline');
      },
    );

    await coordinator.loadStoredStatus();
    final SubscriptionAccessState resolvedState =
        await coordinator.refreshAccessState(source: 'test');

    expect(queryCalls, 1);
    expect(resolvedState.status, SubscriptionAccessStatus.active);
    expect(
        coordinator.accessState.value.status, SubscriptionAccessStatus.active);
    expect(coordinator.isSubscribed.value, isTrue);

    final Map<String, dynamic> storedState =
        jsonDecode(prefs.getString(cacheKey)!) as Map<String, dynamic>;
    expect(storedState['evaluatedAtMs'], cachedAt);
  });

  test('refreshAccessState treats empty entitlements as expired', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final SubscriptionCoordinator coordinator = _coordinator(
      prefs: prefs,
      query: (productIds) async => <ActiveSubscription>[],
    );

    final SubscriptionAccessState resolvedState =
        await coordinator.refreshAccessState(source: 'test');

    expect(resolvedState.status, SubscriptionAccessStatus.expired);
    expect(coordinator.isSubscribed.value, isFalse);
  });

  test('ignores stale cached snapshot after the six hour TTL', () async {
    final int staleAt = DateTime.now().millisecondsSinceEpoch -
        const Duration(hours: 6).inMilliseconds -
        1;
    SharedPreferences.setMockInitialValues(<String, Object>{
      cacheKey: jsonEncode(
        SubscriptionAccessState(
          status: SubscriptionAccessStatus.active,
          evaluatedAtMs: staleAt,
          effectiveUntilMs: staleAt + 10000,
          productId: 'subscribe_month_1',
          transactionId: 'tx-stale',
        ).toJson(),
      ),
    });
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final SubscriptionCoordinator coordinator = _coordinator(
      prefs: prefs,
      query: (productIds) async => throw Exception('offline'),
    );

    await coordinator.loadStoredStatus();
    expect(coordinator.accessState.value.status,
        SubscriptionAccessStatus.unavailable);

    final SubscriptionAccessState resolvedState =
        await coordinator.refreshAccessState(source: 'test');

    expect(resolvedState.status, SubscriptionAccessStatus.unavailable);
    expect(coordinator.isSubscribed.value, isFalse);
  });

  test('refreshes access state when app returns to foreground', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    int queryCalls = 0;
    final SubscriptionCoordinator coordinator = _coordinator(
      prefs: prefs,
      query: (productIds) async {
        queryCalls++;
        return <ActiveSubscription>[
          _activeSubscription(),
        ];
      },
    );

    coordinator.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);

    expect(queryCalls, 1);
    expect(
        coordinator.accessState.value.status, SubscriptionAccessStatus.active);
    expect(coordinator.isSubscribed.value, isTrue);
  });
}
