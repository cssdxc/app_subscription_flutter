import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

import 'subscription_failure.dart';
import 'subscription_price.dart';

/// 试用资格未查询、不可确定与明确不符合资格分别表示。
enum SubscriptionTrialEligibility { unknown, eligible, ineligible }

/// 一个逻辑套餐在 Google Play 的精确映射，不根据价格猜测 offer。
class GooglePlayPlan {
  const GooglePlayPlan({
    required this.productId,
    required this.basePlanId,
    this.offerId,
    this.fallbackToBasePlan = false,
  }) : assert(productId != ''),
       assert(basePlanId != ''),
       assert(offerId != '');

  final String productId;
  final String basePlanId;

  /// null 表示只选择普通 base plan，不是匹配任意 offer。
  final String? offerId;

  /// 指定 offer 不可用时，是否允许购买同一 base plan 的普通价格。
  final bool fallbackToBasePlan;
}

/// 宿主自己定义套餐名称/枚举，库仅保存商店映射与明确的展示兜底。
class SubscriptionPlan {
  const SubscriptionPlan({
    this.appStoreProductId,
    this.googlePlay,
    this.fallbackPrice = '',
  }) : assert(appStoreProductId != null || googlePlay != null),
       assert(appStoreProductId != '');

  final String? appStoreProductId;
  final GooglePlayPlan? googlePlay;

  /// 仅用于商品未加载时的展示，不能据此发起购买或计算平均价。
  final String fallbackPrice;

  String? productIdFor(IapStore store) => switch (store) {
    IapStore.Apple => appStoreProductId,
    IapStore.Google => googlePlay?.productId,
    _ => null,
  };
}

/// 同一解析结果同时提供展示价格与购买 offer，防止两者选择不同方案。
class SubscriptionPlanDetails {
  const SubscriptionPlanDetails({
    required this.plan,
    required this.store,
    this.product,
    this.offer,
    this.price,
    this.storeDisplayPrice,
    this.failureCode,
    this.trialEligibility = SubscriptionTrialEligibility.unknown,
    this.trialPeriod,
  });

  final SubscriptionPlan plan;
  final IapStore store;
  final ProductSubscription? product;
  final SubscriptionOffer? offer;

  /// 正常续费/预付计费阶段价格，与试用或首期优惠价格分开。
  final SubscriptionPrice? price;

  /// 数值价格缺失时，仍可展示商店明确返回的当前计费阶段文案。
  final String? storeDisplayPrice;
  final SubscriptionFailureCode? failureCode;
  final SubscriptionTrialEligibility trialEligibility;

  /// 商店明确返回的免费试用周期；月、年不能当作固定天数。
  final SubscriptionPeriod? trialPeriod;

  String? get productId => plan.productIdFor(store);
  String get displayPrice =>
      price?.displayPrice ?? storeDisplayPrice ?? plan.fallbackPrice;
  bool get canPurchase => product != null && failureCode == null;
  bool get hasFreeTrial =>
      trialEligibility == SubscriptionTrialEligibility.eligible;
}
