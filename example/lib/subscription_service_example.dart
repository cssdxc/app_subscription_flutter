import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ExampleSubscriptionService {
  final ValueNotifier<bool> hasFreeTrial = ValueNotifier<bool>(true);
  final ValueNotifier<SubscriptionAccessState> accessState =
      ValueNotifier<SubscriptionAccessState>(
    const SubscriptionAccessState(
      status: SubscriptionAccessStatus.unavailable,
      evaluatedAtMs: 0,
      note: 'not evaluated',
    ),
  );
  final ValueNotifier<List<ProductSubscriptionIOS>> products =
      ValueNotifier<List<ProductSubscriptionIOS>>(<ProductSubscriptionIOS>[]);

  late final SubscriptionCoordinator coordinator;

  final subscribeWeek1 = 'subscribe_week_1';
  final subscribeMonth1 = 'subscribe_month_1';
  final subscribeYear1 = 'subscribe_year_1';

  bool get shouldGrantAccess => accessState.value.shouldGrantAccess;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();

    coordinator = SubscriptionCoordinator(
      sharedPreferences: prefs,
      config: SubscriptionCoordinatorConfig(
        products: const [
          SubscriptionProductConfig(
            id: 'subscribe_week_1',
            defaultPrice: '\$9.99',
          ),
          SubscriptionProductConfig(
            id: 'subscribe_month_1',
            defaultPrice: '\$19.99',
          ),
          SubscriptionProductConfig(
            id: 'subscribe_year_1',
            defaultPrice: '\$49.99',
          ),
        ],
        logger: _log,
        transactionReporter: _reportTransaction,
      ),
    );

    coordinator.accessState.addListener(() {
      accessState.value = coordinator.accessState.value;
    });
    coordinator.hasFreeTrial.addListener(() {
      hasFreeTrial.value = coordinator.hasFreeTrial.value;
    });
    coordinator.products.addListener(() {
      products.value = coordinator.products.value;
    });

    return coordinator.init();
  }

  Future<void> loadProducts() => coordinator.loadProducts();

  ProductSubscriptionIOS? findProduct(String productId) {
    return coordinator.findProduct(productId);
  }

  Future<SubscriptionActionResult> purchaseMonthly({
    String source = 'paywall_monthly',
  }) {
    return purchaseSubscription(
      findProduct(subscribeMonth1),
      source: source,
    );
  }

  Future<SubscriptionActionResult> purchaseYearly({
    String source = 'paywall_yearly',
  }) {
    return purchaseSubscription(
      findProduct(subscribeYear1),
      source: source,
    );
  }

  Future<SubscriptionActionResult> purchaseSubscription(
    ProductSubscriptionIOS? product, {
    required String source,
  }) {
    return coordinator.purchase(product, source: source);
  }

  Future<SubscriptionActionResult> restorePurchases({
    String source = 'manual_restore',
  }) {
    return coordinator.restore(source: source);
  }

  Future<SubscriptionActionResult> restorePurchasesSilently({
    String source = 'silent_restore',
  }) {
    return coordinator.restoreSilently(source: source);
  }

  Future<void> dispose() async {
    hasFreeTrial.dispose();
    accessState.dispose();
    products.dispose();
    await coordinator.dispose();
  }

  void _log(String message) {
    debugPrint('[Subscription] $message');
  }

  Future<void> _reportTransaction(
      SubscriptionTransactionPayload payload) async {
    // Call your backend here.
  }
}
