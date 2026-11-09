import 'package:app_subscription_core/app_subscription_core.dart';

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

/// plans 只列当前在售商品；默认识别全部订阅，单一权益直接读取 accessState.value.shouldGrantAccess。
SubscriptionCoordinator createExampleSubscription({
  required String googlePlayLicenseKey,
  VerifiedSubscriptionQuery? verifiedSubscriptionQuery,
  SubscriptionTransactionReporter? transactionReporter,
}) => SubscriptionCoordinator(
  config: SubscriptionCoordinatorConfig(
    plans: examplePlans.values.toList(),
    googlePlayLicenseKeyAndroid: googlePlayLicenseKey,
    verifiedSubscriptionQuery: verifiedSubscriptionQuery,
    transactionReporter: transactionReporter,
  ),
);
