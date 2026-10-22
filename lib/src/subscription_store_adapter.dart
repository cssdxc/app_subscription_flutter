import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

import 'subscription_access_state.dart';
import 'subscription_transaction.dart';
import 'subscription_failure.dart';
import 'subscription_plan.dart';

/// 查询一个 App Store 订阅组的 StoreKit 2 状态；主要用于测试替换默认查询。
typedef SubscriptionStatusQueryIOS =
    Future<List<SubscriptionStatusIOS>> Function(String productId);

/// 商店权益查询结果，以及因查询异常而未能确定状态的商品集合。
typedef SubscriptionAccessResolution = ({
  SubscriptionAccessState state,
  Set<String> queryFailedProductIds,
});

/// 发起订阅购买时传给对应商店的可选参数。
class SubscriptionPurchaseOptions {
  /// 创建平台购买参数；未提供的字段由商店使用默认行为。
  const SubscriptionPurchaseOptions({
    this.appAccountTokenIOS,
    this.obfuscatedAccountIdAndroid,
    this.obfuscatedProfileIdAndroid,
    this.isOfferPersonalizedAndroid,
  });

  /// 关联 App Store 交易与应用账户的 UUID 字符串。
  final String? appAccountTokenIOS;

  /// 经过不可逆散列的 Google Play 账户标识。
  final String? obfuscatedAccountIdAndroid;

  /// 经过不可逆散列的 Google Play 用户资料标识。
  final String? obfuscatedProfileIdAndroid;

  /// Google Play 促销价格是否基于用户个性化处理。
  final bool? isOfferPersonalizedAndroid;
}

/// 隔离 App Store 与 Google Play 差异的订阅商店适配契约。
abstract interface class SubscriptionStoreAdapter {
  /// 当前适配器是否支持该购买对象类型。
  bool supportsPurchase(Purchase purchase);

  /// 检查平台特有的交易限制；通用购买状态由交易处理器判断。
  SubscriptionFailureCode? purchaseFailure(Purchase purchase);

  /// 向当前商店发起订阅购买，优惠由套餐目录解析。
  Future<void> requestPurchase({
    required FlutterInappPurchase iap,
    required ProductSubscription product,
    required SubscriptionOffer? offer,
    required SubscriptionPurchaseOptions options,
  });

  /// 恢复或重新查询当前商店中的已有购买。
  Future<List<Purchase>> restorePurchases(FlutterInappPurchase iap);

  /// 完成 App Store 交易或确认 Google Play 购买。
  Future<void> finishTransaction({
    required FlutterInappPurchase iap,
    required Purchase purchase,
  });

  /// 使用平台提供的数据在设备端验证购买真实性。
  Future<void> verifyPurchaseLocally({
    required FlutterInappPurchase iap,
    required Purchase purchase,
  });

  /// 将已验证的商店订阅解析为统一权益状态。
  Future<SubscriptionAccessResolution> resolveVerifiedAccessState({
    required FlutterInappPurchase iap,
    required List<ActiveSubscription> subscriptions,
    required List<ProductSubscription> products,
    required List<String> productIds,
    required String fallbackProductId,
    DateTime? now,
  });

  /// Apple 按订阅组查询试用资格；Google 的资格由目录按已选优惠解析。
  Future<Map<String, SubscriptionTrialEligibility>> queryTrialEligibility({
    required FlutterInappPurchase iap,
    required List<ProductSubscription> products,
  });

  /// 将平台购买对象转换为统一交易回传载荷。
  SubscriptionTransactionPayload transactionPayload(Purchase purchase);
}
