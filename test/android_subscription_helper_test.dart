import 'dart:async';
import 'dart:convert';

import 'package:app_subscription_core/app_subscription_core.dart';
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
      products: const <SubscriptionProductConfig>[
        SubscriptionProductConfig(
          id: 'subscribe_month_1',
          defaultPrice: r'$9.99',
        ),
      ],
      activeSubscriptionQuery: (_) async => <ActiveSubscription>[
        _activeSubscription(),
      ],
      actionObserver: actionObserver,
      googlePlayLicenseKeyAndroid: _licenseKey,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('grants access only for active Google Play subscriptions', () {
    final SubscriptionAccessState state =
        AndroidSubscriptionHelper.resolveAccessStateFromActiveSubscriptions(
      <ActiveSubscription>[_activeSubscription()],
      fallbackProductId: 'subscribe_month_1',
    );

    expect(state.status, SubscriptionAccessStatus.active);
    expect(state.shouldGrantAccess, isTrue);
  });

  test('requires a Google Play license key on Android', () {
    final FlutterInappPurchase iap = FlutterInappPurchase(
      platform: FakePlatform(operatingSystem: Platform.android),
    );

    expect(() => SubscriptionStoreAdapter.forIap(iap), throwsArgumentError);
  });

  test('does not process pending or suspended purchases', () {
    final PurchaseAndroid pending = _purchase(state: PurchaseState.Pending);
    final PurchaseAndroid suspended = _purchase(suspended: true);

    expect(AndroidSubscriptionHelper.isPending(pending), isTrue);
    expect(
      AndroidSubscriptionHelper.shouldProcessPurchaseUpdate(pending),
      isFalse,
    );
    expect(
      AndroidSubscriptionHelper.shouldProcessPurchaseUpdate(suspended),
      isFalse,
    );
    expect(
      const GooglePlaySubscriptionAdapter()
          .blockingAccessState(suspended)
          ?.status,
      SubscriptionAccessStatus.billingRetry,
    );
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

  test('requires an explicit offer when multiple offers are eligible', () {
    final ProductSubscriptionAndroid product = _product(<SubscriptionOffer>[
      _offer(id: 'base', token: 'base-token'),
      _offer(id: 'trial', token: 'trial-token'),
    ]);

    expect(
      () => AndroidSubscriptionHelper.resolvePurchaseOffer(product),
      throwsA(
        isA<AndroidSubscriptionOfferException>().having(
          (error) => error.code,
          'code',
          'offer-required',
        ),
      ),
    );
    expect(
      AndroidSubscriptionHelper.resolvePurchaseOffer(
        product,
        requestedOffer: product.subscriptionOffers.last,
      ).offerTokenAndroid,
      'trial-token',
    );
  });

  test('detects free trials from eligible Google Play offers', () {
    expect(
      AndroidSubscriptionHelper.hasFreeTrial(<ProductSubscriptionAndroid>[
        _product(<SubscriptionOffer>[
          _offer(
            id: 'trial',
            token: 'trial-token',
            paymentMode: PaymentMode.FreeTrial,
          ),
        ]),
      ]),
      isTrue,
    );
  });

  test('passes the selected offer token to the Google Play billing flow',
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
      options: SubscriptionPurchaseOptions(
        offer: product.subscriptionOffers.single,
        obfuscatedAccountIdAndroid: 'account-hash',
      ),
    );

    expect(purchaseArguments?['type'], 'subs');
    expect(purchaseArguments?['productId'], 'subscribe_month_1');
    expect(purchaseArguments?['obfuscatedAccountId'], 'account-hash');
    expect(
      purchaseArguments?['subscriptionOffers'],
      <Map<String, String>>[
        <String, String>{
          'sku': 'subscribe_month_1',
          'offerToken': 'trial-token',
        },
      ],
    );
  });

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

    final SubscriptionActionResult result =
        await coordinator.restore(source: 'test');

    expect(result.success, isTrue);
    expect(acknowledgementCalls, 1);
  });

  test('does not acknowledge when local signature verification fails',
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

    final SubscriptionActionResult result =
        await coordinator.restore(source: 'test');

    expect(result.success, isFalse);
    expect(result.code, 'local-verification-failed');
    expect(
        coordinator.accessState.value.status, SubscriptionAccessStatus.revoked);
    expect(acknowledgementCalls, 0);
  });

  test('returns a failure when Google Play acknowledgement fails', () async {
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
          return false;
        case 'endConnection':
          return true;
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_iapChannel, null);
    });

    final SubscriptionActionResult result =
        await coordinator.restore(source: 'test');

    expect(result.success, isFalse);
    expect(result.code, 'acknowledgement-failed');
  });

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

    final Future<SubscriptionActionResult> firstRestore =
        coordinator.restore(source: 'first');
    while (availablePurchaseQueries == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    final SubscriptionActionResult overlappingRestore =
        await coordinator.restore(source: 'second');
    releaseFirstQuery.complete();
    await firstRestore;

    expect(overlappingRestore.success, isFalse);
    expect(overlappingRestore.code, 'busy');
  });

  test('ignores unrelated updates and emits one finished event on error',
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

    final Future<SubscriptionActionResult> purchaseFuture =
        coordinator.purchase(
      _product(<SubscriptionOffer>[
        _offer(id: 'base', token: 'base-token'),
      ]),
      source: 'test',
    );
    bool purchaseCompleted = false;
    purchaseFuture.whenComplete(() => purchaseCompleted = true);
    await purchaseRequested.future;
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
      events.where((event) => event.phase == SubscriptionActionPhase.finished),
      hasLength(1),
    );
  });

  test('reconnects after a purchase request reports a disconnected service',
      () async {
    final FlutterInappPurchase iap = FlutterInappPurchase(
      platform: FakePlatform(operatingSystem: Platform.android),
    );
    final ProductSubscriptionAndroid product = _product(<SubscriptionOffer>[
      _offer(id: 'base', token: 'base-token'),
    ]);
    int initCalls = 0;
    int requestCalls = 0;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_iapChannel, (MethodCall call) async {
      switch (call.method) {
        case 'initConnection':
          initCalls++;
          return true;
        case 'requestPurchase':
          requestCalls++;
          throw PlatformException(code: 'E_SERVICE_DISCONNECTED');
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
      storeAdapter:
          const GooglePlaySubscriptionAdapter(licenseKey: _licenseKey),
      config: const SubscriptionCoordinatorConfig(
        products: <SubscriptionProductConfig>[
          SubscriptionProductConfig(
            id: 'subscribe_month_1',
            defaultPrice: r'$9.99',
          ),
        ],
      ),
    );
    addTearDown(coordinator.dispose);

    final SubscriptionActionResult first = await coordinator.purchase(
      product,
      source: 'first',
    );
    final SubscriptionActionResult second = await coordinator.purchase(
      product,
      source: 'second',
    );

    expect(first.success, isFalse);
    expect(second.success, isFalse);
    expect(requestCalls, 2);
    expect(initCalls, 2);
  });

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

    final SubscriptionActionResult result =
        await coordinator.restore(source: 'test');

    expect(result.success, isTrue);
    expect(coordinator.accessState.value.shouldGrantAccess, isTrue);
    expect(
      coordinator.accessState.value.status,
      SubscriptionAccessStatus.active,
    );
  });
}
