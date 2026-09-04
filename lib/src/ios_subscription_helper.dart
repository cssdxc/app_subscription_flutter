import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

import 'subscription_access_state.dart';

/// 提供 App Store 订阅字段归一化、权益选择和试用资格判断。
class IosSubscriptionHelper {
  const IosSubscriptionHelper._();

  /// 从 StoreKit 购买对象中解析稳定的商品标识。
  static String normalizedProductId(PurchaseIOS? item) {
    if (item == null) {
      return '';
    }

    final String productId = item.productId.trim();
    if (productId.isNotEmpty && productId != '0') {
      return productId;
    }

    final String fallbackId = item.id.trim();
    return fallbackId.isNotEmpty && fallbackId != '0' ? fallbackId : '';
  }

  /// 判断购买更新是否满足后续验证和完成交易条件。
  static bool shouldProcessPurchaseUpdate(PurchaseIOS item) {
    return item.purchaseState == PurchaseState.Purchased &&
        normalizedProductId(item).isNotEmpty;
  }

  /// Converts a locally verified purchase into a temporary entitlement while
  /// StoreKit refreshes its current-entitlements query after checkout.
  static ActiveSubscription activeSubscriptionFromPurchase(PurchaseIOS item) {
    return ActiveSubscription(
      expirationDateIOS: item.expirationDateIOS,
      isActive: true,
      productId: normalizedProductId(item),
      renewalInfoIOS: item.renewalInfoIOS,
      transactionDate: item.transactionDate,
      transactionId: item.transactionId,
    );
  }

  /// 从多个权益状态中选择最应授予用户的状态。
  static SubscriptionAccessState selectMostRelevantAccessState(
    Iterable<SubscriptionAccessState> states,
  ) {
    final List<SubscriptionAccessState> resolvedStates =
        states.toList(growable: false);
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
    final String normalizedState = status.state.trim();
    final String productId = verifiedEntitlement?.productId.isNotEmpty == true
        ? verifiedEntitlement!.productId
        : fallbackProductId;
    final String transactionId = verifiedEntitlement?.transactionId ?? '';

    switch (normalizedState) {
      case 'subscribed':
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
      case 'inGracePeriod':
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
      case 'inBillingRetryPeriod':
        return SubscriptionAccessState(
          status: SubscriptionAccessStatus.billingRetry,
          evaluatedAtMs: nowMs,
          productId: productId,
          transactionId: transactionId,
          note: 'StoreKit subscription state: inBillingRetryPeriod',
        );
      case 'expired':
        return SubscriptionAccessState(
          status: SubscriptionAccessStatus.expired,
          evaluatedAtMs: nowMs,
          productId: productId,
          transactionId: transactionId,
          note: 'StoreKit subscription state: expired',
        );
      case 'revoked':
        return SubscriptionAccessState(
          status: SubscriptionAccessStatus.revoked,
          evaluatedAtMs: nowMs,
          productId: productId,
          transactionId: transactionId,
          note: 'StoreKit subscription state: revoked',
        );
      default:
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

    final ActiveSubscription? verifiedEntitlement =
        _mostRecentEntitlement(verifiedEntitlements);

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

  /// 根据订阅组资格和购买历史判断是否可展示免费试用。
  static Future<bool> computeTrialEligibility({
    required FlutterInappPurchase iap,
    required List<ProductSubscriptionIOS> products,
    required List<String> subscriptionProductIds,
    void Function(String message)? logger,
  }) async {
    final List<ProductSubscriptionIOS> productsWithTrial = products
        .where(
          (product) =>
              product.introductoryPricePaymentModeIOS ==
                  PaymentModeIOS.FreeTrial ||
              (product.subscriptionOffers ?? const <SubscriptionOffer>[]).any(
                (offer) => offer.paymentMode == PaymentMode.FreeTrial,
              ),
        )
        .toList(growable: false);
    final bool productHasFreeTrial = productsWithTrial.isNotEmpty;

    String? groupId;
    for (final ProductSubscriptionIOS product in productsWithTrial) {
      if ((product.subscriptionGroupIdIOS ?? '').isNotEmpty) {
        groupId = product.subscriptionGroupIdIOS;
        break;
      }
    }

    if ((groupId ?? '').isNotEmpty) {
      final bool eligible = await iap.isEligibleForIntroOfferIOS(groupId!);
      logger?.call(
        'App Store free trial eligible: ${productHasFreeTrial && eligible}',
      );
      return productHasFreeTrial && eligible;
    }

    final List<Purchase> items = await iap.getAvailablePurchases();
    final bool userHasSubscriptionHistory = items.whereType<PurchaseIOS>().any(
          (item) => subscriptionProductIds.contains(normalizedProductId(item)),
        );
    final bool eligible = productHasFreeTrial && !userHasSubscriptionHistory;
    logger?.call('App Store free trial eligible from history: $eligible');
    return eligible;
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
      case SubscriptionAccessStatus.expired:
        return 5;
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

    final int nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final RenewalInfoIOS? renewalInfo = entitlement.renewalInfoIOS;
    if (renewalInfo?.isInBillingRetry == true) {
      return SubscriptionAccessState(
        status: SubscriptionAccessStatus.billingRetry,
        evaluatedAtMs: nowMs,
        productId: entitlement.productId.isNotEmpty
            ? entitlement.productId
            : fallbackProductId,
        transactionId: entitlement.transactionId,
        note: 'verified entitlement is in billing retry',
      );
    }

    final int? graceUntilMs = renewalInfo?.gracePeriodExpirationDate?.toInt();
    if (graceUntilMs != null && graceUntilMs > nowMs) {
      return SubscriptionAccessState(
        status: SubscriptionAccessStatus.gracePeriod,
        evaluatedAtMs: nowMs,
        effectiveUntilMs: graceUntilMs,
        productId: entitlement.productId.isNotEmpty
            ? entitlement.productId
            : fallbackProductId,
        transactionId: entitlement.transactionId,
        note: 'verified entitlement is in grace period',
      );
    }

    final int? expirationMs = entitlement.expirationDateIOS?.toInt();
    if (expirationMs != null && expirationMs <= nowMs) {
      return SubscriptionAccessState(
        status: SubscriptionAccessStatus.expired,
        evaluatedAtMs: nowMs,
        effectiveUntilMs: expirationMs,
        productId: entitlement.productId.isNotEmpty
            ? entitlement.productId
            : fallbackProductId,
        transactionId: entitlement.transactionId,
        note: 'verified entitlement is expired',
      );
    }

    return SubscriptionAccessState(
      status: SubscriptionAccessStatus.active,
      evaluatedAtMs: nowMs,
      effectiveUntilMs: expirationMs,
      productId: entitlement.productId.isNotEmpty
          ? entitlement.productId
          : fallbackProductId,
      transactionId: entitlement.transactionId,
      note: 'verified entitlement is active',
    );
  }
}
