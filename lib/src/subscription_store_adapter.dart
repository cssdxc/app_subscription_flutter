import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

import 'app_store_subscription_adapter.dart';
import 'google_play_subscription_adapter.dart';
import 'subscription_access_state.dart';
import 'subscription_transaction.dart';
import 'subscription_failure.dart';
import 'subscription_plan.dart';

/// 查询一个 App Store 订阅组的 StoreKit 2 状态；主要用于测试替换默认查询。
typedef SubscriptionStatusQueryIOS =
    Future<List<SubscriptionStatusIOS>> Function(String productId);

/// 发起订阅购买时传给对应商店的可选参数。
class SubscriptionPurchaseOptions {
  /// 创建平台购买参数；未提供的字段由商店使用默认行为。
  const SubscriptionPurchaseOptions({
    this.offer,
    this.appAccountTokenIOS,
    this.obfuscatedAccountIdAndroid,
    this.obfuscatedProfileIdAndroid,
    this.isOfferPersonalizedAndroid,
  });

  /// 要购买的 base plan 或促销 offer；当前仅 Android 使用。
  final SubscriptionOffer? offer;

  /// 关联 App Store 交易与应用账户的 UUID 字符串。
  final String? appAccountTokenIOS;

  /// 经过不可逆散列的 Google Play 账户标识。
  final String? obfuscatedAccountIdAndroid;

  /// 经过不可逆散列的 Google Play 用户资料标识。
  final String? obfuscatedProfileIdAndroid;

  /// Google Play 促销价格是否基于用户个性化处理。
  final bool? isOfferPersonalizedAndroid;

  /// 保留账户关联等参数，仅替换由套餐解析出的 offer。
  SubscriptionPurchaseOptions withOffer(SubscriptionOffer? value) =>
      SubscriptionPurchaseOptions(
        offer: value,
        appAccountTokenIOS: appAccountTokenIOS,
        obfuscatedAccountIdAndroid: obfuscatedAccountIdAndroid,
        obfuscatedProfileIdAndroid: obfuscatedProfileIdAndroid,
        isOfferPersonalizedAndroid: isOfferPersonalizedAndroid,
      );
}

/// 隔离 App Store 与 Google Play 差异的订阅商店适配契约。
abstract interface class SubscriptionStoreAdapter {
  /// 根据插件当前平台创建对应的商店适配器。
  factory SubscriptionStoreAdapter.forIap(
    FlutterInappPurchase iap, {
    String googlePlayLicenseKeyAndroid = '',
    SubscriptionStatusQueryIOS? subscriptionStatusQueryIOS,
  }) {
    if (iap.isAndroid) {
      if (googlePlayLicenseKeyAndroid.trim().isEmpty) {
        throw ArgumentError.value(
          googlePlayLicenseKeyAndroid,
          'googlePlayLicenseKeyAndroid',
          'A Google Play license key is required on Android.',
        );
      }
      return GooglePlaySubscriptionAdapter(
        licenseKey: googlePlayLicenseKeyAndroid,
      );
    }
    if (iap.isIOS) {
      return AppStoreSubscriptionAdapter(
        subscriptionStatusQuery: subscriptionStatusQueryIOS,
      );
    }
    throw UnsupportedError(
      'Subscriptions are supported only on iOS and Android.',
    );
  }

  /// 当前适配器是否支持该商品类型。
  bool supportsProduct(ProductSubscription product);

  /// 当前适配器是否支持该购买对象类型。
  bool supportsPurchase(Purchase purchase);

  /// 返回商品在当前商店可购买的 offer。
  List<SubscriptionOffer> offersFor(ProductSubscription product);

  /// 将平台购买对象中的商品标识归一化。
  String normalizedProductId(Purchase purchase);

  /// 判断交易是否仍在等待处理。
  bool isPending(Purchase purchase);

  /// 判断购买更新是否可以进入验证流程。
  bool shouldProcessPurchaseUpdate(Purchase purchase);

  /// 返回能够立即阻断权益的商店状态，否则返回空。
  SubscriptionAccessState? blockingAccessState(Purchase purchase);

  /// 向当前商店发起订阅购买。
  Future<void> requestPurchase({
    required FlutterInappPurchase iap,
    required ProductSubscription product,
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
  Future<SubscriptionAccessState> resolveVerifiedAccessState({
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

/// 表示商店适配、验证或交易完成过程中的可分类错误。
class SubscriptionStoreException implements Exception {
  /// 创建包含稳定错误码和说明的商店异常。
  const SubscriptionStoreException({
    required this.failureCode,
    required this.message,
  });

  /// 可供调用方分类处理的错误码。
  final SubscriptionFailureCode failureCode;
  String get code => failureCode.code;

  /// 面向日志或调用方的错误说明。
  final String message;

  @override
  String toString() => message;
}
