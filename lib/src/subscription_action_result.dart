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
    this.pending = false,
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
  final bool pending;
  final String? productId;
  final String? code;
  final String? message;
  final Purchase? purchase;
  final int restoredCount;

  bool get failed => !success;

  factory SubscriptionActionResult.success({
    required SubscriptionActionType type,
    bool silent = false,
    String? productId,
    Purchase? purchase,
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
    bool pending = false,
    Purchase? purchase,
    int restoredCount = 0,
  }) {
    return SubscriptionActionResult(
      type: type,
      success: false,
      silent: silent,
      cancelled: cancelled,
      pending: pending,
      productId: productId,
      code: code,
      message: message,
      purchase: purchase,
      restoredCount: restoredCount,
    );
  }
}
