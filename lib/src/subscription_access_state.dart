/// 统一描述各应用商店返回的订阅权益状态。
enum SubscriptionAccessStatus {
  /// 订阅有效，可以授予权益。
  active,

  /// 订阅处于账单宽限期，仍可授予权益。
  gracePeriod,

  /// 商店正在重试扣款，当前不授予权益。
  billingRetry,

  /// Google Play 返回的暂停状态，不能据此区分账号保留或用户主动暂停。
  suspended,

  /// 订阅交易已被商店撤销。
  revoked,

  /// 订阅已到期或商店未返回有效权益。
  expired,

  /// 因商店或验证不可用而无法确定权益。
  unavailable,
}

/// 与日志说明分开的可判定状态原因。
enum SubscriptionAccessReason {
  noCurrentSubscription,
  storeQueryFailed,
  localVerificationFailed,
}

/// 订阅模块对外提供的统一权益快照。
class SubscriptionAccessState {
  /// 创建一份不可变的订阅权益快照。
  const SubscriptionAccessState({
    required this.status,
    required this.evaluatedAtMs,
    this.effectiveUntilMs,
    this.productId = '',
    this.transactionId = '',
    this.note,
    this.reason,
  });

  /// 当前权益状态。
  final SubscriptionAccessStatus status;

  /// 本次状态评估时间，使用 Unix 毫秒时间戳。
  final int evaluatedAtMs;

  /// 当前权益预计结束时间，缺失时表示商店未提供。
  final int? effectiveUntilMs;

  /// 产生当前权益的商品标识。
  final String productId;

  /// 产生当前权益的交易标识。
  final String transactionId;

  /// 供日志和诊断使用的状态说明。
  final String? note;
  final SubscriptionAccessReason? reason;

  /// 是否应向用户授予订阅权益。
  bool get shouldGrantAccess =>
      status == SubscriptionAccessStatus.active ||
      status == SubscriptionAccessStatus.gracePeriod;

  /// 将权益快照编码为可持久化的 JSON 对象。
  Map<String, dynamic> toJson() {
    return {
      'status': status.name,
      'evaluatedAtMs': evaluatedAtMs,
      'effectiveUntilMs': effectiveUntilMs,
      'productId': productId,
      'transactionId': transactionId,
      'note': note,
      'reason': reason?.name,
    };
  }

  /// 从持久化 JSON 对象恢复权益快照。
  factory SubscriptionAccessState.fromJson(Map<dynamic, dynamic> json) {
    final String statusValue = json['status']?.toString() ?? '';
    return SubscriptionAccessState(
      status: SubscriptionAccessStatus.values.firstWhere(
        (value) => value.name == statusValue,
        orElse: () => SubscriptionAccessStatus.unavailable,
      ),
      evaluatedAtMs: (json['evaluatedAtMs'] as num?)?.toInt() ?? 0,
      effectiveUntilMs: (json['effectiveUntilMs'] as num?)?.toInt(),
      productId: json['productId']?.toString() ?? '',
      transactionId: json['transactionId']?.toString() ?? '',
      note: json['note']?.toString(),
      reason: SubscriptionAccessReason.values
          .where((value) => value.name == json['reason'])
          .firstOrNull,
    );
  }

  /// 复制当前快照并替换指定字段。
  SubscriptionAccessState copyWith({
    SubscriptionAccessStatus? status,
    int? evaluatedAtMs,
    int? effectiveUntilMs,
    String? productId,
    String? transactionId,
    String? note,
    SubscriptionAccessReason? reason,
  }) {
    return SubscriptionAccessState(
      status: status ?? this.status,
      evaluatedAtMs: evaluatedAtMs ?? this.evaluatedAtMs,
      effectiveUntilMs: effectiveUntilMs ?? this.effectiveUntilMs,
      productId: productId ?? this.productId,
      transactionId: transactionId ?? this.transactionId,
      note: note ?? this.note,
      reason: reason ?? this.reason,
    );
  }
}
