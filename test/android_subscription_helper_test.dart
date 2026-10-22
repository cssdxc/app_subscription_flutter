import 'dart:async';
import 'dart:convert';

import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:app_subscription_core/src/android_subscription_helper.dart';
import 'package:app_subscription_core/src/google_play_subscription_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform/platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

const MethodChannel _iapChannel = MethodChannel('flutter_inapp');
const String _purchaseData =
    '{"productId":"subscribe_month_1","purchaseToken":"purchase-token-1"}';
const String _licenseKey =
    'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAsMElJylHa4cBpux1uudt'
    'dgmxquW30V9na8y4ubzNmiPWXfOH77MhCFO3epdWkTP/ikWYBhAUCNsdqXf7Zu'
    'EbaJVm+4IdiyNFb4Cy0WBeZ6Ps4RPJpw4/4iDG95Erf6UnHNArLXfpAb5fSiV5G'
    'Wh5mpIGmYlHJEZDXB3Sa1BB6xtl6EetkRfDv2UD01uYAEKd1jWm0pcetKSVHMZC'
    '41KIjQqqRLYnAESVtRCqJ7NugpS/Y2U658Kr+bAyJRpfdsQ6hshPYpS31+Dro86S'
    'YpMDA2KJjnys+145fevYWX9orYGBRBkmmS920DQdZeT7fyNLc6DZo442SUhuU+RC'
    'HT7ZqwIDAQAB';
const String _purchaseSignature =
    'R6659bU72HDrQH8dKJLs6yqr/bQzeSUuM1CQQepU64i+kTHJBcoIOjO98hoHvP2a'
    'FhhyyeSACnwr5CZCwn15Y5wg2yK4ib2N9vEa0M8xx8+shF8pyh7Qc2b1pQSfA3g'
    'tuX6lhLyEM/r9v4U/wXCA4QgAxqoTbgumfTnGbwvzSyeaJl5DmkMuMwkrlb83/CT'
    'IvxiXwP+ssJ3902K+WR2Pm4q8DU0yTsnEZZXxHFtpAK9eXhnrFiqft9PG8JSPwkP'
    'lfybA0TH10THY3lfNks5e7x4X1c4rOYDABYUtQ+LBD+gdCZRQ5YpoP8U8DBmbo1X'
    '6ehWdUWfeEAG0qhqzwzpD6w==';

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

ProductSubscriptionAndroid _product(List<SubscriptionOffer> offers) {
  return ProductSubscriptionAndroid(
    currency: 'USD',
    description: 'Monthly subscription',
    displayPrice: r'$9.99',
    id: 'subscribe_month_1',
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
    purchaseToken: 'purchase-token-1',
    quantity: 1,
    signatureAndroid: signature,
    store: IapStore.Google,
    storeId: StoreIds.play,
    transactionDate: 1,
    transactionId: 'order-1',
  );
}

ActiveSubscription _activeSubscription() {
  return const ActiveSubscription(
    autoRenewingAndroid: true,
    basePlanIdAndroid: 'monthly',
    isActive: true,
    productId: 'subscribe_month_1',
    purchaseTokenAndroid: 'purchase-token-1',
    transactionDate: 1,
    transactionId: 'order-1',
  );
}

Future<SubscriptionCoordinator> _androidCoordinator({
  SubscriptionActionObserver? actionObserver,
  ActiveSubscriptionQuery? query,
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
      plans: const <SubscriptionPlan>[
        SubscriptionPlan(
          googlePlay: GooglePlayPlan(
            basePlanId: 'monthly',
            productId: 'subscribe_month_1',
          ),
          fallbackPrice: r'$9.99',
        ),
      ],
      activeSubscriptionQuery:
          query ?? (_) async => <ActiveSubscription>[_activeSubscription()],
      actionObserver: actionObserver,
      googlePlayLicenseKeyAndroid: _licenseKey,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(FlutterInappPurchase.resetSharedStateForTesting);

  test('grants access only for active Google Play subscriptions', () {
    final SubscriptionAccessState state =
        AndroidSubscriptionHelper.resolveAccessStateFromActiveSubscriptions(
          <ActiveSubscription>[_activeSubscription()],
          fallbackProductId: 'subscribe_month_1',
        );

    expect(state.status, SubscriptionAccessStatus.active);
    expect(state.shouldGrantAccess, isTrue);
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
    final SubscriptionCoordinator coordinator = await _androidCoordinator();
    addTearDown(coordinator.dispose);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_iapChannel, (MethodCall call) async {
          switch (call.method) {
            case 'initConnection':
              return true;
            case 'getAvailableItems':
              return <dynamic>[_purchase().toJson()];
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

    expect(result.success, isTrue);
    expect(acknowledgementCalls, 1);
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
        coordinator.accessState.value.status,
        SubscriptionAccessStatus.unavailable,
      );
      expect(acknowledgementCalls, 0);
    },
  );

  test(
    'retries a refused Google Play acknowledgement on the next restore',
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
                return <dynamic>[_purchase().toJson()];
              case 'acknowledgePurchaseAndroid':
                acknowledgementCalls++;
                return acknowledgementCalls > 1;
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
      expect(result.failureCode, SubscriptionFailureCode.acknowledgementFailed);

      final SubscriptionActionResult retry = await coordinator.restore(
        source: 'retry',
      );

      expect(retry.success, isTrue, reason: '${retry.code}: ${retry.message}');
      expect(acknowledgementCalls, 2);
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
      coordinator.accessState.value.status,
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
      coordinator.accessState.value.status,
      SubscriptionAccessStatus.suspended,
    );
    expect(coordinator.accessState.value.shouldGrantAccess, false);
    invalidSignature = true;
    final state = await coordinator.refreshAccessState();
    expect(state.status, SubscriptionAccessStatus.unavailable);
    expect(state.reason, SubscriptionAccessReason.localVerificationFailed);
    expect(state.shouldGrantAccess, false);
  });

  test('其他商品的签名无效事件不覆盖已验证的 Google Play 权益', () async {
    final synced = Completer<SubscriptionActionResult>();
    final valid = _purchase();
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
    final states = <SubscriptionAccessState>[];
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
            state.shouldGrantAccess && state.productId == 'subscribe_month_1',
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
