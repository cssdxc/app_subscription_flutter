import 'dart:async';
import 'dart:convert';

import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:app_subscription_core/src/ios_subscription_helper.dart';
import 'package:app_subscription_core/src/subscription_entitlement_cache.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/subscription_store.dart';

SubscriptionStatusIOS status(
  String id, {
  String? next,
  bool autoRenew = true,
}) => SubscriptionStatusIOS(
  state: 'subscribed',
  renewalInfo: RenewalInfoIOS(
    willAutoRenew: autoRenew,
    autoRenewPreference: next ?? id,
    renewalDate: 1900000000000,
    jsonRepresentation: jsonEncode({'productId': id}),
  ),
);

Future<void> emitPurchase(String id) => TestDefaultBinaryMessengerBinding
    .instance
    .defaultBinaryMessenger
    .handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('purchase-updated', jsonEncode(purchase(id).toJson())),
      ),
      null,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterInappPurchase.resetSharedStateForTesting();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test('Apple 预约切换无需目标新交易，当前商品保持不变', () async {
    var scheduled = false;
    var finishes = 0;
    mockStore(
      products: [product('monthly'), product('yearly')],
      onCall: (call) async {
        if (call.method == 'requestPurchase') scheduled = true;
        if (call.method == 'finishTransaction') finishes++;
        return null;
      },
    );
    final coordinator = create(
      plans: [monthly, yearly],
      query: (_) async => [entitlement('yearly')],
      statuses: (_) async => [
        status('yearly', next: scheduled ? 'monthly' : 'yearly'),
      ],
    );
    final result = await coordinator.purchasePlan(monthly, source: 'change');
    expect(result.success, true);
    expect(result.effect, SubscriptionPurchaseEffect.scheduled);
    final active = coordinator.accessState.value.activeSubscriptions.single;
    expect(active.productId, 'yearly');
    expect(active.renewal?.nextProductId, 'monthly');
    expect(active.subscriptionGroupIdIOS, 'group');
    expect(coordinator.activity.value.showBlockingLoading, false);
    expect(finishes, 0);
  });

  test('Apple 立即切换只在交易完成且新商品有效后返回 applied', () async {
    final requested = Completer<void>();
    var current = 'monthly';
    var finishes = 0;
    mockStore(
      products: [product('monthly'), product('yearly')],
      onCall: (call) async {
        if (call.method == 'requestPurchase') requested.complete();
        if (call.method == 'finishTransaction') finishes++;
        return null;
      },
    );
    final coordinator = create(
      plans: [monthly, yearly],
      query: (_) async => [entitlement(current)],
      statuses: (_) async => [status(current)],
    );
    final buying = coordinator.purchasePlan(yearly, source: 'change');
    await requested.future;
    current = 'yearly';
    await emitPurchase('yearly');
    final result = await buying;
    expect(result.effect, SubscriptionPurchaseEffect.applied);
    expect(finishes, 1);
    expect(
      coordinator.accessState.value.activeSubscriptions.single.productId,
      'yearly',
    );
  });

  test('请求返回后旧商品事件确认预约，无须等待目标商品交易', () async {
    final reconciled = Completer<void>();
    var queries = 0;
    var scheduled = false;
    mockStore(products: [product('monthly'), product('yearly')]);
    final coordinator = create(
      plans: [monthly, yearly],
      query: (_) async => [entitlement('yearly')],
      statuses: (_) async {
        queries++;
        if (queries == 2) reconciled.complete();
        return [status('yearly', next: scheduled ? 'monthly' : 'yearly')];
      },
    );
    final buying = coordinator.purchasePlan(monthly, source: 'change');
    await reconciled.future;
    await pumpEventQueue();
    scheduled = true;
    await emitPurchase('yearly');
    final result = await buying;
    expect(result.productId, 'monthly');
    expect(result.effect, SubscriptionPurchaseEffect.scheduled);
    expect(
      coordinator.accessState.value.activeSubscriptions.single.productId,
      'yearly',
    );
  });

  test('关闭续订保留当前权益，未来目标不作为当前商品', () {
    final record =
        IosSubscriptionHelper.resolveAccessStateFromSubscriptionStatus(
          status: status('yearly', next: 'monthly', autoRenew: false),
          verifiedEntitlement: entitlement('yearly'),
          fallbackProductId: 'monthly',
        );
    expect(record.shouldGrantAccess, true);
    expect(record.productId, 'yearly');
    expect(record.renewal?.autoRenewEnabled, false);
    expect(record.renewal?.nextProductId, isNull);
  });

  test('同组多项权益按当前商品身份关联，保留全部有效商品', () {
    final records =
        IosSubscriptionHelper.resolveAccessStateFromSubscriptionStatuses(
          [status('yearly', next: 'monthly'), status('monthly')],
          verifiedEntitlements: [entitlement('monthly'), entitlement('yearly')],
          fallbackProductId: 'monthly',
        );
    expect(records.every((s) => s.shouldGrantAccess), true);
    expect(records.map((s) => s.productId).toSet(), {'monthly', 'yearly'});
    expect(records.last.renewal?.nextProductId, 'monthly');
  });

  test('状态身份不匹配或无法关联时不借用同组有效状态', () {
    final records =
        IosSubscriptionHelper.resolveAccessStateFromSubscriptionStatuses(
          [status('yearly')],
          verifiedEntitlements: [entitlement('monthly')],
          fallbackProductId: 'monthly',
        );
    expect(records.single.shouldGrantAccess, false);
    expect(records.single.productId, 'monthly');
  });

  test('Apple 无法解析的身份不能回退为唯一交易匹配', () {
    final records =
        IosSubscriptionHelper.resolveAccessStateFromSubscriptionStatuses(
          [
            SubscriptionStatusIOS(
              state: 'subscribed',
              renewalInfo: RenewalInfoIOS(
                willAutoRenew: true,
                jsonRepresentation: '{broken',
              ),
            ),
          ],
          verifiedEntitlements: [entitlement('monthly')],
          fallbackProductId: 'monthly',
        );
    expect(records.single.shouldGrantAccess, false);
  });

  test('Apple 同商品的不同原始交易分别关联状态和续订目标', () {
    final records =
        IosSubscriptionHelper.resolveAccessStateFromSubscriptionStatuses(
          [
            for (final original in ['own', 'family'])
              SubscriptionStatusIOS(
                state: original == 'own' ? 'subscribed' : 'inGracePeriod',
                renewalInfo: RenewalInfoIOS(
                  willAutoRenew: true,
                  autoRenewPreference: original == 'own' ? 'yearly' : 'monthly',
                  jsonRepresentation: jsonEncode({
                    'productId': 'monthly',
                    'originalTransactionId': original,
                  }),
                ),
              ),
          ],
          verifiedEntitlements: [
            for (final original in ['own', 'family'])
              ActiveSubscription(
                productId: 'monthly',
                isActive: true,
                transactionId: original,
                transactionDate: 1,
                purchaseToken:
                    'header.${base64Url.encode(utf8.encode(jsonEncode({'originalTransactionId': original})))}.signature',
              ),
          ],
          fallbackProductId: 'monthly',
        );
    expect(records.length, 2);
    expect(records.first.status, SubscriptionAccessStatus.active);
    expect(records.first.originalTransactionId, 'own');
    expect(records.first.renewal?.nextProductId, 'yearly');
    expect(records.last.status, SubscriptionAccessStatus.gracePeriod);
    expect(records.last.originalTransactionId, 'family');
    expect(records.last.renewal?.nextProductId, 'monthly');
  });

  test('Apple 无当前权益时仍保留可识别的过期和撤销记录', () {
    final records =
        IosSubscriptionHelper.resolveAccessStateFromSubscriptionStatuses(
          [
            for (final id in ['monthly', 'yearly'])
              SubscriptionStatusIOS(
                state: id == 'monthly' ? 'expired' : 'revoked',
                renewalInfo: RenewalInfoIOS(
                  willAutoRenew: false,
                  jsonRepresentation: jsonEncode({'productId': id}),
                ),
              ),
          ],
          verifiedEntitlements: [],
          fallbackProductId: 'monthly',
        );
    expect(records.map((s) => s.productId), ['monthly', 'yearly']);
    expect(records.map((s) => s.status), [
      SubscriptionAccessStatus.expired,
      SubscriptionAccessStatus.revoked,
    ]);
    expect(records.any((s) => s.shouldGrantAccess), false);
  });

  testWidgets('持续运行跨越已知权益边界时重新查询，不模拟续订', (tester) async {
    mockStore();
    var queries = 0;
    final coordinator = create(
      query: (_) async => throw StateError('不应使用设备端查询'),
      statuses: (_) async => [],
      verifiedQuery: (_) async {
        queries++;
        final now = DateTime.now().millisecondsSinceEpoch;
        return SubscriptionSnapshot(
          evaluatedAtMs: now,
          subscriptions: queries == 1
              ? [
                  SubscriptionAccessState(
                    store: IapStore.Apple,
                    status: SubscriptionAccessStatus.active,
                    evaluatedAtMs: now,
                    productId: 'monthly',
                    effectiveUntilMs: now + 1000,
                  ),
                ]
              : [],
        );
      },
    );
    await coordinator.refreshAccessState();
    expect(coordinator.accessState.value.shouldGrantAccess, true);
    await tester.pump(const Duration(seconds: 1));
    expect(queries, 2);
    expect(coordinator.accessState.value.shouldGrantAccess, false);
  });

  test('请求无确认结果时结束等待，迟到事件仍能同步', () async {
    final synced = Completer<void>();
    mockStore(products: [product('monthly')]);
    var current = false;
    final coordinator = create(
      query: (_) async => current ? [entitlement('monthly')] : [],
      statuses: (_) async => current ? [status('monthly')] : [],
      purchaseTimeout: const Duration(milliseconds: 30),
      observe: (event) {
        if (event.type == SubscriptionActionType.sync &&
            event.phase == SubscriptionActionPhase.finished)
          synced.complete();
      },
    );
    final result = await coordinator.purchasePlan(monthly, source: 'test');
    expect(result.outcome, SubscriptionActionOutcome.unconfirmed);
    expect(result.numericCode, isNull);
    expect(coordinator.activity.value.showBlockingLoading, false);
    current = true;
    await emitPurchase('monthly');
    await synced.future;
    expect(coordinator.accessState.value.shouldGrantAccess, true);
  });

  test('离线缓存的预约不能被当作本次请求已确认', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'subscription_access_state',
      jsonEncode(
        SubscriptionSnapshot(
          evaluatedAtMs: DateTime.now().millisecondsSinceEpoch,
          subscriptions: [
            SubscriptionAccessState(
              store: IapStore.Apple,
              status: SubscriptionAccessStatus.active,
              productId: 'yearly',
              evaluatedAtMs: DateTime.now().millisecondsSinceEpoch,
              renewal: SubscriptionRenewal(
                autoRenewEnabled: true,
                nextProductId: 'monthly',
              ),
            ),
          ],
        ).toJson(),
      ),
    );
    mockStore(products: [product('monthly'), product('yearly')]);
    final coordinator = create(
      plans: [monthly, yearly],
      query: (_) async => throw StateError('offline'),
      statuses: (_) async => [],
      purchaseTimeout: const Duration(milliseconds: 30),
    );
    final result = await coordinator.purchasePlan(monthly, source: 'test');
    expect(result.outcome, SubscriptionActionOutcome.unconfirmed);
    expect(
      coordinator.accessState.value.activeSubscriptions.single.productId,
      'yearly',
    );
    expect(
      coordinator.accessState.value.activeSubscriptions.single.fromCache,
      true,
    );
  });

  test('完整快照缓存保留商品身份，过期记录不能继续授权', () async {
    final now = DateTime.fromMillisecondsSinceEpoch(1800000000000);
    final cache = SubscriptionEntitlementCache(storageKey: 'cache');
    await cache.write(
      SubscriptionSnapshot(
        evaluatedAtMs: now.millisecondsSinceEpoch,
        subscriptions: [
          for (final id in ['expired', 'current'])
            SubscriptionAccessState(
              store: IapStore.Google,
              productId: id,
              basePlanIdAndroid: 'annual',
              purchaseTokenAndroid: 'token-$id',
              status: SubscriptionAccessStatus.active,
              evaluatedAtMs: now.millisecondsSinceEpoch,
              effectiveUntilMs:
                  now.millisecondsSinceEpoch + (id == 'expired' ? -1 : 1000),
            ),
        ],
      ),
    );
    final restored = (await cache.read(now: now))!;
    expect(restored.activeSubscriptions.single.productId, 'current');
    expect(restored.activeSubscriptions.single.basePlanIdAndroid, 'annual');
    expect(
      restored.activeSubscriptions.single.purchaseTokenAndroid,
      'token-current',
    );
    expect(restored.activeSubscriptions.single.fromCache, true);
  });

  test('服务端验证可收到原始 Apple 购买，验证失败不完成交易', () async {
    final requested = Completer<void>();
    var finishes = 0;
    Purchase? submitted;
    mockStore(
      products: [product('monthly')],
      onCall: (call) async {
        if (call.method == 'requestPurchase') requested.complete();
        if (call.method == 'finishTransaction') finishes++;
        return null;
      },
    );
    final coordinator = create(
      query: (_) async => throw StateError('不应走设备端查询'),
      statuses: (_) async => [],
      verifiedQuery: (request) async {
        submitted = request.purchase ?? submitted;
        if (request.purchase != null)
          throw const SubscriptionStoreException(
            failureCode: SubscriptionFailureCode.localVerificationFailed,
            message: 'Rejected',
          );
        return SubscriptionSnapshot(
          evaluatedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
      },
    );
    final buying = coordinator.purchasePlan(monthly, source: 'test');
    await requested.future;
    await emitPurchase('monthly');
    expect(
      (await buying).failureCode,
      SubscriptionFailureCode.localVerificationFailed,
    );
    expect(submitted?.productId, 'monthly');
    expect(finishes, 0);
  });
}
