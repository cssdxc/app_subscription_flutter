import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

import 'app_store_trial.dart';
import 'subscription_access_state.dart';
import 'subscription_plan.dart';

/// 插件 SubscriptionStatusIOS.state 当前仍是 String；只在商店边界解析一次。
/// https://developer.apple.com/documentation/storekit/product/subscriptioninfo/renewalstate
enum StoreKitSubscriptionState {
  subscribed,
  inGracePeriod,
  inBillingRetryPeriod,
  expired,
  revoked,
  unknown;

  static StoreKitSubscriptionState fromNative(String value) => values
      .firstWhere((state) => state.name == value.trim(), orElse: () => unknown);
}

/// 提供 App Store 订阅状态映射、权益选择和试用资格判断。
class IosSubscriptionHelper {
  const IosSubscriptionHelper._();

  /// 从多个权益状态中选择最应授予用户的状态。
  static SubscriptionAccessState selectMostRelevantAccessState(
    Iterable<SubscriptionAccessState> states,
  ) {
    final List<SubscriptionAccessState> resolvedStates = states.toList(
      growable: false,
    );
    if (resolvedStates.isEmpty) {
      return SubscriptionAccessState(
        status: SubscriptionAccessStatus.unavailable,
        evaluatedAtMs: DateTime.now().millisecondsSinceEpoch,
        note: 'no subscription access states',
      );
    }

    SubscriptionAccessState bestState = resolvedStates.first;
    for (final SubscriptionAccessState candidate in resolvedStates.skip(1)) {
      bestState = _preferAccessState(bestState, candidate);
    }
    return bestState;
  }

  /// 将 Apple StoreKit 2 返回的订阅状态映射为统一权益状态。
  ///
  /// `subscribed` 和 `inGracePeriod` 只有同时存在已验证的当前权益时才放行。
  /// StoreKit 日期字段只用于展示和审计，不参与状态判定。
  static SubscriptionAccessState resolveAccessStateFromSubscriptionStatus({
    required SubscriptionStatusIOS status,
    required ActiveSubscription? verifiedEntitlement,
    required String fallbackProductId,
    DateTime? now,
  }) {
    final int nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final normalizedState = StoreKitSubscriptionState.fromNative(status.state);
    final String productId = verifiedEntitlement?.productId.isNotEmpty == true
        ? verifiedEntitlement!.productId
        : fallbackProductId;
    final String transactionId = verifiedEntitlement?.transactionId ?? '';

    switch (normalizedState) {
      case StoreKitSubscriptionState.subscribed:
        if (verifiedEntitlement == null) {
          return SubscriptionAccessState(
            status: SubscriptionAccessStatus.unavailable,
            evaluatedAtMs: nowMs,
            productId: productId,
            note: 'subscribed status has no verified current entitlement',
          );
        }
        return SubscriptionAccessState(
          status: SubscriptionAccessStatus.active,
          evaluatedAtMs: nowMs,
          effectiveUntilMs: verifiedEntitlement.expirationDateIOS?.toInt(),
          productId: productId,
          transactionId: transactionId,
          note: 'StoreKit subscription state: subscribed',
        );
      case StoreKitSubscriptionState.inGracePeriod:
        if (verifiedEntitlement == null) {
          return SubscriptionAccessState(
            status: SubscriptionAccessStatus.unavailable,
            evaluatedAtMs: nowMs,
            productId: productId,
            note: 'grace period status has no verified current entitlement',
          );
        }
        return SubscriptionAccessState(
          status: SubscriptionAccessStatus.gracePeriod,
          evaluatedAtMs: nowMs,
          effectiveUntilMs:
              status.renewalInfo?.gracePeriodExpirationDate?.toInt() ??
              verifiedEntitlement.renewalInfoIOS?.gracePeriodExpirationDate
                  ?.toInt(),
          productId: productId,
          transactionId: transactionId,
          note: 'StoreKit subscription state: inGracePeriod',
        );
      case StoreKitSubscriptionState.inBillingRetryPeriod:
        return SubscriptionAccessState(
          status: SubscriptionAccessStatus.billingRetry,
          evaluatedAtMs: nowMs,
          productId: productId,
          transactionId: transactionId,
          note: 'StoreKit subscription state: inBillingRetryPeriod',
        );
      case StoreKitSubscriptionState.expired:
        return SubscriptionAccessState(
          status: SubscriptionAccessStatus.expired,
          evaluatedAtMs: nowMs,
          productId: productId,
          transactionId: transactionId,
          note: 'StoreKit subscription state: expired',
        );
      case StoreKitSubscriptionState.revoked:
        return SubscriptionAccessState(
          status: SubscriptionAccessStatus.revoked,
          evaluatedAtMs: nowMs,
          productId: productId,
          transactionId: transactionId,
          note: 'StoreKit subscription state: revoked',
        );
      case StoreKitSubscriptionState.unknown:
        final SubscriptionAccessState? entitlementState =
            _resolveAccessStateFromEntitlement(
              entitlement: verifiedEntitlement,
              fallbackProductId: productId,
              now: now,
            );
        if (entitlementState != null) {
          return entitlementState.copyWith(
            note:
                'StoreKit state unavailable; used verified entitlement fields',
          );
        }
        return SubscriptionAccessState(
          status: SubscriptionAccessStatus.unavailable,
          evaluatedAtMs: nowMs,
          productId: productId,
          transactionId: transactionId,
          note: 'unknown StoreKit subscription state: ${status.state}',
        );
    }
  }

  /// 归并同一订阅组内 StoreKit 返回的全部状态。
  static SubscriptionAccessState resolveAccessStateFromSubscriptionStatuses(
    List<SubscriptionStatusIOS> statuses, {
    required List<ActiveSubscription> verifiedEntitlements,
    required String fallbackProductId,
    DateTime? now,
  }) {
    final int nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    if (statuses.isEmpty) {
      return SubscriptionAccessState(
        status: SubscriptionAccessStatus.expired,
        evaluatedAtMs: nowMs,
        productId: fallbackProductId,
        note: 'StoreKit returned no subscription status',
      );
    }

    final ActiveSubscription? verifiedEntitlement = _mostRecentEntitlement(
      verifiedEntitlements,
    );

    return selectMostRelevantAccessState(
      statuses.map(
        (status) => resolveAccessStateFromSubscriptionStatus(
          status: status,
          verifiedEntitlement: verifiedEntitlement,
          fallbackProductId: fallbackProductId,
          now: now,
        ),
      ),
    );
  }

  /// 逐订阅组查询资格。同组只查一次；没有组信息或查询失败均为 unknown。
  /// 不能用“没有当前购买”推断“从未享受试用”。
  static Future<Map<String, SubscriptionTrialEligibility>>
  queryTrialEligibility({
    required FlutterInappPurchase iap,
    required List<ProductSubscriptionIOS> products,
  }) async {
    final groups = <String, SubscriptionTrialEligibility>{};
    final result = <String, SubscriptionTrialEligibility>{};
    for (final product in products) {
      if (!product.hasIntroductoryFreeTrial) {
        result[product.id] = SubscriptionTrialEligibility.ineligible;
        continue;
      }
      final group = product.subscriptionGroupIdIOS?.trim() ?? '';
      if (group.isEmpty) {
        result[product.id] = SubscriptionTrialEligibility.unknown;
        continue;
      }
      if (!groups.containsKey(group)) {
        try {
          groups[group] = await iap.isEligibleForIntroOfferIOS(group)
              ? SubscriptionTrialEligibility.eligible
              : SubscriptionTrialEligibility.ineligible;
        } catch (_) {
          groups[group] = SubscriptionTrialEligibility.unknown;
        }
      }
      result[product.id] = groups[group]!;
    }
    return Map.unmodifiable(result);
  }

  static SubscriptionAccessState _preferAccessState(
    SubscriptionAccessState first,
    SubscriptionAccessState second,
  ) {
    if (first.shouldGrantAccess != second.shouldGrantAccess) {
      return first.shouldGrantAccess ? first : second;
    }

    final int firstPriority = _accessStatePriority(first.status);
    final int secondPriority = _accessStatePriority(second.status);
    if (firstPriority != secondPriority) {
      return firstPriority < secondPriority ? first : second;
    }

    final int firstUntil = first.effectiveUntilMs ?? -1;
    final int secondUntil = second.effectiveUntilMs ?? -1;
    if (firstUntil != secondUntil) {
      return firstUntil > secondUntil ? first : second;
    }

    return first.evaluatedAtMs >= second.evaluatedAtMs ? first : second;
  }

  static int _accessStatePriority(SubscriptionAccessStatus status) {
    switch (status) {
      case SubscriptionAccessStatus.active:
        return 0;
      case SubscriptionAccessStatus.gracePeriod:
        return 1;
      case SubscriptionAccessStatus.unavailable:
        return 2;
      case SubscriptionAccessStatus.revoked:
        return 3;
      case SubscriptionAccessStatus.billingRetry:
        return 4;
      case SubscriptionAccessStatus.suspended:
        return 5;
      case SubscriptionAccessStatus.expired:
        return 6;
    }
  }

  static ActiveSubscription? _mostRecentEntitlement(
    List<ActiveSubscription> entitlements,
  ) {
    if (entitlements.isEmpty) {
      return null;
    }

    ActiveSubscription mostRecent = entitlements.first;
    for (final ActiveSubscription entitlement in entitlements.skip(1)) {
      if (entitlement.transactionDate > mostRecent.transactionDate) {
        mostRecent = entitlement;
      }
    }
    return mostRecent;
  }

  static SubscriptionAccessState? _resolveAccessStateFromEntitlement({
    required ActiveSubscription? entitlement,
    required String fallbackProductId,
    DateTime? now,
  }) {
    if (entitlement == null || !entitlement.isActive) {
      return null;
    }

    // isActive 是 StoreKit 验证的结果；日期只用于展示。
    return SubscriptionAccessState(
      status: SubscriptionAccessStatus.active,
      evaluatedAtMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
      effectiveUntilMs: entitlement.expirationDateIOS?.toInt(),
      productId: entitlement.productId.isNotEmpty
          ? entitlement.productId
          : fallbackProductId,
      transactionId: entitlement.transactionId,
      note: 'verified entitlement is active',
    );
  }
}
