import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'subscription_access_state.dart';

/// 仅负责权益快照的持久化和有效期检查，不查询商店或决定商店状态。
class SubscriptionEntitlementCache {
  const SubscriptionEntitlementCache({
    required this.preferences,
    required this.storageKey,
  });

  final SharedPreferences preferences;
  final String storageKey;
  static const ttl = Duration(hours: 6);

  /// 损坏、过期或来自未来的快照均不采用。
  SubscriptionAccessState? read({DateTime? now}) {
    try {
      final raw = preferences.getString(storageKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final state = SubscriptionAccessState.fromJson(decoded);
      final age =
          (now ?? DateTime.now()).millisecondsSinceEpoch - state.evaluatedAtMs;
      return state.evaluatedAtMs > 0 && age >= 0 && age <= ttl.inMilliseconds
          ? state
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(SubscriptionAccessState state) async {
    await preferences.setString(storageKey, jsonEncode(state.toJson()));
  }
}
