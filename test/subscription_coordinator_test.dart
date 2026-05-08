import 'dart:async';
import 'dart:convert';

import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const MethodChannel _iapChannel = MethodChannel('flutter_inapp');

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
  SubscriptionTransactionReporter? transactionReporter,
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
      transactionReporter: transactionReporter,
    ),
  );
}

PurchaseIOS _purchase({
  String productId = 'subscribe_month_1',
  String? id,
  String transactionId = 'tx-active',
  String? originalTransactionId = 'original-tx-active',
}) {
  return PurchaseIOS(
    id: id ?? (transactionId.isNotEmpty ? transactionId : productId),
    isAutoRenewing: true,
    platform: IapPlatform.IOS,
    productId: productId,
    purchaseState: PurchaseState.Purchased,
    quantity: 1,
    store: IapStore.Apple,
    transactionDate: DateTime.now().millisecondsSinceEpoch.toDouble(),
    transactionId: transactionId,
    originalTransactionIdentifierIOS: originalTransactionId,
  );
}

void main() {
  const String cacheKey = 'subscription_access_state';

  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('retains active grace period when native entitlements are empty',
      () async {
    final int cachedAt = DateTime.now().millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues(<String, Object>{
      cacheKey: jsonEncode(
        SubscriptionAccessState(
          status: SubscriptionAccessStatus.gracePeriod,
          evaluatedAtMs: cachedAt,
          effectiveUntilMs: cachedAt + 10000,
          productId: 'subscribe_month_1',
          transactionId: 'tx-grace',
        ).toJson(),
      ),
    });
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final SubscriptionCoordinator coordinator = _coordinator(
      prefs: prefs,
      query: (productIds) async => <ActiveSubscription>[],
    );

    await coordinator.loadStoredStatus();
    final SubscriptionAccessState resolvedState =
        await coordinator.refreshAccessState(source: 'test');

    expect(resolvedState.status, SubscriptionAccessStatus.gracePeriod);
    expect(resolvedState.shouldGrantAccess, isTrue);
    expect(resolvedState.effectiveUntilMs, cachedAt + 10000);
    expect(coordinator.isSubscribed.value, isTrue);
  });

  test(
      'does not retain expired grace period when native entitlements are empty',
      () async {
    final int cachedAt = DateTime.now().millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues(<String, Object>{
      cacheKey: jsonEncode(
        SubscriptionAccessState(
          status: SubscriptionAccessStatus.gracePeriod,
          evaluatedAtMs: cachedAt,
          effectiveUntilMs: cachedAt - 1,
          productId: 'subscribe_month_1',
          transactionId: 'tx-grace',
        ).toJson(),
      ),
    });
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final SubscriptionCoordinator coordinator = _coordinator(
      prefs: prefs,
      query: (productIds) async => <ActiveSubscription>[],
    );

    await coordinator.loadStoredStatus();
    final SubscriptionAccessState resolvedState =
        await coordinator.refreshAccessState(source: 'test');

    expect(resolvedState.status, SubscriptionAccessStatus.expired);
    expect(resolvedState.shouldGrantAccess, isFalse);
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
    final Completer<void> stateCompleter = Completer<void>();
    final SubscriptionCoordinator coordinator = _coordinator(
      prefs: prefs,
      query: (productIds) async {
        queryCalls++;
        return <ActiveSubscription>[
          _activeSubscription(),
        ];
      },
    );
    void onStateChanged() {
      if (coordinator.accessState.value.status ==
              SubscriptionAccessStatus.active &&
          !stateCompleter.isCompleted) {
        stateCompleter.complete();
      }
    }

    coordinator.accessState.addListener(onStateChanged);
    addTearDown(() => coordinator.accessState.removeListener(onStateChanged));

    coordinator.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await stateCompleter.future;

    expect(queryCalls, 1);
    expect(
        coordinator.accessState.value.status, SubscriptionAccessStatus.active);
    expect(coordinator.isSubscribed.value, isTrue);
  });

  test(
      'restore reports transaction when native access is active even if local validation is invalid',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<SubscriptionTransactionPayload> reportedPayloads =
        <SubscriptionTransactionPayload>[];
    final PurchaseIOS purchase = _purchase(
      transactionId: 'tx-invalid-validation',
      originalTransactionId: 'original-invalid-validation',
    );
    final SubscriptionCoordinator coordinator = _coordinator(
      prefs: prefs,
      query: (productIds) async => <ActiveSubscription>[
        _activeSubscription(transactionId: 'tx-native-active'),
      ],
      transactionReporter: (payload) async {
        reportedPayloads.add(payload);
      },
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_iapChannel, (MethodCall call) async {
      switch (call.method) {
        case 'initConnection':
          return true;
        case 'restorePurchases':
          return null;
        case 'getAvailableItems':
          return <dynamic>[purchase.toJson()];
        case 'validateReceiptIOS':
          return <String, dynamic>{
            'isValid': false,
            'latestTransaction': purchase.toJson(),
          };
        case 'finishTransaction':
          return null;
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_iapChannel, null);
    });

    final SubscriptionActionResult result =
        await coordinator.restore(source: 'test');

    expect(result.success, isTrue);
    expect(reportedPayloads, hasLength(1));
    expect(
        reportedPayloads.single.currentTransactionId, 'tx-invalid-validation');
    expect(reportedPayloads.single.originalTransactionId,
        'original-invalid-validation');
  });

  test('restore does not report transaction when no item has transactionId',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    int reportCalls = 0;
    final PurchaseIOS purchase = _purchase(
      id: 'purchase-without-transaction-id',
      transactionId: '',
      originalTransactionId: 'original-without-current-tx',
    );
    final SubscriptionCoordinator coordinator = _coordinator(
      prefs: prefs,
      query: (productIds) async => <ActiveSubscription>[
        _activeSubscription(transactionId: ''),
      ],
      transactionReporter: (payload) async {
        reportCalls++;
      },
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_iapChannel, (MethodCall call) async {
      switch (call.method) {
        case 'initConnection':
          return true;
        case 'restorePurchases':
          return null;
        case 'getAvailableItems':
          return <dynamic>[purchase.toJson()];
        case 'validateReceiptIOS':
          return <String, dynamic>{
            'isValid': false,
            'latestTransaction': purchase.toJson(),
          };
        case 'finishTransaction':
          return null;
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_iapChannel, null);
    });

    final SubscriptionActionResult result =
        await coordinator.restore(source: 'test');

    expect(result.success, isTrue);
    expect(reportCalls, 0);
  });

  test(
      'restore does not report transaction when native status is unavailable and only cached access grants entitlement',
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
    int reportCalls = 0;
    final PurchaseIOS purchase = _purchase(
      transactionId: 'tx-native-purchase',
      originalTransactionId: 'original-native-purchase',
    );
    final SubscriptionCoordinator coordinator = _coordinator(
      prefs: prefs,
      query: (productIds) async => throw Exception('native unavailable'),
      transactionReporter: (payload) async {
        reportCalls++;
      },
    );

    await coordinator.loadStoredStatus();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_iapChannel, (MethodCall call) async {
      switch (call.method) {
        case 'initConnection':
          return true;
        case 'restorePurchases':
          return null;
        case 'getAvailableItems':
          return <dynamic>[purchase.toJson()];
        case 'validateReceiptIOS':
          return <String, dynamic>{
            'isValid': false,
            'latestTransaction': purchase.toJson(),
          };
        case 'finishTransaction':
          return null;
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_iapChannel, null);
    });

    final SubscriptionActionResult result =
        await coordinator.restore(source: 'test');

    expect(result.success, isTrue);
    expect(
        coordinator.accessState.value.status, SubscriptionAccessStatus.active);
    expect(reportCalls, 0);
  });
}
