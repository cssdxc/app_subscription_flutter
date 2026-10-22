/// 封装自身的失败原因；商店错误使用插件的 ErrorCode，二者不混用。
enum SubscriptionFailureCode {
  unsupportedPlatform('unsupported-platform'),
  productNotFound('product-not-found'),
  invalidProductPlatform('invalid-product-platform'),
  busy('busy'),
  disposed('disposed'),
  planNotConfigured('plan-not-configured'),
  storeUnavailable('store-unavailable'),
  requestFailed('request-failed'),
  restoreException('restore-exception'),
  restoreInactive('restore-inactive'),
  purchasePending('purchase-pending'),
  subscriptionSuspended('subscription-suspended'),
  ignoredState('ignored-state'),
  unknownSku('unknown-sku'),
  subscriptionInactive('subscription-inactive'),
  storeQueryFailed('store-query-failed'),
  processingException('processing-exception'),
  invalidOffer('invalid-offer'),
  offerRequired('offer-required'),
  offerUnavailable('offer-unavailable'),
  acknowledgementFailed('acknowledgement-failed'),
  localVerificationFailed('local-verification-failed'),
  missingLicenseKey('missing-license-key'),
  missingPurchaseToken('missing-purchase-token');

  const SubscriptionFailureCode(this.code);

  /// 仅供日志和上报使用的稳定编码，业务判断使用枚举。
  final String code;
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
