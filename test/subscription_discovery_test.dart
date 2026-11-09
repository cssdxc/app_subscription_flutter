import 'dart:async';
import 'dart:convert';

import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/subscription_store.dart';

ActiveSubscription legacyEntitlement({
  String id = 'legacy',
  String group = 'group',
}) => ActiveSubscription(
  productId: id,
  isActive: true,
  transactionDate: 1,
  transactionId: 'active-$id',
  purchaseToken:
      'header.${base64Url.encode(utf8.encode(jsonEncode({'subscriptionGroupIdentifier': group})))}.signature',
);

SubscriptionStatusIOS legacyStatus(String id, {String state = 'subscribed'}) =>
    SubscriptionStatusIOS(
      state: state,
      renewalInfo: RenewalInfoIOS(
        willAutoRenew: true,
        jsonRepresentation: jsonEncode({'productId': id}),
      ),
    );

Future<void> emit(Purchase purchase) => TestDefaultBinaryMessengerBinding
    .instance
    .defaultBinaryMessenger
    .handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('purchase-updated', jsonEncode(purchase.toJson())),
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

  test('默认查询全部订阅，历史商品不加入在售套餐或价格请求', () async {
    List? fetched;
    final statusQueries = <String>[];
    mockStore(
      products: [product('monthly')],
      onCall: (call) async {
        if (call.method == 'fetchProducts')
          fetched = (call.arguments as Map)['skus'] as List;
        if (call.method == 'getActiveSubscriptions') {
          expect(call.arguments, isNull);
          return [legacyEntitlement().toJson()];
        }
        return null;
      },
    );
    final coordinator = create(
      statuses: (id) async {
        statusQueries.add(id);
        return [legacyStatus('legacy')];
      },
    );
    await coordinator.init();
    final record = coordinator.accessState.value.activeSubscriptions.single;
    expect(record.productId, 'legacy');
    expect(record.subscriptionGroupIdIOS, 'group');
    expect(fetched, ['monthly']);
    expect(statusQueries, ['monthly']);
    expect(coordinator.plans.value.single.productId, 'monthly');
    expect(coordinator.productIds, ['monthly']);
  });

  test('仅查询权益时无需配置任何商品，也不发起空商品价格请求', () async {
    mockStore(
      onCall: (call) async {
        if (call.method == 'fetchProducts') fail('不能请求空商品列表');
        return null;
      },
    );
    final coordinator = create(
      plans: [],
      query: (ids) async {
        expect(ids, isNull);
        return [legacyEntitlement()];
      },
      statuses: (id) async {
        expect(id, 'legacy');
        return [legacyStatus('legacy')];
      },
    );
    await coordinator.init();
    expect(coordinator.isConfigured, true);
    expect(coordinator.plans.value, isEmpty);
    expect(coordinator.accessState.value.shouldGrantAccess, true);
    expect(
      (await coordinator.purchasePlan(monthly, source: 'test')).failureCode,
      SubscriptionFailureCode.planNotConfigured,
    );
  });

  test('不同订阅组的历史商品也可自动识别', () async {
    mockStore(products: [product('monthly')]);
    final queries = <String>[];
    final coordinator = create(
      query: (_) async => [legacyEntitlement(group: 'old-group')],
      statuses: (id) async {
        queries.add(id);
        return id == 'legacy' ? [legacyStatus('legacy')] : [];
      },
    );
    await coordinator.init();
    expect(queries, ['monthly', 'legacy']);
    expect(
      coordinator.accessState.value.activeSubscriptions.single.productId,
      'legacy',
    );
  });

  test('显式过滤独立于在售配置，可只识别历史商品', () async {
    mockStore(products: [product('monthly')]);
    final coordinator = create(
      subscriptionProductIds: ['legacy'],
      query: (ids) async {
        expect(ids, ['legacy']);
        return [legacyEntitlement()];
      },
      statuses: (id) async {
        expect(id, 'monthly');
        return [legacyStatus('legacy')];
      },
    );
    await coordinator.init();
    expect(
      coordinator.accessState.value.activeSubscriptions.single.productId,
      'legacy',
    );
    expect(coordinator.plans.value.single.productId, 'monthly');
  });

  test('借用范围外同组商品查询失败时，失败状态仍属于识别范围', () async {
    mockStore(products: [product('monthly')]);
    final coordinator = create(
      subscriptionProductIds: ['legacy'],
      query: (_) async => [legacyEntitlement()],
      statuses: (id) async {
        expect(id, 'monthly');
        throw StateError('查询失败');
      },
    );
    await coordinator.init();
    final snapshot = coordinator.accessState.value;
    expect(snapshot.queryFailedProductIds, {'legacy'});
    expect(snapshot.subscriptions.single.productId, 'legacy');
    expect(
      snapshot.subscriptions.single.status,
      SubscriptionAccessStatus.unavailable,
    );
  });

  test('构造时复制识别范围，服务端记录与失败范围受相同过滤', () async {
    final scope = ['legacy'];
    mockStore(products: [product('monthly')]);
    final coordinator = create(
      subscriptionProductIds: scope,
      statuses: (_) async => [],
      verifiedQuery: (request) async {
        expect(request.productIds, ['legacy']);
        final now = DateTime.now().millisecondsSinceEpoch;
        return SubscriptionSnapshot(
          evaluatedAtMs: now,
          queryFailedProductIds: ['outside'],
          subscriptions: [
            for (final id in ['legacy', 'outside'])
              SubscriptionAccessState(
                store: IapStore.Apple,
                productId: id,
                status: SubscriptionAccessStatus.active,
                evaluatedAtMs: now,
              ),
          ],
        );
      },
    );
    scope.clear();
    await coordinator.init();
    expect(
      coordinator.accessState.value.activeSubscriptions.single.productId,
      'legacy',
    );
    expect(coordinator.accessState.value.queryFailedProductIds, isEmpty);
  });

  test('显式空范围不调用权益查询，也不采用历史缓存', () async {
    mockStore();
    final coordinator = create(
      subscriptionProductIds: [],
      query: (_) async => throw StateError('不能调用'),
      statuses: (_) async => throw StateError('不能调用'),
    );
    await coordinator.refreshAccessState();
    expect(coordinator.accessState.value.subscriptions, isEmpty);
    expect(coordinator.accessState.value.shouldGrantAccess, false);
  });

  test('历史订阅恢复会验证完成并授予当前权益，普通内购不完成', () async {
    final legacy = purchase('legacy').toJson()
      ..['subscriptionGroupIdIOS'] = 'group';
    final finished = <String>[];
    mockStore(
      purchases: [PurchaseIOS.fromJson(legacy), purchase('coins')],
      products: [product('monthly')],
      onCall: (call) async {
        if (call.method == 'finishTransaction') {
          finished.add(
            ((call.arguments as Map)['purchase'] as Map)['productId'] as String,
          );
        }
        return null;
      },
    );
    final coordinator = create(
      query: (_) async => [legacyEntitlement()],
      statuses: (_) async => [legacyStatus('legacy')],
    );
    final result = await coordinator.restore();
    expect(result.success, true);
    expect(result.restoredCount, 1);
    expect(finished, ['legacy']);
    expect(coordinator.accessState.value.shouldGrantAccess, true);
  });

  test('历史商品事件会刷新权益，后续无有效订阅时收回', () async {
    final synced = Completer<void>();
    var active = false;
    var finishes = 0;
    mockStore(
      products: [product('monthly')],
      onCall: (call) async {
        if (call.method == 'finishTransaction') finishes++;
        return null;
      },
    );
    final coordinator = create(
      query: (_) async => active ? [legacyEntitlement()] : [],
      statuses: (_) async => active ? [legacyStatus('legacy')] : [],
      observe: (event) {
        if (event.type == SubscriptionActionType.sync &&
            event.phase == SubscriptionActionPhase.finished) {
          synced.complete();
        }
      },
    );
    await coordinator.init();
    active = true;
    await emit(
      PurchaseIOS.fromJson(
        purchase('legacy').toJson()..['subscriptionGroupIdIOS'] = 'group',
      ),
    );
    await synced.future;
    expect(finishes, 1);
    expect(
      coordinator.accessState.value.activeSubscriptions.single.productId,
      'legacy',
    );
    active = false;
    await coordinator.refreshAccessState();
    expect(coordinator.accessState.value.shouldGrantAccess, false);
  });

  test('服务端收到全量范围且历史记录不会再被在售套餐过滤', () async {
    mockStore(products: [product('monthly')]);
    final coordinator = create(
      query: (_) async => throw StateError('不应查询设备'),
      statuses: (_) async => throw StateError('不应查询设备'),
      verifiedQuery: (request) async {
        expect(request.productIds, isNull);
        final now = DateTime.now().millisecondsSinceEpoch;
        return SubscriptionSnapshot(
          evaluatedAtMs: now,
          subscriptions: [
            SubscriptionAccessState(
              store: IapStore.Apple,
              productId: 'legacy',
              status: SubscriptionAccessStatus.active,
              evaluatedAtMs: now,
            ),
            SubscriptionAccessState(
              store: IapStore.Google,
              productId: 'other-store',
              status: SubscriptionAccessStatus.active,
              evaluatedAtMs: now,
            ),
          ],
        );
      },
    );
    await coordinator.init();
    expect(
      coordinator.accessState.value.activeSubscriptions.single.productId,
      'legacy',
    );
  });

  test('全量查询失败保留历史订阅缓存和原始证据，不重新写入', () async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;
    final raw = jsonEncode(
      SubscriptionSnapshot(
        evaluatedAtMs: now,
        subscriptions: [
          SubscriptionAccessState(
            store: IapStore.Apple,
            productId: 'legacy',
            status: SubscriptionAccessStatus.active,
            evaluatedAtMs: now,
          ),
        ],
      ).toJson(),
    );
    await prefs.setString('subscription_access_state', raw);
    mockStore(products: [product('monthly')]);
    final coordinator = create(
      query: (_) async => throw StateError('离线'),
      statuses: (_) async => [],
    );
    await coordinator.init();
    final record = coordinator.accessState.value.activeSubscriptions.single;
    expect(record.productId, 'legacy');
    expect(record.fromCache, true);
    expect(record.evaluatedAtMs, now);
    expect(
      coordinator.accessState.value.queryFailedProductIds,
      contains('legacy'),
    );
    expect(prefs.getString('subscription_access_state'), raw);
  });
}
