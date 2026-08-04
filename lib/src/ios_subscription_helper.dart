import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

import 'subscription_access_state.dart';

class IosSubscriptionHelper {
  const IosSubscriptionHelper._();

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

  static bool shouldProcessPurchaseUpdate(PurchaseIOS item) {
    return item.purchaseState == PurchaseState.Purchased &&
        normalizedProductId(item).isNotEmpty;
  }

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

  static SubscriptionAccessState resolveAccessStateFromActiveSubscription({
    required ActiveSubscription subscription,
    DateTime? now,
  }) {
    // StoreKit currentEntitlements includes subscriptions in subscribed or
    // inGracePeriod state.
    final int nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final RenewalInfoIOS? renewalInfo = subscription.renewalInfoIOS;
    final int? graceUntilMs = renewalInfo?.gracePeriodExpirationDate?.toInt();
    final bool hasActiveGracePeriod =
        graceUntilMs != null && graceUntilMs > nowMs;
    final SubscriptionAccessStatus status = hasActiveGracePeriod
        ? SubscriptionAccessStatus.gracePeriod
        : (subscription.isActive
            ? SubscriptionAccessStatus.active
            : SubscriptionAccessStatus.expired);

    return SubscriptionAccessState(
      status: status,
      evaluatedAtMs: nowMs,
      effectiveUntilMs: graceUntilMs ?? subscription.expirationDateIOS?.toInt(),
      productId: subscription.productId,
      transactionId: subscription.transactionId,
      note: status == SubscriptionAccessStatus.gracePeriod
          ? 'native entitlement in grace period'
          : (status == SubscriptionAccessStatus.active
              ? 'active native entitlement'
              : 'inactive native subscription'),
    );
  }

  static SubscriptionAccessState resolveAccessStateFromActiveSubscriptions(
    List<ActiveSubscription> subscriptions, {
    required String fallbackProductId,
    DateTime? now,
  }) {
    final int nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    if (subscriptions.isEmpty) {
      return SubscriptionAccessState(
        status: SubscriptionAccessStatus.expired,
        evaluatedAtMs: nowMs,
        productId: fallbackProductId,
        note: 'no active native entitlement',
      );
    }

    return selectMostRelevantAccessState(
      subscriptions.map(
        (subscription) => resolveAccessStateFromActiveSubscription(
          subscription: subscription,
          now: now,
        ),
      ),
    );
  }

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
      case SubscriptionAccessStatus.revoked:
        return 2;
      case SubscriptionAccessStatus.billingRetry:
        return 3;
      case SubscriptionAccessStatus.expired:
        return 4;
      case SubscriptionAccessStatus.unavailable:
        return 5;
    }
  }
}
