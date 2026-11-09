import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'subscription_snapshot.dart';

/// 仅负责权益快照的持久化和有效期检查，不查询商店或决定商店状态。
class SubscriptionEntitlementCache {
  SubscriptionEntitlementCache({
    SharedPreferences? preferences,
    required this.storageKey,
  }) : _preferences = preferences;

  SharedPreferences? _preferences;
  final String storageKey;
  static const ttl = Duration(hours: 6);

  Future<SharedPreferences> _storage() async =>
      _preferences ??= await SharedPreferences.getInstance();

  /// 损坏、过期或来自未来的快照均不采用。
  Future<SubscriptionSnapshot?> read({DateTime? now}) async {
    try {
      final raw = (await _storage()).getString(storageKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final state = SubscriptionSnapshot.fromJson(decoded);
      final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
      final age = nowMs - state.evaluatedAtMs;
      if (state.evaluatedAtMs <= 0 || age < 0 || age >= ttl.inMilliseconds)
        return null;
      return SubscriptionSnapshot(
        evaluatedAtMs: state.evaluatedAtMs,
        queryFailedProductIds: state.queryFailedProductIds,
        subscriptions: state.subscriptions
            .where((s) {
              final recordAge = nowMs - s.evaluatedAtMs;
              return s.evaluatedAtMs > 0 &&
                  recordAge >= 0 &&
                  recordAge < ttl.inMilliseconds &&
                  (!s.shouldGrantAccess ||
                      s.effectiveUntilMs == null ||
                      s.effectiveUntilMs! > nowMs);
            })
            .map((s) => s.copyWith(fromCache: true)),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> write(SubscriptionSnapshot state) async {
    await (await _storage()).setString(storageKey, jsonEncode(state.toJson()));
  }
}
