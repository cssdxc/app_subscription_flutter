import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

enum SubscriptionActionType {
  purchase,
  restore,
  sync,
}

class SubscriptionActionResult {
  const SubscriptionActionResult({
    required this.type,
    required this.success,
    this.silent = false,
    this.cancelled = false,
    this.productId,
    this.code,
    this.message,
    this.purchase,
    this.restoredCount = 0,
  });

  final SubscriptionActionType type;
  final bool success;
  final bool silent;
  final bool cancelled;
  final String? productId;
  final String? code;
  final String? message;
  final PurchaseIOS? purchase;
  final int restoredCount;

  bool get failed => !success;

  factory SubscriptionActionResult.success({
    required SubscriptionActionType type,
    bool silent = false,
    String? productId,
    PurchaseIOS? purchase,
    int restoredCount = 0,
    String? message,
  }) {
    return SubscriptionActionResult(
      type: type,
      success: true,
      silent: silent,
      productId: productId,
      purchase: purchase,
      restoredCount: restoredCount,
      message: message,
    );
  }

  factory SubscriptionActionResult.failure({
    required SubscriptionActionType type,
    bool silent = false,
    String? productId,
    String? code,
    String? message,
    bool cancelled = false,
    PurchaseIOS? purchase,
    int restoredCount = 0,
  }) {
    return SubscriptionActionResult(
      type: type,
      success: false,
      silent: silent,
      cancelled: cancelled,
      productId: productId,
      code: code,
      message: message,
      purchase: purchase,
      restoredCount: restoredCount,
    );
  }
}
