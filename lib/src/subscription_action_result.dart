import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

/// 订阅操作的业务类型。
enum SubscriptionActionType {
  /// 发起购买。
  purchase,

  /// 恢复已有购买。
  restore,

  /// 根据商店事件同步状态。
  sync,
}

/// 一次购买、恢复或同步操作的统一结果。
class SubscriptionActionResult {
  /// 创建一次订阅操作结果。
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

  /// 操作类型。
  final SubscriptionActionType type;

  /// 操作是否成功完成。
  final bool success;

  /// 是否为不应触发交互提示的静默操作。
  final bool silent;

  /// 用户是否主动取消了操作。
  final bool cancelled;

  /// 交易是否仍处于待处理状态。
  final bool pending;

  /// 本次操作关联的商品标识。
  final String? productId;

  /// 可供调用方分类处理的错误码。
  final String? code;

  /// 商店或订阅模块返回的结果说明。
  final String? message;

  /// 本次操作关联的原始购买对象。
  final Purchase? purchase;

  /// 恢复流程中发现并处理的购买数量。
  final int restoredCount;

  /// 操作是否失败。
  bool get failed => !success;

  /// 创建成功结果。
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

  /// 创建失败、取消或待处理结果。
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
