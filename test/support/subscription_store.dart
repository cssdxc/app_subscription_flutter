import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform/platform.dart';

const channel = MethodChannel('flutter_inapp');
const monthly = SubscriptionPlan(appStoreProductId: 'monthly');
const yearly = SubscriptionPlan(appStoreProductId: 'yearly');

ActiveSubscription entitlement(String id) => ActiveSubscription(
  productId: id,
  isActive: true,
  transactionDate: 1,
  transactionId: 'active-$id',
);

PurchaseIOS purchase(String id) => PurchaseIOS(
  id: 'purchase-$id',
  transactionId: 'purchase-$id',
  originalTransactionIdentifierIOS: 'original-$id',
  productId: id,
  isAutoRenewing: true,
  purchaseState: PurchaseState.Purchased,
  quantity: 1,
  store: IapStore.Apple,
  storeId: StoreIds.apple,
  transactionDate: 1,
);

ProductSubscriptionIOS product(String id, {String group = 'group'}) =>
    ProductSubscriptionIOS(
      id: id,
      currency: 'USD',
      description: '',
      title: '',
      displayNameIOS: '',
      displayPrice: r'$12.00',
      price: 12,
      introductoryPricePaymentModeIOS: PaymentModeIOS.FreeTrial,
      subscriptionGroupIdIOS: group,
      isFamilyShareableIOS: false,
      jsonRepresentationIOS: '{}',
      typeIOS: ProductTypeIOS.AutoRenewableSubscription,
    );

void mockStore({
  List<PurchaseIOS> purchases = const [],
  List<ProductSubscriptionIOS> products = const [],
  Future<Object?> Function(MethodCall)? onCall,
}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        if (onCall != null) {
          final value = await onCall(call);
          if (value != null) return value;
        }
        switch (call.method) {
          case 'initConnection':
          case 'restorePurchases':
          case 'endConnection':
          case 'isTransactionVerifiedIOS':
          case 'isEligibleForIntroOfferIOS':
            return true;
          case 'fetchProducts':
            return products.map((item) => item.toJson()).toList();
          case 'getAvailableItems':
            return purchases.map((item) => item.toJson()).toList();
        }
        return null;
      });
}

SubscriptionCoordinator create({
  List<SubscriptionPlan> plans = const [monthly],
  List<String>? subscriptionProductIds,
  ActiveSubscriptionQuery? query,
  required SubscriptionStatusQueryIOS statuses,
  SubscriptionTransactionReporter? report,
  SubscriptionActionObserver? observe,
  SubscriptionLogger? logger,
  VerifiedSubscriptionQuery? verifiedQuery,
  Duration purchaseTimeout = const Duration(seconds: 2),
}) {
  final coordinator = SubscriptionCoordinator(
    iap: FlutterInappPurchase(
      platform: FakePlatform(operatingSystem: Platform.iOS),
    ),
    config: SubscriptionCoordinatorConfig(
      plans: plans,
      subscriptionProductIds: subscriptionProductIds,
      activeSubscriptionQuery: query,
      subscriptionStatusQueryIOS: statuses,
      transactionReporter: report,
      actionObserver: observe,
      logger: logger,
      verifiedSubscriptionQuery: verifiedQuery,
      purchaseTimeout: purchaseTimeout,
    ),
  );
  addTearDown(coordinator.dispose);
  return coordinator;
}
