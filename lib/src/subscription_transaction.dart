import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

/// 向宿主应用回传的跨商店交易载荷。
class SubscriptionTransactionPayload {
  /// 创建一份可供记录或审计的交易载荷。
  const SubscriptionTransactionPayload({
    required this.productId,
    required this.store,
    required this.originalTransactionId,
    required this.currentTransactionId,
    required this.purchase,
    this.purchaseToken,
    this.packageNameAndroid,
  });

  /// 商品标识。
  final String productId;

  /// 交易所属的应用商店。
  final IapStore store;

  /// 原始交易标识；Android 使用购买令牌作为稳定标识。
  final String originalTransactionId;

  /// 当前交易标识。
  final String currentTransactionId;

  /// 商店返回的购买令牌或 StoreKit JWS。
  final String? purchaseToken;

  /// Android 应用包名。
  final String? packageNameAndroid;

  /// 插件返回的原始购买对象。
  final Purchase purchase;
}
