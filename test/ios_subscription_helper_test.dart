import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:app_subscription_core/src/ios_subscription_helper.dart';
import 'package:app_subscription_core/src/app_store_subscription_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform/platform.dart';

ActiveSubscription _entitlement({
  String productId = 'subscribe_month_1',
  String transactionId = 'tx_1',
  double transactionDate = 1,
  double? expirationDateIOS,
  RenewalInfoIOS? renewalInfoIOS,
}) {
  return ActiveSubscription(
    isActive: false,
    productId: productId,
    transactionDate: transactionDate,
    transactionId: transactionId,
    expirationDateIOS: expirationDateIOS,
    renewalInfoIOS: renewalInfoIOS,
  );
}

ProductSubscriptionIOS _product({required String id, required String groupId}) {
  return ProductSubscriptionIOS(
    currency: 'USD',
    description: id,
    displayNameIOS: id,
    displayPrice: r'$9.99',
    id: id,
    introductoryPricePaymentModeIOS: PaymentModeIOS.PayAsYouGo,
    isFamilyShareableIOS: false,
    jsonRepresentationIOS: '{}',
    subscriptionGroupIdIOS: groupId,
    title: id,
    typeIOS: ProductTypeIOS.AutoRenewableSubscription,
  );
}

void main() {
  const int nowMs = 1700000000000;

  TestWidgetsFlutterBinding.ensureInitialized();

  test('通过插件解析新版原生 StoreKit 状态，宽限期不依赖 isActive', () async {
    const MethodChannel channel = MethodChannel('flutter_inapp');
    final FlutterInappPurchase iap = FlutterInappPurchase(
      platform: FakePlatform(operatingSystem: Platform.iOS),
    );
    const AppStoreSubscriptionAdapter adapter = AppStoreSubscriptionAdapter();
    final Map<String, SubscriptionAccessStatus> expectedStatuses =
        <String, SubscriptionAccessStatus>{
          'subscribed': SubscriptionAccessStatus.active,
          'inGracePeriod': SubscriptionAccessStatus.gracePeriod,
          'inBillingRetryPeriod': SubscriptionAccessStatus.billingRetry,
          'expired': SubscriptionAccessStatus.expired,
          'revoked': SubscriptionAccessStatus.revoked,
          'unknown': SubscriptionAccessStatus.unavailable,
        };
    String nativeState = 'unknown';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'subscriptionStatusIOS');
          expect(call.arguments, <String, String>{'sku': 'subscribe_month_1'});
          return <Map<String, Object>>[
            <String, Object>{
              'state': nativeState,
              'renewalInfo': <String, Object>{
                'willAutoRenew': true,
                'gracePeriodExpirationDate': 1,
              },
            },
          ];
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    for (final MapEntry<String, SubscriptionAccessStatus> entry
        in expectedStatuses.entries) {
      nativeState = entry.key;
      final resolution = await adapter.resolveVerifiedAccessState(
        iap: iap,
        subscriptions: <ActiveSubscription>[_entitlement()],
        products: const <ProductSubscription>[],
        productIds: const <String>['subscribe_month_1'],
        fallbackProductId: 'subscribe_month_1',
        now: DateTime.fromMillisecondsSinceEpoch(nowMs),
      );

      final state = resolution.state;
      expect(state.status, entry.value, reason: nativeState);
      if (nativeState == 'inGracePeriod') {
        expect(state.shouldGrantAccess, isTrue);
        expect(state.effectiveUntilMs, 1);
      }
    }
  });

  test('按 Apple StoreKit 状态映射五种订阅生命周期', () {
    final ActiveSubscription entitlement = _entitlement(
      expirationDateIOS: (nowMs + 10000).toDouble(),
    );
    final Map<String, SubscriptionAccessStatus> expectedStatuses =
        <String, SubscriptionAccessStatus>{
          'subscribed': SubscriptionAccessStatus.active,
          'inGracePeriod': SubscriptionAccessStatus.gracePeriod,
          'inBillingRetryPeriod': SubscriptionAccessStatus.billingRetry,
          'expired': SubscriptionAccessStatus.expired,
          'revoked': SubscriptionAccessStatus.revoked,
        };

    for (final MapEntry<String, SubscriptionAccessStatus> entry
        in expectedStatuses.entries) {
      final SubscriptionAccessState state =
          IosSubscriptionHelper.resolveAccessStateFromSubscriptionStatus(
            status: SubscriptionStatusIOS(state: entry.key),
            verifiedEntitlement: entitlement,
            fallbackProductId: 'fallback',
            now: DateTime.fromMillisecondsSinceEpoch(nowMs),
          );

      expect(state.status, entry.value, reason: entry.key);
    }
  });

  test('未知 StoreKit 状态使用已验证权益字段确定性降级', () {
    final ActiveSubscription entitlement = _entitlement(
      expirationDateIOS: (nowMs + 10000).toDouble(),
    );

    final SubscriptionAccessState state =
        IosSubscriptionHelper.resolveAccessStateFromSubscriptionStatus(
          status: const SubscriptionStatusIOS(
            state: 'RenewalState(rawValue: 1)',
          ),
          verifiedEntitlement: entitlement,
          fallbackProductId: 'fallback',
          now: DateTime.fromMillisecondsSinceEpoch(nowMs),
        );

    expect(state.status, SubscriptionAccessStatus.unavailable);
    expect(state.shouldGrantAccess, isFalse);
  });

  test('未知 StoreKit 状态可由 isActive 的已验证权益确定为 active', () {
    final ActiveSubscription entitlement = ActiveSubscription(
      isActive: true,
      productId: 'subscribe_month_1',
      transactionDate: 1,
      transactionId: 'tx-active',
    );

    final SubscriptionAccessState state =
        IosSubscriptionHelper.resolveAccessStateFromSubscriptionStatus(
          status: const SubscriptionStatusIOS(
            state: 'RenewalState(rawValue: 1)',
          ),
          verifiedEntitlement: entitlement,
          fallbackProductId: 'fallback',
          now: DateTime.fromMillisecondsSinceEpoch(nowMs),
        );

    expect(state.status, SubscriptionAccessStatus.active);
  });

  test('宽限期由 StoreKit 状态决定，不比较设备时间', () {
    final SubscriptionAccessState state =
        IosSubscriptionHelper.resolveAccessStateFromSubscriptionStatus(
          status: const SubscriptionStatusIOS(
            state: 'inGracePeriod',
            renewalInfo: RenewalInfoIOS(
              gracePeriodExpirationDate: 1,
              willAutoRenew: true,
            ),
          ),
          verifiedEntitlement: _entitlement(),
          fallbackProductId: 'subscribe_month_1',
          now: DateTime.fromMillisecondsSinceEpoch(nowMs),
        );

    expect(state.status, SubscriptionAccessStatus.gracePeriod);
    expect(state.shouldGrantAccess, isTrue);
    expect(state.effectiveUntilMs, 1);
  });

  test('可放行的 Apple 状态必须同时存在已验证当前权益', () {
    for (final String storeKitState in <String>[
      'subscribed',
      'inGracePeriod',
    ]) {
      final SubscriptionAccessState state =
          IosSubscriptionHelper.resolveAccessStateFromSubscriptionStatus(
            status: SubscriptionStatusIOS(state: storeKitState),
            verifiedEntitlement: null,
            fallbackProductId: 'subscribe_month_1',
            now: DateTime.fromMillisecondsSinceEpoch(nowMs),
          );

      expect(
        state.status,
        SubscriptionAccessStatus.unavailable,
        reason: storeKitState,
      );
      expect(state.shouldGrantAccess, isFalse);
    }
  });

  test('未知 Apple 状态不会授予权益', () {
    final SubscriptionAccessState state =
        IosSubscriptionHelper.resolveAccessStateFromSubscriptionStatus(
          status: const SubscriptionStatusIOS(state: 'futureState'),
          verifiedEntitlement: _entitlement(),
          fallbackProductId: 'subscribe_month_1',
          now: DateTime.fromMillisecondsSinceEpoch(nowMs),
        );

    expect(state.status, SubscriptionAccessStatus.unavailable);
    expect(state.shouldGrantAccess, isFalse);
  });

  test('StoreKit 成功返回空状态时视为没有订阅', () {
    final SubscriptionAccessState state =
        IosSubscriptionHelper.resolveAccessStateFromSubscriptionStatuses(
          const <SubscriptionStatusIOS>[],
          verifiedEntitlements: const <ActiveSubscription>[],
          fallbackProductId: 'subscribe_month_1',
          now: DateTime.fromMillisecondsSinceEpoch(nowMs),
        );

    expect(state.status, SubscriptionAccessStatus.expired);
    expect(state.shouldGrantAccess, isFalse);
  });

  test('同一 App Store 订阅组只查询一次状态', () async {
    final List<String> queriedProductIds = <String>[];
    final AppStoreSubscriptionAdapter adapter = AppStoreSubscriptionAdapter(
      subscriptionStatusQuery: (productId) async {
        queriedProductIds.add(productId);
        return <SubscriptionStatusIOS>[
          SubscriptionStatusIOS(
            state: productId == 'pro_month' ? 'expired' : 'subscribed',
          ),
        ];
      },
    );
    final FlutterInappPurchase iap = FlutterInappPurchase(
      platform: FakePlatform(operatingSystem: Platform.iOS),
    );

    final resolution = await adapter.resolveVerifiedAccessState(
      iap: iap,
      subscriptions: <ActiveSubscription>[
        _entitlement(productId: 'basic_month'),
      ],
      products: <ProductSubscription>[
        _product(id: 'basic_month', groupId: 'basic'),
        _product(id: 'basic_year', groupId: 'basic'),
        _product(id: 'pro_month', groupId: 'pro'),
      ],
      productIds: const <String>['basic_month', 'basic_year', 'pro_month'],
      fallbackProductId: 'basic_month,basic_year,pro_month',
      now: DateTime.fromMillisecondsSinceEpoch(nowMs),
    );

    expect(queriedProductIds, <String>['basic_month', 'pro_month']);
    expect(resolution.state.status, SubscriptionAccessStatus.active);
    expect(resolution.state.productId, 'basic_month');
  });

  test('任一订阅组查询失败且没有有效权益时返回不可用', () async {
    final AppStoreSubscriptionAdapter adapter = AppStoreSubscriptionAdapter(
      subscriptionStatusQuery: (productId) async {
        if (productId == 'pro_month') {
          throw Exception('offline');
        }
        return const <SubscriptionStatusIOS>[
          SubscriptionStatusIOS(state: 'expired'),
        ];
      },
    );
    final FlutterInappPurchase iap = FlutterInappPurchase(
      platform: FakePlatform(operatingSystem: Platform.iOS),
    );

    final resolution = await adapter.resolveVerifiedAccessState(
      iap: iap,
      subscriptions: const <ActiveSubscription>[],
      products: <ProductSubscription>[
        _product(id: 'basic_month', groupId: 'basic'),
        _product(id: 'pro_month', groupId: 'pro'),
      ],
      productIds: const <String>['basic_month', 'pro_month'],
      fallbackProductId: 'basic_month,pro_month',
      now: DateTime.fromMillisecondsSinceEpoch(nowMs),
    );

    expect(resolution.state.status, SubscriptionAccessStatus.unavailable);
    expect(resolution.state.shouldGrantAccess, isFalse);
    expect(resolution.queryFailedProductIds, {'pro_month'});
  });
}
