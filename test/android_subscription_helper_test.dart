import 'dart:async';
import 'dart:convert';

import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:app_subscription_core/src/android_subscription_helper.dart';
import 'package:app_subscription_core/src/google_play_subscription_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform/platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

const MethodChannel _iapChannel = MethodChannel('flutter_inapp');
const String _purchaseData =
    '{"productId":"subscribe_month_1","purchaseToken":"purchase-token-1"}';
const String _licenseKey =
    'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA0EIBiabI7LVOWHgtw0Ru'
    'PO8F8QdOcMf6eyr06yM4yiaffPtrBoKPz2VEiaLZGoNTZ3/wSeOcQx4is7V7liTU'
    'fE6f2NiI/cwnlTG7GZ1h2AZOBcz5zvjSfukI9epz9WMpFtOayfDzmdUAUY9nVTwK'
    'vhkqAa4uoBZfMNd/lpfouuTVz2eH8UX26zQzD37ez9wPblssnWyB4BHIythPcSdK'
    'cAS5NfJjOGCmBdIIif5+XI9Xh5/p4PG3EwTT5SfFMmZWR93Ow6s+kB5G7k+mP/YV'
    'j1wUStiTqjoHWYyE2GETwcHsR/PCXKhi9HdgCaD/GR+7Zx1Y1s6NDY9u+qyeJAq0'
    'TwIDAQAB';
const String _purchaseSignature =
    'oCGnixlLhaDhm3hw0si0jtEzkrGSpiwTu49nlLeRsF8xbwDZ2dZ1hKp+F1tdoLFT'
    'HVMu+DUI1LwtmlnMf+Ln0RSJeX3jvCEmlGD4L0sLvO/2GW3pB/0CIUeusAbFxF7V'
    'GpYO4sJJifbdllS7ThyRcIb3LXhPtHRWTrzEOAjQJnHaf9tRG3N9Od7a7LL6H+AQ'
    'IZ2TQ0gHznqL1ZPP7ftcn0a4OtMEgHNYnOeMD4CRC2NlUB3ZaKpKadHamdS9i5TO'
    'UMOwtkSQOVvDie6NvhjsjKWcCSf1Wa0S7LvoXP/IMvAHEjn9OKHP8t8bT6BkdaCf'
    'xydPq72Vdzi+UF6mtc15bQ==';
const String _targetProduct = 'subscription_target';
const String _targetToken = 'purchase-token-2';
const String _priorToken = 'purchase-token-3';
const String _targetSignature =
    'CdWDLyAmGQCFzNh6Fo3idlGlPeb8knigFiCPyqNCg4EVftSy8bCyD8FI1CNjdN5K'
    'ay05rbIsA4y/LqsfbpxHaewCq3j1gVrRTktB6l/i1xfQyA1Q/8Mc0+YmjE9O1I+3'
    'easEIWn+h+B1HKk1Dy6fh+96H/jJAHI5uhPthiokbqq3S1fTZM1ICHBGaTzbWhrl'
    '1gOSIWeGEi8ta7GfhAH3h1Mh010nbLKSVyt8+ntD7RM4yxGXyEV+6mfp9vXUzuEk'
    'K+Z9gMWiqNZ7Y8xwT2h+uVQQqW56OJ9sVGOYFueq7R6GTjZhA1u8SSEP/O7xh3s0'
    'VT3OBzGRmn0Aa9tKlXdxRQ==';
const String _priorSignature =
    'mWUNkCY+DcYpxdGk1ARfqbnfOE/12yV19Pry9WLxGdlE/ZcOKfvL7fJSbrIsFx4c'
    'l3DVp0v0li0Ie4Wc4aDjLE0p75cyLSP7c12ui6J2vHLvtu9bG6u7fFSooyiFuZfF'
    'vFY9dD26k/CB0MHggtg/stdBQBFbfcfAuwhJXNSLZm28ZfXyv0/PgklLIfiv6Y/P'
    'CwLQHhCMtGky9uo4Oyj8yuY1zPJuO5scs8X1TbFH/h8HxkOk5ne20zari7GyG79B'
    '0lOmuaiNB/jWCFh3+/mCQMm/q80L8hUIlGfwDtt6GkxA7WAqd0EkXz8irHZSMz0j'
    'Wy9kEDYa2aY1u0lfiTsEOg==';

SubscriptionOffer _offer({
  required String id,
  required String token,
  PaymentMode paymentMode = PaymentMode.PayAsYouGo,
}) {
  return SubscriptionOffer(
    basePlanIdAndroid: 'monthly',
    displayPrice: r'$9.99',
    id: id,
    offerTokenAndroid: token,
    paymentMode: paymentMode,
    price: 9.99,
    type: DiscountOfferType.Introductory,
  );
}

ProductSubscriptionAndroid _product(
  List<SubscriptionOffer> offers, {
  String productId = 'subscribe_month_1',
}) {
  return ProductSubscriptionAndroid(
    currency: 'USD',
    description: 'Monthly subscription',
    displayPrice: r'$9.99',
    id: productId,
    nameAndroid: 'Monthly',
    subscriptionOffers: offers,
    title: 'Monthly',
  );
}

PurchaseAndroid _purchase({
  PurchaseState state = PurchaseState.Purchased,
  bool suspended = false,
  bool acknowledged = false,
  String data = _purchaseData,
  String signature = _purchaseSignature,
  String productId = 'subscribe_month_1',
  String token = 'purchase-token-1',
}) {
  return PurchaseAndroid(
    dataAndroid: data,
    id: 'order-1',
    isAcknowledgedAndroid: acknowledged,
    isAutoRenewing: true,
    isSuspendedAndroid: suspended,
    packageNameAndroid: 'com.example.app',
    productId: productId,
    purchaseState: state,
    purchaseToken: token,
    quantity: 1,
    signatureAndroid: signature,
    store: IapStore.Google,
    storeId: StoreIds.play,
    transactionDate: 1,
    transactionId: 'order-1',
  );
}

ActiveSubscription _activeSubscription({
  String productId = 'subscribe_month_1',
  String token = 'purchase-token-1',
}) {
  return ActiveSubscription(
    autoRenewingAndroid: true,
    basePlanIdAndroid: 'monthly',
    isActive: true,
    productId: productId,
    purchaseTokenAndroid: token,
    transactionDate: 1,
    transactionId: 'order-1',
  );
}

PurchaseAndroid _targetPurchase({required bool acknowledged}) => _purchase(
  productId: _targetProduct,
  token: _targetToken,
  data: '{"productId":"$_targetProduct","purchaseToken":"$_targetToken"}',
  signature: _targetSignature,
  acknowledged: acknowledged,
);

PurchaseAndroid _priorPurchase({
  PurchaseState state = PurchaseState.Purchased,
}) => _purchase(
  state: state,
  token: _priorToken,
  data: '{"productId":"subscribe_month_1","purchaseToken":"$_priorToken"}',
  signature: _priorSignature,
  acknowledged: true,
);

Future<void> _emitAndroidPurchase(PurchaseAndroid purchase) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _iapChannel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('purchase-updated', jsonEncode(purchase.toJson())),
          ),
          null,
        );

Future<SubscriptionCoordinator> _androidCoordinator({
  List<SubscriptionPlan>? plans,
  List<String>? subscriptionProductIds,
  SubscriptionActionObserver? actionObserver,
  GooglePlayAcknowledgementObserver? acknowledgementObserver,
  SubscriptionLogger? logger,
  ActiveSubscriptionQuery? query,
  VerifiedSubscriptionQuery? verifiedQuery,
  Duration purchaseTimeout = const Duration(seconds: 2),
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  final FlutterInappPurchase iap = FlutterInappPurchase(
    platform: FakePlatform(operatingSystem: Platform.android),
  );
  return SubscriptionCoordinator(
    sharedPreferences: preferences,
    iap: iap,
    storeAdapter: const GooglePlaySubscriptionAdapter(licenseKey: _licenseKey),
    config: SubscriptionCoordinatorConfig(
      plans:
          plans ??
          const <SubscriptionPlan>[
            SubscriptionPlan(
              googlePlay: GooglePlayPlan(
                basePlanId: 'monthly',
                productId: 'subscribe_month_1',
              ),
              fallbackPrice: r'$9.99',
            ),
          ],
      subscriptionProductIds: subscriptionProductIds,
      activeSubscriptionQuery:
          query ?? (_) async => <ActiveSubscription>[_activeSubscription()],
      actionObserver: actionObserver,
      googlePlayAcknowledgementObserver: acknowledgementObserver,
      logger: logger,
      verifiedSubscriptionQuery: verifiedQuery,
      purchaseTimeout: purchaseTimeout,
      googlePlayLicenseKeyAndroid: _licenseKey,
    ),
  );
}

void _mockAndroidStore({Future<Object?> Function(MethodCall)? onCall}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_iapChannel, (call) async {
        final result = await onCall?.call(call);
        if (result != null) return result;
        return switch (call.method) {
          'initConnection' || 'endConnection' => true,
          'fetchProducts' => [
            _product([_offer(id: 'monthly', token: 'offer')]).toJson(),
          ],
          'getAvailableItems' => [_purchase().toJson()],
          _ => null,
        };
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_iapChannel, null),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(FlutterInappPurchase.resetSharedStateForTesting);

  for (final trigger in ['bootstrap', 'app_resumed', 'store_reconnected']) {
    test('Google 在 $trigger 静默补确认后发布当前权益', () async {
      var available = trigger == 'bootstrap';
      var acknowledged = false;
      var ackCalls = 0;
      var initCalls = 0;
      final acknowledgementStarted = Completer<void>();
      final releaseAcknowledgement = Completer<void>();
      final synced = Completer<SubscriptionActionEvent>();
      final confirmations = <GooglePlayAcknowledgementEvent>[];
      final coordinator = await _androidCoordinator(
        plans: trigger == 'store_reconnected' ? null : const [],
        acknowledgementObserver: confirmations.add,
        actionObserver: (event) {
          if (event.type == SubscriptionActionType.sync &&
              event.phase == SubscriptionActionPhase.finished &&
              !synced.isCompleted) {
            synced.complete(event);
          }
        },
      );
      _mockAndroidStore(
        onCall: (call) async {
          if (call.method == 'initConnection') {
            initCalls++;
            return true;
          }
          if (call.method == 'getAvailableItems') {
            expect(call.arguments['includeSuspendedAndroid'], true);
            return [
              if (available) _purchase(acknowledged: acknowledged).toJson(),
            ];
          }
          if (call.method == 'restorePurchases') fail('不应调用商店恢复');
          if (call.method == 'acknowledgePurchaseAndroid') {
            expect(call.arguments['purchaseToken'], 'purchase-token-1');
            ackCalls++;
            acknowledgementStarted.complete();
            await releaseAcknowledgement.future;
            acknowledged = true;
            return '{"responseCode":0}';
          }
          return null;
        },
      );
      addTearDown(coordinator.dispose);
      final initializing = coordinator.init();
      try {
        if (trigger != 'bootstrap') await initializing;
        available = true;
        switch (trigger) {
          case 'app_resumed':
            coordinator.didChangeAppLifecycleState(AppLifecycleState.resumed);
          case 'store_reconnected':
            await TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger
                .handlePlatformMessage(
                  _iapChannel.name,
                  const StandardMethodCodec().encodeMethodCall(
                    MethodCall(
                      'purchase-error',
                      jsonEncode({'code': ErrorCode.ServiceDisconnected.value}),
                    ),
                  ),
                  null,
                );
            expect(await coordinator.loadProducts(force: true), true);
            expect(initCalls, 2);
        }
        await acknowledgementStarted.future.timeout(const Duration(seconds: 2));
        expect(coordinator.accessState.value.shouldGrantAccess, false);
        expect(confirmations, isEmpty);
      } finally {
        releaseAcknowledgement.complete();
      }
      await initializing;
      final event = await synced.future.timeout(const Duration(seconds: 2));
      expect(coordinator.accessState.value.shouldGrantAccess, true);
      expect(event.source, trigger);
      expect(event.silent, true);
      expect(event.result?.success, true);
      expect(ackCalls, 1);
      final confirmation = confirmations.single;
      expect(confirmation.success, true);
      expect(confirmation.error, isNull);
      expect(confirmation.type, SubscriptionActionType.sync);
      expect(confirmation.source, trigger);
      expect(confirmation.productId, 'subscribe_month_1');
      expect(confirmation.transactionId, 'order-1');
    });
  }

  test('Google 确认被拒后重新查单并自动重试一次', () async {
    var queries = 0;
    var attempts = 0;
    final retried = Completer<bool>();
    final confirmations = <GooglePlayAcknowledgementEvent>[];
    final coordinator = await _androidCoordinator(
      acknowledgementObserver: confirmations.add,
      actionObserver: (event) {
        if (event.source == 'acknowledgement_retry' &&
            event.phase == SubscriptionActionPhase.finished) {
          retried.complete(event.result!.success);
        }
      },
    );
    _mockAndroidStore(
      onCall: (call) async {
        if (call.method == 'getAvailableItems') queries++;
        if (call.method == 'acknowledgePurchaseAndroid') {
          attempts++;
          expect(queries, attempts);
          expect(coordinator.accessState.value.shouldGrantAccess, attempts > 1);
          if (attempts == 1) {
            throw PlatformException(
              code: 'service-error',
              message: 'Billing service is unavailable',
              details: {'debugMessage': 'Play Billing: unavailable for test'},
            );
          }
          return '{"responseCode":0}';
        }
        return null;
      },
    );
    addTearDown(coordinator.dispose);
    await coordinator.init();
    expect(attempts, 1);
    expect(coordinator.accessState.value.shouldGrantAccess, true);
    final rejected = confirmations.single;
    expect(rejected.success, false);
    expect(rejected.source, 'bootstrap');
    expect(rejected.error?.responseCode, isNull);
    expect(rejected.error?.debugMessage, 'Play Billing: unavailable for test');
    expect(rejected.error?.nativeCode, 'service-error');
    expect(rejected.error?.nativeMessage, 'Billing service is unavailable');
    expect(await retried.future.timeout(const Duration(seconds: 3)), true);
    expect(attempts, 2);
    expect(confirmations.map((event) => event.success), [false, true]);
    expect(confirmations.last.source, 'acknowledgement_retry');
    expect(confirmations.last.transactionId, rejected.transactionId);
  });

  test('Google 确认回调未完成或失败不阻塞订阅初始化', () async {
    final report = Completer<void>();
    final logged = Completer<String>();
    final coordinator = await _androidCoordinator(
      plans: const [],
      acknowledgementObserver: (_) => report.future,
      logger: (message) {
        if (message.contains('Google Play 确认回调失败')) logged.complete(message);
      },
    );
    _mockAndroidStore(
      onCall: (call) async => call.method == 'acknowledgePurchaseAndroid'
          ? '{"responseCode":0}'
          : null,
    );
    addTearDown(coordinator.dispose);
    await coordinator.init().timeout(const Duration(seconds: 2));
    expect(coordinator.accessState.value.shouldGrantAccess, true);
    report.completeError(StateError('telemetry offline'));
    expect(
      await logged.future.timeout(const Duration(seconds: 2)),
      contains('telemetry offline'),
    );
  });

  for (final excluded in [
    _purchase(state: PurchaseState.Pending),
    _purchase(suspended: true),
    _purchase(signature: 'invalid'),
    _purchase(acknowledged: true),
  ]) {
    test('Google 不补确认 ${excluded.purchaseState}: '
        'suspended=${excluded.isSuspendedAndroid}, '
        'validSignature=${excluded.signatureAndroid != 'invalid'}, '
        'acknowledged=${excluded.isAcknowledgedAndroid}', () async {
      var attempts = 0;
      _mockAndroidStore(
        onCall: (call) async {
          if (call.method == 'getAvailableItems') return [excluded.toJson()];
          if (call.method == 'acknowledgePurchaseAndroid') attempts++;
          return null;
        },
      );
      final confirmations = <GooglePlayAcknowledgementEvent>[];
      final coordinator = await _androidCoordinator(
        plans: const [],
        acknowledgementObserver: confirmations.add,
      );
      addTearDown(coordinator.dispose);
      await coordinator.init();
      expect(attempts, 0);
      expect(confirmations, isEmpty);
      expect(
        coordinator.accessState.value.shouldGrantAccess,
        excluded.isAcknowledgedAndroid,
      );
    });
  }

  test('grants access only for active Google Play subscriptions', () {
    final SubscriptionAccessState state =
        AndroidSubscriptionHelper.resolveAccessStateFromActiveSubscription(
          subscription: _activeSubscription(),
        );

    expect(state.status, SubscriptionAccessStatus.active);
    expect(state.shouldGrantAccess, isTrue);
  });

  test('Google 默认查询全部订阅，未在售历史商品可恢复且无需 base plan 身份', () async {
    var acknowledgements = 0;
    _mockAndroidStore(
      onCall: (call) async {
        if (call.method == 'getAvailableItems') {
          return [_purchase(acknowledged: acknowledgements > 0).toJson()];
        }
        if (call.method == 'acknowledgePurchaseAndroid') {
          acknowledgements++;
          return true;
        }
        return null;
      },
    );
    final coordinator = await _androidCoordinator(
      plans: const [
        SubscriptionPlan(
          googlePlay: GooglePlayPlan(
            productId: 'current',
            basePlanId: 'annual',
          ),
        ),
      ],
      query: (ids) async {
        expect(ids, isNull);
        return [_activeSubscription()];
      },
    );
    addTearDown(coordinator.dispose);
    final result = await coordinator.restore();
    expect(result.success, true);
    expect(result.restoredCount, 1);
    expect(acknowledgements, 1);
    final record = coordinator.accessState.value.activeSubscriptions.single;
    expect(record.productId, 'subscribe_month_1');
    expect(record.basePlanIdAndroid, isNull);
    expect(coordinator.productIds, ['current']);
  });

  test('Google 全量查询排除普通内购，不因购买签名有效而确认非订阅', () async {
    var acknowledgements = 0;
    _mockAndroidStore(
      onCall: (call) async {
        if (call.method == 'acknowledgePurchaseAndroid') {
          acknowledgements++;
          return true;
        }
        return null;
      },
    );
    final coordinator = await _androidCoordinator(
      plans: const [
        SubscriptionPlan(
          googlePlay: GooglePlayPlan(
            productId: 'current',
            basePlanId: 'annual',
          ),
        ),
      ],
      query: (_) async => [],
    );
    addTearDown(coordinator.dispose);
    await coordinator.restore();
    expect(coordinator.accessState.value.subscriptions, isEmpty);
    expect(coordinator.accessState.value.shouldGrantAccess, false);
    expect(acknowledgements, 0);
  });

  test('Google 显式范围排除历史订阅及其恢复确认', () async {
    var acknowledgements = 0;
    _mockAndroidStore(
      onCall: (call) async {
        if (call.method == 'acknowledgePurchaseAndroid') acknowledgements++;
        return null;
      },
    );
    final coordinator = await _androidCoordinator(
      subscriptionProductIds: ['current'],
      query: (ids) async {
        expect(ids, ['current']);
        return [_activeSubscription()];
      },
    );
    addTearDown(coordinator.dispose);
    await coordinator.restore();
    expect(coordinator.accessState.value.shouldGrantAccess, false);
    expect(acknowledgements, 0);
  });

  test('客户端商品目录的 base plan 不作为已购套餐身份', () {
    final record =
        AndroidSubscriptionHelper.resolveAccessStateFromActiveSubscription(
          subscription: _activeSubscription(),
        );
    expect(record.basePlanIdAndroid, isNull);
    expect(record.purchaseTokenAndroid, 'purchase-token-1');
  });

  for (final expected in [
    SubscriptionActionOutcome.success,
    SubscriptionActionOutcome.failure,
    SubscriptionActionOutcome.unconfirmed,
  ]) {
    test('Google 本地购买按本次已确认的商品权益返回 $expected', () async {
      final requested = Completer<void>();
      final acknowledgementStarted = Completer<void>();
      final releaseAcknowledgement = Completer<void>();
      var purchased = false;
      var acknowledged = false;
      var useOtherToken = false;
      final acknowledgedTokens = <String>[];
      _mockAndroidStore(
        onCall: (call) async {
          switch (call.method) {
            case 'requestPurchase':
              expect((call.arguments as Map)['purchaseToken'], isNull);
              requested.complete();
            case 'getAvailableItems':
              return [
                if (purchased)
                  (useOtherToken
                          ? _priorPurchase()
                          : _purchase(acknowledged: acknowledged))
                      .toJson(),
              ];
            case 'acknowledgePurchaseAndroid':
              acknowledgedTokens.add(
                (call.arguments as Map)['purchaseToken'] as String,
              );
              acknowledgementStarted.complete();
              await releaseAcknowledgement.future;
              acknowledged = expected != SubscriptionActionOutcome.failure;
              useOtherToken = expected == SubscriptionActionOutcome.unconfirmed;
              return acknowledged;
          }
          return null;
        },
      );
      final coordinator = await _androidCoordinator(
        query: (_) async => [
          if (purchased)
            _activeSubscription(
              token: useOtherToken ? _priorToken : 'purchase-token-1',
            ),
        ],
      );
      addTearDown(coordinator.dispose);
      final buying = coordinator.purchasePlan(
        coordinator.config.plans.single,
        source: 'test',
      );
      await requested.future;
      purchased = true;
      await _emitAndroidPurchase(_purchase());
      try {
        await acknowledgementStarted.future.timeout(const Duration(seconds: 2));
        expect(coordinator.accessState.value.shouldGrantAccess, false);
      } finally {
        releaseAcknowledgement.complete();
      }
      final result = await buying;
      expect(acknowledgedTokens, ['purchase-token-1']);
      expect(result.outcome, expected);
      expect(result.success, expected == SubscriptionActionOutcome.success);
      final entitlement =
          coordinator.accessState.value.activeSubscriptions.single;
      expect(entitlement.basePlanIdAndroid, isNull);
      expect(
        entitlement.purchaseTokenAndroid,
        useOtherToken ? _priorToken : 'purchase-token-1',
      );
      if (expected == SubscriptionActionOutcome.success) {
        expect(result.effect, SubscriptionPurchaseEffect.applied);
      } else if (expected == SubscriptionActionOutcome.failure) {
        expect(
          result.failureCode,
          SubscriptionFailureCode.acknowledgementFailed,
        );
      }
    });
  }

  test('Google 购买请求后的旧 token 回放不会完成本次购买', () async {
    final requested = Completer<void>();
    final synced = Completer<SubscriptionActionResult>();
    var current = _priorPurchase(state: PurchaseState.Pending);
    _mockAndroidStore(
      onCall: (call) async {
        switch (call.method) {
          case 'requestPurchase':
            requested.complete();
          case 'getAvailableItems':
            return [current.toJson()];
          case 'acknowledgePurchaseAndroid':
            expect(
              (call.arguments as Map)['purchaseToken'],
              'purchase-token-1',
            );
            current = _purchase(acknowledged: true);
            return true;
        }
        return null;
      },
    );
    final coordinator = await _androidCoordinator(
      query: (_) async => [_activeSubscription(token: current.purchaseToken!)],
      actionObserver: (event) {
        if (event.source == 'purchase_update' &&
            event.phase == SubscriptionActionPhase.finished) {
          synced.complete(event.result);
        }
      },
    );
    addTearDown(coordinator.dispose);
    final buying = coordinator.purchasePlan(
      coordinator.config.plans.single,
      source: 'test',
    );
    await requested.future;
    current = _priorPurchase();
    await _emitAndroidPurchase(current);
    expect((await synced.future).type, SubscriptionActionType.sync);
    current = _purchase();
    await _emitAndroidPurchase(current);
    expect((await buying).effect, SubscriptionPurchaseEffect.applied);
  });

  test('Google 本地跨商品立即替换验证旧购买并确认新 token', () async {
    final requested = Completer<void>();
    final acknowledgementStarted = Completer<void>();
    final releaseAcknowledgement = Completer<void>();
    final oldPurchase = _purchase(acknowledged: true);
    var targetActive = false;
    var targetAcknowledged = false;
    _mockAndroidStore(
      onCall: (call) async {
        switch (call.method) {
          case 'fetchProducts':
            return [
              _product([
                _offer(id: 'monthly', token: 'target-offer'),
              ], productId: _targetProduct).toJson(),
            ];
          case 'getAvailableItems':
            return [
              (targetActive
                      ? _targetPurchase(acknowledged: targetAcknowledged)
                      : oldPurchase)
                  .toJson(),
            ];
          case 'requestPurchase':
            final payload = call.arguments as Map;
            expect(payload['purchaseToken'], oldPurchase.purchaseToken);
            expect(payload['productId'], _targetProduct);
            expect(payload['subscriptionProductReplacementParams'], {
              'oldProductId': oldPurchase.productId,
              'replacementMode': 'with-time-proration',
            });
            requested.complete();
          case 'acknowledgePurchaseAndroid':
            expect((call.arguments as Map)['purchaseToken'], _targetToken);
            acknowledgementStarted.complete();
            await releaseAcknowledgement.future;
            targetAcknowledged = true;
            return true;
        }
        return null;
      },
    );
    final coordinator = await _androidCoordinator(
      plans: const [
        SubscriptionPlan(
          googlePlay: GooglePlayPlan(
            basePlanId: 'monthly',
            productId: _targetProduct,
          ),
        ),
      ],
      query: (_) async => [
        targetActive
            ? _activeSubscription(
                productId: _targetProduct,
                token: _targetToken,
              )
            : _activeSubscription(),
      ],
    );
    addTearDown(coordinator.dispose);
    await coordinator.init();
    final buying = coordinator.purchasePlan(
      coordinator.config.plans.single,
      source: 'change',
      options: SubscriptionPurchaseOptions(
        replacementAndroid: GooglePlayReplacement(
          purchaseToken: oldPurchase.purchaseToken!,
          oldProductId: oldPurchase.productId,
          mode: SubscriptionReplacementModeAndroid.WithTimeProration,
        ),
      ),
    );
    await requested.future.timeout(const Duration(seconds: 2));
    targetActive = true;
    await _emitAndroidPurchase(_targetPurchase(acknowledged: false));
    try {
      await acknowledgementStarted.future.timeout(const Duration(seconds: 2));
      expect(
        coordinator.accessState.value.activeSubscriptions.single.productId,
        oldPurchase.productId,
      );
    } finally {
      releaseAcknowledgement.complete();
    }
    final result = await buying;
    expect(result.success, true);
    expect(result.effect, SubscriptionPurchaseEffect.applied);
    expect(targetAcknowledged, true);
    final entitlement =
        coordinator.accessState.value.activeSubscriptions.single;
    expect(entitlement.productId, _targetProduct);
    expect(entitlement.purchaseTokenAndroid, _targetToken);
    expect(entitlement.basePlanIdAndroid, isNull);
  });

  for (final verification in [
    'verified',
    'differentBasePlan',
    'wrongToken',
    'queryFailed',
  ]) {
    test('Google 新购买先验证令牌权益再确认：$verification', () async {
      final requested = Completer<void>();
      final confirmations = <GooglePlayAcknowledgementEvent>[];
      var acknowledgements = 0;
      var verifiedBeforeAck = false;
      _mockAndroidStore(
        onCall: (call) async {
          if (call.method == 'requestPurchase') requested.complete();
          if (call.method == 'acknowledgePurchaseAndroid') {
            expect(verifiedBeforeAck, true);
            acknowledgements++;
            return true;
          }
          return null;
        },
      );
      final coordinator = await _androidCoordinator(
        acknowledgementObserver: confirmations.add,
        verifiedQuery: (request) async {
          if (request.purchase != null) {
            expect(request.purchase?.purchaseToken, 'purchase-token-1');
            expect(acknowledgements, 0);
            verifiedBeforeAck = true;
          }
          final now = DateTime.now().millisecondsSinceEpoch;
          return SubscriptionSnapshot(
            evaluatedAtMs: now,
            queryFailedProductIds: verification == 'queryFailed'
                ? ['subscribe_month_1']
                : [],
            subscriptions: [
              SubscriptionAccessState(
                store: IapStore.Google,
                productId: 'subscribe_month_1',
                basePlanIdAndroid: verification == 'differentBasePlan'
                    ? 'annual'
                    : 'monthly',
                purchaseTokenAndroid: verification == 'wrongToken'
                    ? 'other'
                    : 'purchase-token-1',
                status: SubscriptionAccessStatus.active,
                evaluatedAtMs: now,
              ),
            ],
          );
        },
      );
      addTearDown(coordinator.dispose);
      final buying = coordinator.purchasePlan(
        coordinator.config.plans.single,
        source: 'test',
      );
      await requested.future;
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            _iapChannel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('purchase-updated', jsonEncode(_purchase().toJson())),
            ),
            null,
          );
      final result = await buying;
      if (verification == 'verified') {
        expect(result.effect, SubscriptionPurchaseEffect.applied);
        expect(acknowledgements, 1);
        expect(confirmations.single.type, SubscriptionActionType.purchase);
        expect(confirmations.single.source, 'test');
      } else if (verification == 'differentBasePlan') {
        expect(result.outcome, SubscriptionActionOutcome.unconfirmed);
        expect(acknowledgements, 1);
      } else {
        expect(
          result.failureCode,
          verification == 'wrongToken'
              ? SubscriptionFailureCode.subscriptionInactive
              : SubscriptionFailureCode.storeQueryFailed,
        );
        expect(acknowledgements, 0);
        expect(confirmations, isEmpty);
        if (verification == 'queryFailed') {
          expect(coordinator.accessState.value.shouldGrantAccess, false);
        }
      }
    });
  }

  test('Google 替换传递官方旧 token、商品与模式，不配置业务等级', () async {
    Object? requested;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_iapChannel, (call) async {
          if (call.method == 'initConnection') return true;
          if (call.method == 'requestPurchase') requested = call.arguments;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_iapChannel, null),
    );
    final iap = FlutterInappPurchase(
      platform: FakePlatform(operatingSystem: Platform.android),
    );
    await iap.initConnection();
    final offer = _offer(id: 'monthly', token: 'selected-offer');
    await const GooglePlaySubscriptionAdapter().requestPurchase(
      iap: iap,
      product: _product([offer]),
      offer: offer,
      options: const SubscriptionPurchaseOptions(
        replacementAndroid: GooglePlayReplacement(
          purchaseToken: 'old-token',
          oldProductId: 'old-product',
          mode: SubscriptionReplacementModeAndroid.Deferred,
        ),
      ),
    );
    final payload = requested as Map;
    expect(payload['purchaseToken'], 'old-token');
    expect(payload['subscriptionProductReplacementParams'], {
      'oldProductId': 'old-product',
      'replacementMode': 'deferred',
    });
    expect(
      (payload['subscriptionOffers'] as List).single['offerToken'],
      'selected-offer',
    );
  });

  for (final (scenario, oldProductId, oldToken, mode, expected) in [
    (
      '同商品',
      'subscribe_month_1',
      'purchase-token-1',
      SubscriptionReplacementModeAndroid.WithTimeProration,
      SubscriptionFailureCode.verificationRequired,
    ),
    (
      '延后替换',
      _targetProduct,
      _targetToken,
      SubscriptionReplacementModeAndroid.Deferred,
      SubscriptionFailureCode.verificationRequired,
    ),
    (
      '未确认旧订单',
      _targetProduct,
      _targetToken,
      SubscriptionReplacementModeAndroid.ChargeFullPrice,
      SubscriptionFailureCode.invalidReplacement,
    ),
    (
      '旧 token 不匹配',
      _targetProduct,
      'unowned-token',
      SubscriptionReplacementModeAndroid.ChargeFullPrice,
      SubscriptionFailureCode.invalidReplacement,
    ),
  ]) {
    test('Google 本地替换拒绝：$scenario', () async {
      var requests = 0;
      var oldOrderQueried = 0;
      _mockAndroidStore(
        onCall: (call) async {
          switch (call.method) {
            case 'getAvailableItems':
              oldOrderQueried++;
              return [
                _targetPurchase(
                  acknowledged:
                      oldOrderQueried == 1 || oldToken != _targetToken,
                ).toJson(),
              ];
            case 'requestPurchase':
              requests++;
          }
          return null;
        },
      );
      final coordinator = await _androidCoordinator(
        query: (_) async => [
          _activeSubscription(productId: _targetProduct, token: _targetToken),
        ],
      );
      addTearDown(coordinator.dispose);
      final result = await coordinator.purchasePlan(
        coordinator.config.plans.single,
        source: 'change',
        options: SubscriptionPurchaseOptions(
          replacementAndroid: GooglePlayReplacement(
            purchaseToken: oldToken,
            oldProductId: oldProductId,
            mode: mode,
          ),
        ),
      );
      expect(result.failureCode, expected);
      expect(requests, 0);
    });
  }

  test('Google 旧购买验证等待超时后不再启动付款', () async {
    final restoring = Completer<void>();
    final oldPurchase = Completer<Object?>();
    var requests = 0;
    _mockAndroidStore(
      onCall: (call) async {
        if (call.method == 'getAvailableItems') {
          restoring.complete();
          return oldPurchase.future;
        }
        if (call.method == 'requestPurchase') requests++;
        return null;
      },
    );
    final coordinator = await _androidCoordinator(
      verifiedQuery: (_) async => SubscriptionSnapshot(
        evaluatedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
      purchaseTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(coordinator.dispose);
    final buying = coordinator.purchasePlan(
      coordinator.config.plans.single,
      source: 'change',
      options: const SubscriptionPurchaseOptions(
        replacementAndroid: GooglePlayReplacement(
          purchaseToken: 'purchase-token-1',
          oldProductId: 'subscribe_month_1',
          mode: SubscriptionReplacementModeAndroid.Deferred,
        ),
      ),
    );
    await restoring.future;
    expect((await buying).outcome, SubscriptionActionOutcome.unconfirmed);
    oldPurchase.complete([_purchase().toJson()]);
    await pumpEventQueue();
    expect(requests, 0);
  });

  test('Google 延后切换以服务端当前和未来 line item 为准', () async {
    var changed = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_iapChannel, (call) async {
          switch (call.method) {
            case 'initConnection':
            case 'endConnection':
              return true;
            case 'fetchProducts':
              return [
                _product([_offer(id: 'monthly', token: 'offer')]).toJson(),
              ];
            case 'getAvailableItems':
              return [_purchase().toJson()];
            case 'requestPurchase':
              changed = true;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_iapChannel, null),
    );
    final coordinator = await _androidCoordinator(
      verifiedQuery: (request) async => SubscriptionSnapshot(
        evaluatedAtMs: DateTime.now().millisecondsSinceEpoch,
        subscriptions: [
          SubscriptionAccessState(
            store: IapStore.Google,
            productId: 'subscribe_month_1',
            purchaseTokenAndroid: 'purchase-token-1',
            basePlanIdAndroid: 'legacy',
            status: SubscriptionAccessStatus.active,
            evaluatedAtMs: DateTime.now().millisecondsSinceEpoch,
            renewal: SubscriptionRenewal(
              autoRenewEnabled: true,
              nextProductId: changed ? 'subscribe_month_1' : null,
              nextBasePlanIdAndroid: changed ? 'monthly' : null,
            ),
          ),
        ],
      ),
    );
    addTearDown(coordinator.dispose);
    final result = await coordinator.purchasePlan(
      coordinator.config.plans.single,
      source: 'change',
      options: const SubscriptionPurchaseOptions(
        replacementAndroid: GooglePlayReplacement(
          purchaseToken: 'purchase-token-1',
          oldProductId: 'subscribe_month_1',
          mode: SubscriptionReplacementModeAndroid.Deferred,
        ),
      ),
    );
    expect(result.effect, SubscriptionPurchaseEffect.scheduled);
    expect(
      coordinator
          .accessState
          .value
          .activeSubscriptions
          .single
          .basePlanIdAndroid,
      'legacy',
    );
    expect(
      coordinator
          .accessState
          .value
          .activeSubscriptions
          .single
          .renewal
          ?.nextBasePlanIdAndroid,
      'monthly',
    );
  });

  test('暂停订阅属于平台交易限制，普通购买不受此限制', () {
    const adapter = GooglePlaySubscriptionAdapter();
    expect(
      adapter.purchaseFailure(_purchase(suspended: true)),
      SubscriptionFailureCode.subscriptionSuspended,
    );
    expect(adapter.purchaseFailure(_purchase()), isNull);
  });

  test('verifies Google Play purchase signatures locally', () {
    expect(
      AndroidSubscriptionHelper.verifyPurchaseSignature(
        purchase: _purchase(),
        licenseKey: _licenseKey,
      ),
      isTrue,
    );
    expect(
      AndroidSubscriptionHelper.verifyPurchaseSignature(
        purchase: _purchase(data: 'modified-purchase-data'),
        licenseKey: _licenseKey,
      ),
      isFalse,
    );
    expect(
      AndroidSubscriptionHelper.verifyPurchaseSignature(
        purchase: _purchase(productId: 'different_product'),
        licenseKey: _licenseKey,
      ),
      isFalse,
    );
  });

  test('只接受当前商品包含的已选优惠令牌', () {
    final iap = FlutterInappPurchase(
      platform: FakePlatform(operatingSystem: Platform.android),
    );
    final product = _product([
      _offer(id: 'monthly', token: 'base-token'),
      _offer(id: 'trial', token: 'trial-token'),
    ]);
    for (final offer in [null, _offer(id: 'trial', token: 'another-token')]) {
      expect(
        () => const GooglePlaySubscriptionAdapter().requestPurchase(
          iap: iap,
          product: product,
          offer: offer,
          options: const SubscriptionPurchaseOptions(),
        ),
        throwsA(
          isA<SubscriptionStoreException>().having(
            (error) => error.failureCode,
            'failureCode',
            SubscriptionFailureCode.invalidOffer,
          ),
        ),
      );
    }
  });

  test(
    'passes the selected offer token to the Google Play billing flow',
    () async {
      final FlutterInappPurchase iap = FlutterInappPurchase(
        platform: FakePlatform(operatingSystem: Platform.android),
      );
      final ProductSubscriptionAndroid product = _product(<SubscriptionOffer>[
        _offer(id: 'trial', token: 'trial-token'),
      ]);
      Map<dynamic, dynamic>? purchaseArguments;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_iapChannel, (MethodCall call) async {
            switch (call.method) {
              case 'initConnection':
                return true;
              case 'requestPurchase':
                purchaseArguments = call.arguments as Map<dynamic, dynamic>;
                return null;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_iapChannel, null);
      });

      await iap.initConnection();
      await const GooglePlaySubscriptionAdapter().requestPurchase(
        iap: iap,
        product: product,
        offer: product.subscriptionOffers.single,
        options: const SubscriptionPurchaseOptions(
          obfuscatedAccountIdAndroid: 'account-hash',
        ),
      );

      expect(purchaseArguments?['type'], 'subs');
      expect(purchaseArguments?['productId'], 'subscribe_month_1');
      expect(purchaseArguments?['obfuscatedAccountId'], 'account-hash');
      expect(purchaseArguments?['subscriptionOffers'], <Map<String, String>>[
        <String, String>{
          'sku': 'subscribe_month_1',
          'offerToken': 'trial-token',
        },
      ]);
    },
  );

  test('acknowledges only after local verification succeeds', () async {
    int acknowledgementCalls = 0;
    var historyAvailable = false;
    final acknowledgementStarted = Completer<void>();
    final releaseAcknowledgement = Completer<void>();
    final SubscriptionCoordinator coordinator = await _androidCoordinator();
    addTearDown(coordinator.dispose);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_iapChannel, (MethodCall call) async {
          switch (call.method) {
            case 'initConnection':
              return true;
            case 'getAvailableItems':
              return [if (historyAvailable) _purchase().toJson()];
            case 'acknowledgePurchaseAndroid':
              acknowledgementCalls++;
              acknowledgementStarted.complete();
              await releaseAcknowledgement.future;
              return true;
            case 'endConnection':
              return true;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_iapChannel, null);
    });

    await coordinator.init();
    historyAvailable = true;
    final restoring = coordinator.restore(source: 'test');
    try {
      await acknowledgementStarted.future.timeout(const Duration(seconds: 2));
      expect(coordinator.accessState.value.shouldGrantAccess, false);
    } finally {
      releaseAcknowledgement.complete();
    }
    final result = await restoring;
    expect(result.success, isTrue);
    expect(acknowledgementCalls, 1);
    expect(coordinator.accessState.value.shouldGrantAccess, true);
  });

  test(
    'does not acknowledge when local signature verification fails',
    () async {
      int acknowledgementCalls = 0;
      final SubscriptionCoordinator coordinator = await _androidCoordinator();
      addTearDown(coordinator.dispose);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_iapChannel, (MethodCall call) async {
            switch (call.method) {
              case 'initConnection':
                return true;
              case 'getAvailableItems':
                return <dynamic>[
                  _purchase(data: 'modified-purchase-data').toJson(),
                ];
              case 'acknowledgePurchaseAndroid':
                acknowledgementCalls++;
                return true;
              case 'endConnection':
                return true;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_iapChannel, null);
      });

      final SubscriptionActionResult result = await coordinator.restore(
        source: 'test',
      );

      expect(result.success, isFalse);
      expect(
        result.failureCode,
        SubscriptionFailureCode.localVerificationFailed,
      );
      expect(
        coordinator.accessState.value.subscriptions.single.status,
        SubscriptionAccessStatus.unavailable,
      );
      expect(acknowledgementCalls, 0);
    },
  );

  test(
    'retries a refused Google Play acknowledgement on the next restore',
    () async {
      int acknowledgementCalls = 0;
      var historyAvailable = false;
      final confirmations = <GooglePlayAcknowledgementEvent>[];
      final coordinator = await _androidCoordinator(
        acknowledgementObserver: confirmations.add,
      );
      addTearDown(coordinator.dispose);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_iapChannel, (MethodCall call) async {
            switch (call.method) {
              case 'initConnection':
                return true;
              case 'getAvailableItems':
                return [if (historyAvailable) _purchase().toJson()];
              case 'acknowledgePurchaseAndroid':
                acknowledgementCalls++;
                return acknowledgementCalls > 1
                    ? '{"responseCode":0}'
                    : '{"responseCode":8,"debugMessage":"Item not owned"}';
              case 'endConnection':
                return true;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_iapChannel, null);
      });

      await coordinator.init();
      historyAvailable = true;
      final SubscriptionActionResult result = await coordinator.restore(
        source: 'test',
      );

      expect(result.success, isFalse);
      expect(result.failureCode, SubscriptionFailureCode.acknowledgementFailed);
      expect(confirmations.single.type, SubscriptionActionType.restore);
      expect(confirmations.single.error?.responseCode, 8);
      expect(confirmations.single.error?.debugMessage, 'Item not owned');

      final SubscriptionActionResult retry = await coordinator.restore(
        source: 'retry',
      );

      expect(retry.success, isTrue, reason: '${retry.code}: ${retry.message}');
      expect(acknowledgementCalls, 2);
      expect(confirmations.last.success, true);
    },
  );

  test('blocks overlapping restore operations', () async {
    final Completer<void> releaseFirstQuery = Completer<void>();
    int availablePurchaseQueries = 0;
    final SubscriptionCoordinator coordinator = await _androidCoordinator();
    addTearDown(coordinator.dispose);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_iapChannel, (MethodCall call) async {
          switch (call.method) {
            case 'initConnection':
              return true;
            case 'getAvailableItems':
              availablePurchaseQueries++;
              if (availablePurchaseQueries == 1) {
                await releaseFirstQuery.future;
              }
              return <dynamic>[];
            case 'endConnection':
              return true;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_iapChannel, null);
    });

    final Future<SubscriptionActionResult> firstRestore = coordinator.restore(
      source: 'first',
    );
    while (availablePurchaseQueries == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    final SubscriptionActionResult overlappingRestore = await coordinator
        .restore(source: 'second');
    releaseFirstQuery.complete();
    await firstRestore;

    expect(overlappingRestore.success, isFalse);
    expect(overlappingRestore.failureCode, SubscriptionFailureCode.busy);
  });

  test(
    'keeps purchase events after another plugin instance connects',
    () async {
      final List<SubscriptionActionEvent> events = <SubscriptionActionEvent>[];
      final Completer<void> purchaseRequested = Completer<void>();
      final SubscriptionCoordinator coordinator = await _androidCoordinator(
        actionObserver: events.add,
      );
      addTearDown(coordinator.dispose);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_iapChannel, (MethodCall call) async {
            switch (call.method) {
              case 'initConnection':
                return true;
              case 'fetchProducts':
                return [
                  _product([
                    _offer(id: 'monthly', token: 'base-token'),
                  ]).toJson(),
                ];
              case 'getAvailableItems':
                return [];
              case 'requestPurchase':
                purchaseRequested.complete();
                return null;
              case 'endConnection':
                return true;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_iapChannel, null);
      });

      final Future<SubscriptionActionResult> purchaseFuture = coordinator
          .purchasePlan(coordinator.config.plans.single, source: 'test');
      bool purchaseCompleted = false;
      purchaseFuture.whenComplete(() => purchaseCompleted = true);
      await purchaseRequested.future;

      // 11.x 在其他实例接管原生通道后仍会共享购买事件。
      final FlutterInappPurchase otherIap = FlutterInappPurchase(
        platform: FakePlatform(operatingSystem: Platform.android),
      );
      await otherIap.initConnection();

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            _iapChannel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(
                'purchase-updated',
                jsonEncode(_purchase(productId: 'unrelated_product').toJson()),
              ),
            ),
            null,
          );
      await Future<void>.delayed(Duration.zero);
      expect(purchaseCompleted, isFalse);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            _iapChannel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(
                'purchase-error',
                jsonEncode(<String, Object>{
                  'code': 'user-cancelled',
                  'message': 'cancelled',
                }),
              ),
            ),
            null,
          );
      final SubscriptionActionResult result = await purchaseFuture;

      expect(result.cancelled, isTrue);
      expect(
        events.where(
          (event) =>
              event.phase == SubscriptionActionPhase.finished &&
              event.type == SubscriptionActionType.purchase,
        ),
        hasLength(1),
      );
    },
  );

  test(
    'reconnects after a purchase request reports a disconnected service',
    () async {
      final FlutterInappPurchase iap = FlutterInappPurchase(
        platform: FakePlatform(operatingSystem: Platform.android),
      );
      int initCalls = 0;
      int requestCalls = 0;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_iapChannel, (MethodCall call) async {
            switch (call.method) {
              case 'initConnection':
                initCalls++;
                return true;
              case 'fetchProducts':
                return [
                  _product([
                    _offer(id: 'monthly', token: 'base-token'),
                  ]).toJson(),
                ];
              case 'getActiveSubscriptions':
              case 'getAvailableItems':
                return [];
              case 'requestPurchase':
                requestCalls++;
                throw PlatformException(
                  code: ErrorCode.ServiceDisconnected.value,
                );
              case 'endConnection':
                return true;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_iapChannel, null);
      });

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final SubscriptionCoordinator coordinator = SubscriptionCoordinator(
        sharedPreferences: prefs,
        iap: iap,
        storeAdapter: const GooglePlaySubscriptionAdapter(
          licenseKey: _licenseKey,
        ),
        config: const SubscriptionCoordinatorConfig(
          plans: <SubscriptionPlan>[
            SubscriptionPlan(
              googlePlay: GooglePlayPlan(
                basePlanId: 'monthly',
                productId: 'subscribe_month_1',
              ),
              fallbackPrice: r'$9.99',
            ),
          ],
        ),
      );
      addTearDown(coordinator.dispose);

      final SubscriptionActionResult first = await coordinator.purchasePlan(
        coordinator.config.plans.single,
        source: 'first',
      );
      final SubscriptionActionResult second = await coordinator.purchasePlan(
        coordinator.config.plans.single,
        source: 'second',
      );

      expect(first.storeErrorCode, ErrorCode.ServiceDisconnected);
      expect(second.storeErrorCode, ErrorCode.ServiceDisconnected);
      expect(requestCalls, 2);
      expect(initCalls, 2);
    },
  );

  test('active entitlement wins over a later suspended restore item', () async {
    final SubscriptionCoordinator coordinator = await _androidCoordinator();
    addTearDown(coordinator.dispose);
    final PurchaseAndroid active = _purchase(acknowledged: true);
    final PurchaseAndroid suspended = _purchase(suspended: true);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_iapChannel, (MethodCall call) async {
          switch (call.method) {
            case 'initConnection':
              return true;
            case 'getAvailableItems':
              return <dynamic>[active.toJson(), suspended.toJson()];
            case 'endConnection':
              return true;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_iapChannel, null);
    });

    final SubscriptionActionResult result = await coordinator.restore(
      source: 'test',
    );

    expect(result.success, isTrue);
    expect(coordinator.accessState.value.shouldGrantAccess, isTrue);
    expect(
      coordinator.accessState.value.subscriptions.single.status,
      SubscriptionAccessStatus.active,
    );
  });

  test('Play 暂停状态与扣款重试区分，签名失败也不解释为商店撤销', () async {
    var invalidSignature = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_iapChannel, (call) async {
          switch (call.method) {
            case 'initConnection':
            case 'endConnection':
              return true;
            case 'fetchProducts':
              return [];
            case 'getAvailableItems':
              return [
                _purchase(
                  suspended: true,
                  signature: invalidSignature ? 'invalid' : _purchaseSignature,
                ).toJson(),
              ];
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_iapChannel, null),
    );
    // 当前权益查询先返回有效，随后购买查询已返回暂停；不能继续按旧结果放行。
    final coordinator = await _androidCoordinator();
    addTearDown(coordinator.dispose);
    await coordinator.init();
    expect(
      coordinator.accessState.value.subscriptions.single.status,
      SubscriptionAccessStatus.suspended,
    );
    expect(coordinator.accessState.value.shouldGrantAccess, false);
    invalidSignature = true;
    final state = await coordinator.refreshAccessState();
    expect(
      state.subscriptions.single.status,
      SubscriptionAccessStatus.unavailable,
    );
    expect(
      state.subscriptions.single.reason,
      SubscriptionAccessReason.localVerificationFailed,
    );
    expect(state.shouldGrantAccess, false);
  });

  test('其他商品的签名无效事件不覆盖已验证的 Google Play 权益', () async {
    final synced = Completer<SubscriptionActionResult>();
    final valid = _purchase(acknowledged: true);
    final invalid = _purchase(
      productId: 'another_subscription',
      signature: 'invalid',
    );
    var acknowledgements = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_iapChannel, (call) async {
          switch (call.method) {
            case 'initConnection':
            case 'endConnection':
              return true;
            case 'fetchProducts':
              return [];
            case 'getAvailableItems':
              return [valid.toJson(), invalid.toJson()];
            case 'acknowledgePurchaseAndroid':
              acknowledgements++;
              return true;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_iapChannel, null),
    );
    final coordinator = SubscriptionCoordinator(
      iap: FlutterInappPurchase(
        platform: FakePlatform(operatingSystem: Platform.android),
      ),
      config: SubscriptionCoordinatorConfig(
        plans: const [
          SubscriptionPlan(
            googlePlay: GooglePlayPlan(
              productId: 'subscribe_month_1',
              basePlanId: 'monthly',
            ),
          ),
          SubscriptionPlan(
            googlePlay: GooglePlayPlan(
              productId: 'another_subscription',
              basePlanId: 'monthly',
            ),
          ),
        ],
        googlePlayLicenseKeyAndroid: _licenseKey,
        activeSubscriptionQuery: (_) async => [_activeSubscription()],
        actionObserver: (event) {
          if (event.phase == SubscriptionActionPhase.finished &&
              event.type == SubscriptionActionType.sync) {
            synced.complete(event.result!);
          }
        },
      ),
    );
    addTearDown(coordinator.dispose);
    await coordinator.init();
    expect(coordinator.accessState.value.shouldGrantAccess, true);
    final states = <SubscriptionSnapshot>[];
    coordinator.accessState.addListener(
      () => states.add(coordinator.accessState.value),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _iapChannel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('purchase-updated', jsonEncode(invalid.toJson())),
          ),
          null,
        );
    final result = await synced.future;
    expect(result.failureCode, SubscriptionFailureCode.localVerificationFailed);
    expect(acknowledgements, 0);
    expect(states, isNotEmpty);
    expect(
      states.every(
        (state) =>
            state.shouldGrantAccess &&
            state.activeSubscriptions.single.productId == 'subscribe_month_1',
      ),
      true,
    );
  });

  for (final queryThrows in [false, true]) {
    test('Android 权益${queryThrows ? '查询异常' : '返回空结果'}不进行固定轮询', () async {
      var queries = 0;
      final coordinator = await _androidCoordinator(
        query: (_) async {
          queries++;
          if (queryThrows) throw StateError('查询不可用');
          return [];
        },
      );
      addTearDown(coordinator.dispose);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_iapChannel, (call) async {
            switch (call.method) {
              case 'initConnection':
              case 'endConnection':
                return true;
              case 'fetchProducts':
                return [];
              case 'getAvailableItems':
                return [_purchase().toJson()];
              case 'acknowledgePurchaseAndroid':
                fail('未确认有效权益，不应确认该交易');
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_iapChannel, null),
      );
      await coordinator.init();
      queries = 0;
      final result = await coordinator.restore();
      expect(
        result.failureCode,
        queryThrows
            ? SubscriptionFailureCode.processingException
            : SubscriptionFailureCode.subscriptionInactive,
      );
      // 单笔验证一次，恢复结束后的全局刷新一次。
      expect(queries, 2);
    });
  }
}
