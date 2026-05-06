enum SubscriptionAccessStatus {
  active,
  gracePeriod,
  billingRetry,
  revoked,
  expired,
  unavailable,
}

class SubscriptionAccessState {
  const SubscriptionAccessState({
    required this.status,
    required this.evaluatedAtMs,
    this.effectiveUntilMs,
    this.productId = '',
    this.transactionId = '',
    this.note,
  });

  final SubscriptionAccessStatus status;
  final int evaluatedAtMs;
  final int? effectiveUntilMs;
  final String productId;
  final String transactionId;
  final String? note;

  bool get shouldGrantAccess =>
      status == SubscriptionAccessStatus.active ||
      status == SubscriptionAccessStatus.gracePeriod;

  Map<String, dynamic> toJson() {
    return {
      'status': status.name,
      'evaluatedAtMs': evaluatedAtMs,
      'effectiveUntilMs': effectiveUntilMs,
      'productId': productId,
      'transactionId': transactionId,
      'note': note,
    };
  }

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
    );
  }

  SubscriptionAccessState copyWith({
    SubscriptionAccessStatus? status,
    int? evaluatedAtMs,
    int? effectiveUntilMs,
    String? productId,
    String? transactionId,
    String? note,
  }) {
    return SubscriptionAccessState(
      status: status ?? this.status,
      evaluatedAtMs: evaluatedAtMs ?? this.evaluatedAtMs,
      effectiveUntilMs: effectiveUntilMs ?? this.effectiveUntilMs,
      productId: productId ?? this.productId,
      transactionId: transactionId ?? this.transactionId,
      note: note ?? this.note,
    );
  }
}
