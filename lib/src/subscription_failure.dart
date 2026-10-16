/// 封装自身的失败原因；商店错误使用插件的 ErrorCode，二者不混用。
enum SubscriptionFailureCode {
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
  billingRetry('billing-retry'),
  ignoredState('ignored-state'),
  unknownSku('unknown-sku'),
  validationFailed('validation-failed'),
  processingException('processing-exception'),
  invalidOffer('invalid-offer'),
  offerRequired('offer-required'),
  offerUnavailable('offer-unavailable'),
  unsupportedOffer('unsupported-offer'),
  acknowledgementFailed('acknowledgement-failed'),
  localVerificationFailed('local-verification-failed'),
  missingLicenseKey('missing-license-key'),
  missingPurchaseToken('missing-purchase-token');

  const SubscriptionFailureCode(this.code);

  /// 仅供日志和上报使用的稳定编码，业务判断使用枚举。
  final String code;
}
