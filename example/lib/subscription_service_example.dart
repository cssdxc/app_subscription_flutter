import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 演示宿主应用如何封装订阅协调器及其可观察状态。
class ExampleSubscriptionService {
  /// 创建示例订阅服务。
  ExampleSubscriptionService({this.googlePlayLicenseKeyAndroid = ''});

  /// Android 设备端购买签名验证所需的 Play Console 公钥。
  final String googlePlayLicenseKeyAndroid;

  /// 当前商品集合是否包含可用的免费试用。
  final ValueNotifier<bool> hasFreeTrial = ValueNotifier<bool>(true);

  /// 当前统一订阅权益状态。
  final ValueNotifier<SubscriptionAccessState> accessState =
      ValueNotifier<SubscriptionAccessState>(
    const SubscriptionAccessState(
      status: SubscriptionAccessStatus.unavailable,
      evaluatedAtMs: 0,
      note: 'not evaluated',
    ),
  );

  /// 当前已加载的订阅商品。
  final ValueNotifier<List<ProductSubscription>> products =
      ValueNotifier<List<ProductSubscription>>(<ProductSubscription>[]);

  /// 负责实际订阅流程的协调器。
  late final SubscriptionCoordinator coordinator;

  /// 示例周订阅商品标识。
  final subscribeWeek1 = 'subscribe_week_1';

  /// 示例月订阅商品标识。
  final subscribeMonth1 = 'subscribe_month_1';

  /// 示例年订阅商品标识。
  final subscribeYear1 = 'subscribe_year_1';

  /// 当前状态是否应授予订阅权益。
  bool get shouldGrantAccess => accessState.value.shouldGrantAccess;

  /// 初始化存储、协调器和状态监听。
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
        googlePlayLicenseKeyAndroid: googlePlayLicenseKeyAndroid,
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

  /// 从商店加载订阅商品。
  Future<void> loadProducts() => coordinator.loadProducts();

  /// 查找指定订阅商品。
  ProductSubscription? findProduct(String productId) {
    return coordinator.findProduct(productId);
  }

  /// 购买示例月订阅。
  Future<SubscriptionActionResult> purchaseMonthly({
    String source = 'paywall_monthly',
  }) {
    return purchaseSubscription(
      findProduct(subscribeMonth1),
      source: source,
    );
  }

  /// 购买示例年订阅。
  Future<SubscriptionActionResult> purchaseYearly({
    String source = 'paywall_yearly',
  }) {
    return purchaseSubscription(
      findProduct(subscribeYear1),
      source: source,
    );
  }

  /// 购买调用方指定的订阅商品。
  Future<SubscriptionActionResult> purchaseSubscription(
    ProductSubscription? product, {
    required String source,
  }) {
    return coordinator.purchase(product, source: source);
  }

  /// 通过用户操作恢复已有购买。
  Future<SubscriptionActionResult> restorePurchases({
    String source = 'manual_restore',
  }) {
    return coordinator.restore(source: source);
  }

  /// 静默恢复已有购买。
  Future<SubscriptionActionResult> restorePurchasesSilently({
    String source = 'silent_restore',
  }) {
    return coordinator.restoreSilently(source: source);
  }

  /// 释放示例服务和订阅协调器资源。
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
    // 可在此按需记录交易或接入审计系统。
  }
}
