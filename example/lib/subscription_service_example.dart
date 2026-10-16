import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 套餐名称属于宿主；库不要求统一各产品的业务枚举。
enum ExamplePlan { monthly, yearly }

/// 示例标识需要替换为宿主在两个商店中实际配置的标识。
const examplePlans = <ExamplePlan, SubscriptionPlan>{
  ExamplePlan.monthly: SubscriptionPlan(
    appStoreProductId: 'example.subscription.monthly',
    googlePlay: GooglePlayPlan(
      productId: 'example.subscription',
      basePlanId: 'monthly',
    ),
  ),
  ExamplePlan.yearly: SubscriptionPlan(
    appStoreProductId: 'example.subscription.yearly',
    googlePlay: GooglePlayPlan(
      productId: 'example.subscription',
      basePlanId: 'yearly',
      offerId: 'yearly-trial',
      fallbackToBasePlan: true,
    ),
  ),
};

/// 宿主只装配配置和业务回调，无须重复转发通知器或自己维护购买 loading。
Future<SubscriptionCoordinator> createExampleSubscription({
  required String googlePlayLicenseKey,
  SubscriptionTransactionReporter? transactionReporter,
}) async {
  final coordinator = SubscriptionCoordinator(
    sharedPreferences: await SharedPreferences.getInstance(),
    config: SubscriptionCoordinatorConfig(
      plans: examplePlans.values.toList(),
      googlePlayLicenseKeyAndroid: googlePlayLicenseKey,
      transactionReporter: transactionReporter,
    ),
  );
  await coordinator.init();
  return coordinator;
}
