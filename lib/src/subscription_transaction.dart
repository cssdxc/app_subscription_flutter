import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

import 'subscription_action_result.dart';

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

/// 一次 Google Play 订阅确认尝试的结果，不代表购买操作或权益的结果。
class GooglePlayAcknowledgementEvent {
  const GooglePlayAcknowledgementEvent({
    required this.productId,
    required this.type,
    required this.source,
    this.transactionId,
    this.error,
  });

  final String productId;

  /// 商店订单标识（如有），不回传购买令牌。
  final String? transactionId;

  final SubscriptionActionType type;
  final String source;
  final GooglePlayAcknowledgementError? error;
  bool get success => error == null;
}

/// Android 原生通道提供的失败信息，不使用本库的订阅错误码。
class GooglePlayAcknowledgementError {
  const GooglePlayAcknowledgementError({
    this.responseCode,
    this.debugMessage,
    this.nativeCode,
    this.nativeMessage,
  });

  /// Google BillingResult 的数字响应码；原生未返回时为空。
  final int? responseCode;

  /// Google BillingResult 的原始调试说明；原生未返回时为空。
  final String? debugMessage;

  /// 插件原生异常码，可能是 OpenIAP 对响应码的映射。
  final String? nativeCode;

  /// 插件原生异常说明，不作为 Google 原始 debugMessage 使用。
  final String? nativeMessage;
}
