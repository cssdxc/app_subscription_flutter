import 'dart:async';
import 'dart:convert';

import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/subscription_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterInappPurchase.resetSharedStateForTesting();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('恢复期间的新交易在恢复之后处理，不因恢复查询为空而丢失', () async {
    final querying = Completer<void>();
    final release = Completer<void>();
    final synced = Completer<SubscriptionActionResult>();
    var availableQueries = 0;
    var finishes = 0;
    mockStore(
      onCall: (call) async {
        if (call.method == 'getAvailableItems' && ++availableQueries == 1) {
          querying.complete();
          await release.future;
        }
        if (call.method == 'finishTransaction') finishes++;
        return null;
      },
    );
    final coordinator = create(
      query: (_) async => [entitlement('monthly')],
      statuses: (_) async => [SubscriptionStatusIOS(state: 'subscribed')],
      observe: (event) {
        if (event.type == SubscriptionActionType.sync &&
            event.phase == SubscriptionActionPhase.finished)
          synced.complete(event.result!);
      },
    );
    final restoring = coordinator.restore();
    await querying.future;
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(
              'purchase-updated',
              jsonEncode(purchase('monthly').toJson()),
            ),
          ),
          null,
        );
    release.complete();
    expect((await restoring).restoredCount, 0);
    expect(
      (await synced.future.timeout(const Duration(seconds: 2))).success,
      true,
    );
    expect(finishes, 1);
  });

  test('恢复期间重放同一笔已恢复交易，只完成和记录一次，其他交易继续处理', () async {
    final verifying = Completer<void>();
    final release = Completer<void>();
    final synced = Completer<SubscriptionActionResult>();
    var finishes = 0;
    var reports = 0;
    mockStore(
      purchases: [purchase('monthly')],
      onCall: (call) async {
        if (call.method == 'isTransactionVerifiedIOS') {
          verifying.complete();
          await release.future;
        }
        if (call.method == 'finishTransaction') finishes++;
        return null;
      },
    );
    final coordinator = create(
      plans: const [monthly, yearly],
      query: (_) async => [entitlement('monthly')],
      statuses: (_) async => [SubscriptionStatusIOS(state: 'subscribed')],
      report: (_) async {
        reports++;
      },
      observe: (event) {
        if (event.type == SubscriptionActionType.sync &&
            event.phase == SubscriptionActionPhase.finished)
          synced.complete(event.result!);
      },
    );
    final restoring = coordinator.restore();
    await verifying.future;
    final pending = PurchaseIOS.fromJson({
      ...purchase('yearly').toJson(),
      'purchaseState': PurchaseState.Pending.toJson(),
    });
    for (final item in [purchase('monthly'), pending]) {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('purchase-updated', jsonEncode(item.toJson())),
            ),
            null,
          );
    }
    release.complete();
    expect((await restoring).restoredCount, 1);
    expect(
      (await synced.future.timeout(const Duration(seconds: 2))).pending,
      true,
    );
    expect(finishes, 1);
    expect(reports, 1);
  });

  test('购买请求之前入队的同商品交易不结束本次购买', () async {
    final fetching = Completer<void>();
    final releaseProducts = Completer<void>();
    final verifyingEarlier = Completer<void>();
    final releaseEarlier = Completer<void>();
    final requested = Completer<void>();
    final syncedMonthly = Completer<void>();
    var fetches = 0;
    mockStore(
      products: [product('monthly'), product('yearly')],
      onCall: (call) async {
        if (call.method == 'fetchProducts' && ++fetches == 1) {
          fetching.complete();
          await releaseProducts.future;
        }
        if (call.method == 'requestPurchase') requested.complete();
        if (call.method == 'isTransactionVerifiedIOS' &&
            (call.arguments as Map)['sku'] == 'yearly') {
          verifyingEarlier.complete();
          await releaseEarlier.future;
        }
        return null;
      },
    );
    final coordinator = create(
      plans: const [monthly, yearly],
      query: (ids) async => (ids ?? []).map(entitlement).toList(),
      statuses: (_) async => [SubscriptionStatusIOS(state: 'subscribed')],
      observe: (event) {
        if (event.productId == 'monthly' &&
            event.type == SubscriptionActionType.sync &&
            event.phase == SubscriptionActionPhase.finished)
          syncedMonthly.complete();
      },
    );
    var completed = false;
    final buying = coordinator.purchasePlan(monthly, source: 'test').then((
      result,
    ) {
      completed = true;
      return result;
    });
    await fetching.future;
    for (final id in ['yearly', 'monthly']) {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('purchase-updated', jsonEncode(purchase(id).toJson())),
            ),
            null,
          );
    }
    await verifyingEarlier.future;
    releaseProducts.complete();
    await requested.future;
    releaseEarlier.complete();
    await syncedMonthly.future.timeout(const Duration(seconds: 2));
    expect(completed, false);
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(
              'purchase-error',
              jsonEncode({'code': 'user-cancelled', 'message': 'cancelled'}),
            ),
          ),
          null,
        );
    expect((await buying).cancelled, true);
  });

  test('Apple 已验证交易完成不依赖当前权益查询，离线不刷新授权证据', () async {
    var failQuery = false;
    mockStore(purchases: [purchase('monthly')]);
    final coordinator = create(
      query: (_) async {
        if (failQuery)
          throw PurchaseError(code: ErrorCode.NetworkError, message: '商店网络不可用');
        return [entitlement('monthly')];
      },
      statuses: (_) async => [SubscriptionStatusIOS(state: 'subscribed')],
    );
    await coordinator.init();
    failQuery = true;
    final result = await coordinator.restore();
    expect(result.failureCode, SubscriptionFailureCode.restoreInactive);
    expect(
      coordinator.accessState.value.activeSubscriptions.single.fromCache,
      true,
    );
  });

  test('显式识别范围之外的商品缓存不能在离线时授予权益', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'subscription_access_state',
      jsonEncode(
        SubscriptionAccessState(
          status: SubscriptionAccessStatus.active,
          evaluatedAtMs: DateTime.now().millisecondsSinceEpoch,
          productId: 'removed-product',
        ).toJson(),
      ),
    );
    final coordinator = create(
      subscriptionProductIds: ['monthly'],
      query: (_) async => throw StateError('商店离线'),
      statuses: (_) async => [],
    );
    await coordinator.init();
    expect(coordinator.accessState.value.shouldGrantAccess, false);
    expect((await coordinator.refreshAccessState()).shouldGrantAccess, false);
  });

  test('购买期间处理其他已配置商品的交易，不结束当前购买', () async {
    final requested = Completer<void>();
    final synced = Completer<SubscriptionActionResult>();
    final finishedProducts = <String>[];
    mockStore(
      products: [product('monthly'), product('yearly')],
      onCall: (call) async {
        if (call.method == 'requestPurchase') requested.complete();
        if (call.method == 'finishTransaction') {
          finishedProducts.add(
            ((call.arguments as Map)['purchase'] as Map)['productId'] as String,
          );
        }
        return null;
      },
    );
    final coordinator = create(
      plans: const [monthly, yearly],
      query: (ids) async => (ids ?? []).map(entitlement).toList(),
      statuses: (_) async => [SubscriptionStatusIOS(state: 'subscribed')],
      observe: (event) {
        if (event.phase == SubscriptionActionPhase.finished &&
            event.type == SubscriptionActionType.sync) {
          synced.complete(event.result!);
        }
      },
    );
    var purchaseCompleted = false;
    final buying = coordinator.purchasePlan(monthly, source: 'test').then((
      result,
    ) {
      purchaseCompleted = true;
      return result;
    });
    await requested.future;
    Future<void> emit(String method, Map<String, dynamic> payload) =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              channel.name,
              const StandardMethodCodec().encodeMethodCall(
                MethodCall(method, jsonEncode(payload)),
              ),
              null,
            );
    await emit('purchase-updated', purchase('yearly').toJson());
    expect(
      (await synced.future.timeout(const Duration(seconds: 2))).success,
      true,
    );
    expect(finishedProducts, ['yearly']);
    expect(purchaseCompleted, false);
    expect(coordinator.activity.value.isPurchasing, true);
    await emit('purchase-error', {
      'code': 'user-cancelled',
      'message': 'cancelled',
    });
    expect((await buying).cancelled, true);
  });

  test('订单记录未返回时，商店交易、恢复结果和加载状态已完成', () async {
    var finishCalls = 0;
    final entered = Completer<void>();
    final gate = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'initConnection':
            case 'restorePurchases':
            case 'endConnection':
            case 'isTransactionVerifiedIOS':
              return true;
            case 'fetchProducts':
              return [];
            case 'getAvailableItems':
              return [purchase('monthly').toJson()];
            case 'finishTransaction':
              finishCalls++;
              return null;
          }
          return null;
        });
    final coordinator = create(
      query: (_) async => [entitlement('monthly')],
      statuses: (_) async => [SubscriptionStatusIOS(state: 'subscribed')],
      report: (_) async {
        entered.complete();
        await gate.future;
      },
    );
    await coordinator.init();
    var completed = false;
    final restoring = coordinator.restore().then((result) {
      completed = true;
      return result;
    });
    await entered.future;
    expect(finishCalls, 1);
    expect((await restoring.timeout(const Duration(seconds: 2))).success, true);
    expect(completed, true);
    expect(coordinator.activity.value.isRestoring, false);
    expect(coordinator.activity.value.isLoading, false);
    gate.complete();
  });

  test('另一订阅组的过期交易不得覆盖有效年度权益或发布失效通知', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'initConnection':
            case 'endConnection':
            case 'isTransactionVerifiedIOS':
              return true;
            case 'fetchProducts':
              return [
                product('monthly', group: 'group-monthly').toJson(),
                product('yearly', group: 'group-yearly').toJson(),
              ];
          }
          return null;
        });
    final synced = Completer<SubscriptionActionResult>();
    final coordinator = create(
      plans: const [monthly, yearly],
      query: (_) async => [entitlement('yearly')],
      statuses: (id) async => [
        SubscriptionStatusIOS(state: id == 'yearly' ? 'subscribed' : 'expired'),
      ],
      observe: (event) {
        if (event.phase == SubscriptionActionPhase.finished &&
            event.type == SubscriptionActionType.sync) {
          synced.complete(event.result!);
        }
      },
    );
    await coordinator.init();
    expect(coordinator.accessState.value.shouldGrantAccess, true);
    expect(
      coordinator.accessState.value.activeSubscriptions.single.productId,
      'yearly',
    );
    final published = <SubscriptionSnapshot>[];
    coordinator.accessState.addListener(
      () => published.add(coordinator.accessState.value),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(
              'purchase-updated',
              jsonEncode(purchase('monthly').toJson()),
            ),
          ),
          null,
        );
    await synced.future;
    expect(
      coordinator.accessState.value.activeSubscriptions.single.status,
      SubscriptionAccessStatus.active,
    );
    expect(
      coordinator.accessState.value.activeSubscriptions.single.productId,
      'yearly',
    );
    expect(published, isNotEmpty);
    expect(
      published.every(
        (state) =>
            state.shouldGrantAccess &&
            state.activeSubscriptions.single.productId == 'yearly',
      ),
      true,
    );
    expect((await coordinator.refreshAccessState()).shouldGrantAccess, true);
  });

  test('StoreKit 查询失败保留有效缓存及原时间戳', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'subscription_access_state',
      jsonEncode(
        SubscriptionAccessState(
          status: SubscriptionAccessStatus.active,
          evaluatedAtMs: DateTime.now().millisecondsSinceEpoch,
          productId: 'monthly',
        ).toJson(),
      ),
    );
    final coordinator = create(
      query: (_) async => [entitlement('monthly')],
      statuses: (_) async => throw StateError('商店状态查询暂不可用'),
    );
    final originalCache = prefs.getString('subscription_access_state');
    await coordinator.init();
    expect(coordinator.accessState.value.shouldGrantAccess, true);
    final state = await coordinator.refreshAccessState();
    expect(state.subscriptions.single.status, SubscriptionAccessStatus.active);
    expect(prefs.getString('subscription_access_state'), originalCache);
  });

  for (final asynchronous in [false, true]) {
    test('订单记录${asynchronous ? '异步' : '同步'}异常不影响已完成交易', () async {
      final logged = Completer<void>();
      var finished = false;
      mockStore(
        purchases: [purchase('monthly')],
        onCall: (call) async {
          if (call.method == 'finishTransaction') finished = true;
          return null;
        },
      );
      final coordinator = create(
        query: (_) async => [entitlement('monthly')],
        statuses: (_) async => [SubscriptionStatusIOS(state: 'subscribed')],
        report: (_) {
          expect(finished, true);
          if (asynchronous) return Future<void>.error(StateError('异步记录失败'));
          throw StateError('同步记录失败');
        },
        logger: (message) {
          if (message.startsWith('记录交易失败')) logged.complete();
        },
      );
      expect((await coordinator.restore()).success, true);
      await logged.future;
      expect(coordinator.activity.value.isLoading, false);
    });
  }

  test('商店交易完成失败时不调用订单记录', () async {
    var reports = 0;
    mockStore(
      purchases: [purchase('monthly')],
      onCall: (call) async {
        if (call.method == 'finishTransaction') {
          throw PlatformException(code: 'E_UNKNOWN', message: '交易完成失败');
        }
        return null;
      },
    );
    final coordinator = create(
      query: (_) async => [entitlement('monthly')],
      statuses: (_) async => [SubscriptionStatusIOS(state: 'subscribed')],
      report: (_) async {
        reports++;
      },
    );
    expect((await coordinator.restore()).success, false);
    expect(reports, 0);
    expect(coordinator.activity.value.isLoading, false);
  });

  test('Apple 已验证历史交易仍完成，但不授予当前权益', () async {
    var finishes = 0;
    var reports = 0;
    mockStore(
      purchases: [purchase('monthly')],
      onCall: (call) async {
        if (call.method == 'finishTransaction') finishes++;
        return null;
      },
    );
    final coordinator = create(
      plans: const [monthly, yearly],
      query: (_) async => [],
      statuses: (id) async => [
        SubscriptionStatusIOS(
          state: id == 'monthly' ? 'subscribed' : 'expired',
        ),
      ],
      report: (_) async {
        reports++;
      },
    );
    final result = await coordinator.restore();
    expect(result.failureCode, SubscriptionFailureCode.restoreInactive);
    expect(coordinator.accessState.value.shouldGrantAccess, false);
    expect(finishes, 1);
    expect(reports, 1);
  });

  test('批量恢复仅在批次末重新查询一次试用资格', () async {
    var eligibilityQueries = 0;
    mockStore(
      purchases: [purchase('monthly'), purchase('yearly')],
      products: [product('monthly'), product('yearly')],
      onCall: (call) async {
        if (call.method == 'isEligibleForIntroOfferIOS') eligibilityQueries++;
        return null;
      },
    );
    final coordinator = create(
      plans: const [monthly, yearly],
      query: (_) async => [entitlement('monthly'), entitlement('yearly')],
      statuses: (_) async => [
        for (final id in ['monthly', 'yearly'])
          SubscriptionStatusIOS(
            state: 'subscribed',
            renewalInfo: RenewalInfoIOS(
              willAutoRenew: true,
              jsonRepresentation: jsonEncode({'productId': id}),
            ),
          ),
      ],
    );
    await coordinator.init();
    eligibilityQueries = 0;
    final result = await coordinator.restore();
    expect(result.success, true);
    expect(result.restoredCount, 2);
    expect(eligibilityQueries, 1);
  });

  test('StoreKit 查询失败且缓存已过期时返回明确的查询失败原因', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'subscription_access_state',
      jsonEncode(
        SubscriptionAccessState(
          status: SubscriptionAccessStatus.active,
          evaluatedAtMs: DateTime.now()
              .subtract(const Duration(hours: 7))
              .millisecondsSinceEpoch,
          productId: 'monthly',
        ).toJson(),
      ),
    );
    final coordinator = create(
      query: (_) async => [entitlement('monthly')],
      statuses: (_) async => throw StateError('查询失败'),
    );
    final state = await coordinator.refreshAccessState();
    expect(state.shouldGrantAccess, false);
    expect(
      state.subscriptions.single.status,
      SubscriptionAccessStatus.unavailable,
    );
    expect(
      state.subscriptions.single.reason,
      SubscriptionAccessReason.storeQueryFailed,
    );
  });

  test('单笔验证期间释放协调器，不再完成商店交易或启动订单记录', () async {
    final verifying = Completer<void>();
    final release = Completer<void>();
    var finishes = 0;
    var reports = 0;
    mockStore(
      purchases: [purchase('monthly')],
      onCall: (call) async {
        if (call.method == 'isTransactionVerifiedIOS') {
          verifying.complete();
          await release.future;
        }
        if (call.method == 'finishTransaction') finishes++;
        return null;
      },
    );
    final coordinator = create(
      query: (_) async => [entitlement('monthly')],
      statuses: (_) async => [SubscriptionStatusIOS(state: 'subscribed')],
      report: (_) async {
        reports++;
      },
    );
    final restoring = coordinator.restore();
    await verifying.future;
    await coordinator.dispose();
    release.complete();
    final result = await restoring;
    expect(result.failureCode, SubscriptionFailureCode.disposed);
    expect(finishes, 0);
    expect(reports, 0);
  });

  test('交易完成后等待旧刷新结束，再重新聚合本次商店权益', () async {
    final oldQueryStarted = Completer<void>();
    final releaseOldQuery = Completer<void>();
    final finished = Completer<void>();
    final synced = Completer<void>();
    var queries = 0;
    var storeState = 'expired';
    mockStore(
      onCall: (call) async {
        if (call.method == 'finishTransaction') finished.complete();
        return null;
      },
    );
    final coordinator = create(
      query: (_) async {
        queries++;
        if (queries == 1) return [];
        if (queries == 2) {
          oldQueryStarted.complete();
          await releaseOldQuery.future;
          return [];
        }
        return [entitlement('monthly')];
      },
      statuses: (_) async => [SubscriptionStatusIOS(state: storeState)],
      observe: (event) {
        if (event.phase == SubscriptionActionPhase.finished &&
            event.type == SubscriptionActionType.sync) {
          synced.complete();
        }
      },
    );
    await coordinator.init();
    final oldRefresh = coordinator.refreshAccessState();
    await oldQueryStarted.future;
    storeState = 'subscribed';
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(
              'purchase-updated',
              jsonEncode(purchase('monthly').toJson()),
            ),
          ),
          null,
        );
    await finished.future;
    releaseOldQuery.complete();
    await oldRefresh;
    await synced.future;
    expect(queries, 3);
    expect(coordinator.accessState.value.shouldGrantAccess, true);
  });

  for (final cachedProductId in ['monthly', 'yearly']) {
    test('部分订阅组查询失败，仅采用失败组的缓存：$cachedProductId', () async {
      final prefs = await SharedPreferences.getInstance();
      final cached = jsonEncode(
        SubscriptionAccessState(
          status: SubscriptionAccessStatus.active,
          evaluatedAtMs: DateTime.now().millisecondsSinceEpoch,
          productId: cachedProductId,
        ).toJson(),
      );
      await prefs.setString('subscription_access_state', cached);
      mockStore(
        products: [
          product('monthly', group: 'monthly-group'),
          product('yearly', group: 'yearly-group'),
        ],
      );
      final coordinator = create(
        plans: const [monthly, yearly],
        query: (_) async => [],
        statuses: (id) async {
          if (id == 'monthly') throw StateError('月度订阅组查询失败');
          return [SubscriptionStatusIOS(state: 'expired')];
        },
      );
      await coordinator.init();
      final shouldUseCache = cachedProductId == 'monthly';
      expect(coordinator.accessState.value.shouldGrantAccess, shouldUseCache);
      if (shouldUseCache) {
        final stored = SubscriptionSnapshot.fromJson(
          jsonDecode(prefs.getString('subscription_access_state')!) as Map,
        );
        final old = SubscriptionAccessState.fromJson(jsonDecode(cached) as Map);
        expect(
          stored.activeSubscriptions.single.evaluatedAtMs,
          old.evaluatedAtMs,
        );
      } else {
        expect(
          coordinator.accessState.value.subscriptions
              .firstWhere((s) => s.productId == 'monthly')
              .reason,
          SubscriptionAccessReason.storeQueryFailed,
        );
      }
    });
  }

  test('同组状态查询失败时，缓存商品无需等于组内代表商品', () async {
    final prefs = await SharedPreferences.getInstance();
    final cached = jsonEncode(
      SubscriptionAccessState(
        status: SubscriptionAccessStatus.active,
        evaluatedAtMs: DateTime.now().millisecondsSinceEpoch,
        productId: 'yearly',
      ).toJson(),
    );
    await prefs.setString('subscription_access_state', cached);
    mockStore(products: [product('monthly'), product('yearly')]);
    final coordinator = create(
      plans: const [monthly, yearly],
      query: (_) async => [],
      statuses: (_) async => throw StateError('该订阅组查询失败'),
    );
    await coordinator.init();
    expect(coordinator.accessState.value.shouldGrantAccess, true);
    expect(
      coordinator.accessState.value.activeSubscriptions.single.productId,
      'yearly',
    );
    expect(prefs.getString('subscription_access_state'), cached);
  });
}
