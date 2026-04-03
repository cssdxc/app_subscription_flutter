import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ExampleSubscriptionService extends GetxService {
  final RxBool isSubscribed = false.obs;
  final hasFreeTrial = true.obs;
  final RxList<ProductSubscriptionIOS> products =
      <ProductSubscriptionIOS>[].obs;

  late final SubscriptionCoordinator coordinator;

  final subscribeWeek1 = 'subscribe_week_1';
  final subscribeMonth1 = 'subscribe_month_1';
  final subscribeYear1 = 'subscribe_year_1';

  Future<ExampleSubscriptionService> init() async {
    final prefs = await SharedPreferences.getInstance();

    coordinator = SubscriptionCoordinator(
      sharedPreferences: prefs,
      config: SubscriptionCoordinatorConfig(
        yearlyProductId: subscribeYear1,
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

    coordinator.isSubscribed.addListener(() {
      isSubscribed.value = coordinator.isSubscribed.value;
    });
    coordinator.hasFreeTrial.addListener(() {
      hasFreeTrial.value = coordinator.hasFreeTrial.value;
    });
    coordinator.products.addListener(() {
      products.value = coordinator.products.value;
    });

    await coordinator.init();
    return this;
  }

  Future<void> loadProducts() => coordinator.loadProducts();

  ProductSubscriptionIOS? findProduct(String productId) {
    return coordinator.findProduct(productId);
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

  void _log(String message) {
    print('[Subscription] $message');
  }

  Future<void> _reportTransaction(
      SubscriptionTransactionPayload payload) async {
    // Call your backend here.
  }
}
