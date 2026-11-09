import 'subscription_access_state.dart';

/// 订阅识别范围的查询快照。各记录保留自己的身份、状态和证据时间。
class SubscriptionSnapshot {
  SubscriptionSnapshot({
    required this.evaluatedAtMs,
    Iterable<SubscriptionAccessState> subscriptions = const [],
    Iterable<String> queryFailedProductIds = const [],
  }) : subscriptions = List.unmodifiable(subscriptions),
       queryFailedProductIds = Set.unmodifiable(queryFailedProductIds);

  final int evaluatedAtMs;
  final List<SubscriptionAccessState> subscriptions;

  /// 查询失败不等于订阅失效；对应记录可能采用离线缓存。
  final Set<String> queryFailedProductIds;

  Iterable<SubscriptionAccessState> get activeSubscriptions =>
      subscriptions.where((s) => s.shouldGrantAccess);

  /// 仅表示存在有效订阅；具体功能由宿主按商店商品身份映射。
  bool get shouldGrantAccess => activeSubscriptions.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'schemaVersion': 2,
    'evaluatedAtMs': evaluatedAtMs,
    'subscriptions': subscriptions.map((s) => s.toJson()).toList(),
    'queryFailedProductIds': queryFailedProductIds.toList(),
  };

  factory SubscriptionSnapshot.fromJson(Map<dynamic, dynamic> json) {
    // v2 之前只缓存一项商品；保留身份，不猜业务权益。
    if (!json.containsKey('schemaVersion')) {
      final state = SubscriptionAccessState.fromJson(json);
      return SubscriptionSnapshot(
        evaluatedAtMs: state.evaluatedAtMs,
        subscriptions: [state],
      );
    }
    if (json['schemaVersion'] != 2)
      throw const FormatException('Unknown subscription cache schema');
    return SubscriptionSnapshot(
      evaluatedAtMs: (json['evaluatedAtMs'] as num).toInt(),
      subscriptions: (json['subscriptions'] as List).map(
        (s) => SubscriptionAccessState.fromJson(s as Map),
      ),
      queryFailedProductIds: (json['queryFailedProductIds'] as List)
          .cast<String>(),
    );
  }
}
