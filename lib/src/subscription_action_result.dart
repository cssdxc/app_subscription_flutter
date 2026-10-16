import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

import 'subscription_failure.dart';

/// 一次操作的互斥结果，调用方使用 switch 处理。
enum SubscriptionActionOutcome { success, cancelled, pending, failure }

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
  const SubscriptionActionResult({
    required this.type,
    required this.outcome,
    this.silent = false,
    this.productId,
    this.failureCode,
    this.storeErrorCode,
    this.message,
    this.purchase,
    this.restoredCount = 0,
  });

  final SubscriptionActionType type;
  final SubscriptionActionOutcome outcome;
  final bool silent;
  final String? productId;

  /// 库自身的失败原因，与商店错误分开。
  final SubscriptionFailureCode? failureCode;

  /// 插件提供的商店错误，保持官方枚举语义。
  final ErrorCode? storeErrorCode;
  final String? message;
  final Purchase? purchase;
  final int restoredCount;

  /// 只用于日志或上报，不用于业务分支判断。
  String? get code => failureCode?.code ?? storeErrorCode?.value;
  bool get success => outcome == SubscriptionActionOutcome.success;
  bool get cancelled => outcome == SubscriptionActionOutcome.cancelled;
  bool get pending => outcome == SubscriptionActionOutcome.pending;
  bool get failed => outcome == SubscriptionActionOutcome.failure;

  factory SubscriptionActionResult.success({
    required SubscriptionActionType type,
    bool silent = false,
    String? productId,
    Purchase? purchase,
    int restoredCount = 0,
    String? message,
  }) => SubscriptionActionResult(
    type: type,
    outcome: SubscriptionActionOutcome.success,
    silent: silent,
    productId: productId,
    purchase: purchase,
    restoredCount: restoredCount,
    message: message,
  );

  factory SubscriptionActionResult.failure({
    required SubscriptionActionType type,
    bool silent = false,
    String? productId,
    SubscriptionFailureCode? failureCode,
    ErrorCode? storeErrorCode,
    String? message,
    Purchase? purchase,
    int restoredCount = 0,
  }) => SubscriptionActionResult(
    type: type,
    outcome: storeErrorCode == ErrorCode.UserCancelled
        ? SubscriptionActionOutcome.cancelled
        : failureCode == SubscriptionFailureCode.purchasePending ||
              storeErrorCode == ErrorCode.DeferredPayment ||
              storeErrorCode == ErrorCode.Pending
        ? SubscriptionActionOutcome.pending
        : SubscriptionActionOutcome.failure,
    silent: silent,
    productId: productId,
    failureCode: failureCode,
    storeErrorCode: storeErrorCode,
    message: message,
    purchase: purchase,
    restoredCount: restoredCount,
  );
}

/// 订阅操作事件所处的阶段。
enum SubscriptionActionPhase {
  /// 操作已经开始。
  started,

  /// 操作已经结束。
  finished,
}

/// 提供给宿主应用埋点或加载态管理的订阅操作事件。
class SubscriptionActionEvent {
  /// 创建一个订阅操作生命周期事件。
  const SubscriptionActionEvent({
    required this.phase,
    required this.type,
    required this.source,
    this.silent = false,
    this.productId,
    this.result,
  });

  /// 当前事件阶段。
  final SubscriptionActionPhase phase;

  /// 当前操作类型。
  final SubscriptionActionType type;

  /// 调用方传入的操作来源标识。
  final String source;

  /// 是否为静默操作。
  final bool silent;

  /// 操作关联的商品标识。
  final String? productId;

  /// 结束事件对应的操作结果；开始事件为空。
  final SubscriptionActionResult? result;
}
