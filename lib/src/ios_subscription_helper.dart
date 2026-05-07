import 'package:flutter/services.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

import 'subscription_access_state.dart';

class SubscriptionVerificationResult {
  const SubscriptionVerificationResult({
    required this.accessState,
    this.resolvedItem,
  });

  final SubscriptionAccessState accessState;
  final PurchaseIOS? resolvedItem;

  bool get isActive => accessState.shouldGrantAccess;
}

class IOSLocalValidationResult {
  const IOSLocalValidationResult({
    required this.isValid,
    this.latestTransaction,
  });

  final bool isValid;
  final PurchaseIOS? latestTransaction;
}

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
    if (fallbackId.isNotEmpty && fallbackId != '0') {
      return fallbackId;
    }

    return '';
  }

  static bool shouldProcessPurchaseUpdate(PurchaseIOS item) {
    final String productId = normalizedProductId(item);
    return item.purchaseState == PurchaseState.Purchased &&
        productId.isNotEmpty;
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
    // Apple currentEntitlements grants auto-renewable subscriptions only when
    // the renewal state is subscribed or inGracePeriod.
    // https://developer.apple.com/documentation/storekit/transaction/currententitlements
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

    final List<SubscriptionAccessState> resolvedStates = subscriptions
        .map(
          (subscription) => resolveAccessStateFromActiveSubscription(
            subscription: subscription,
            now: now,
          ),
        )
        .toList(growable: false);
    return selectMostRelevantAccessState(resolvedStates);
  }

  static Future<IOSLocalValidationResult?> validateReceiptLocally({
    required MethodChannel channel,
    required String productId,
    PurchaseIOS? fallbackItem,
    void Function(String message)? logger,
  }) async {
    try {
      final Map<dynamic, dynamic>? rawResult = await channel
          .invokeMethod<Map<dynamic, dynamic>>('validateReceiptIOS', {
        'apple': {'sku': productId},
      });
      if (rawResult == null) {
        return null;
      }

      final Map<String, dynamic> result = rawResult.map(
        (key, value) => MapEntry(key.toString(), value),
      );

      PurchaseIOS? latestTransaction;
      final dynamic latestTransactionRaw = result['latestTransaction'];
      if (latestTransactionRaw is Map) {
        latestTransaction = parseLatestTransaction(
          latestTransactionRaw,
          productId: productId,
          fallbackItem: fallbackItem,
          logger: logger,
        );
      }

      return IOSLocalValidationResult(
        isValid: result['isValid'] == true,
        latestTransaction: latestTransaction,
      );
    } on PlatformException catch (e) {
      logger?.call(
        'Local iOS receipt validation failed for $productId: '
        'code=${e.code}, message=${e.message}, details=${e.details}',
      );
      return null;
    } catch (e) {
      logger?.call('Local iOS receipt validation failed for $productId: $e');
      return null;
    }
  }

  static PurchaseIOS? parseLatestTransaction(
    Map<dynamic, dynamic> rawTransaction, {
    required String productId,
    PurchaseIOS? fallbackItem,
    void Function(String message)? logger,
  }) {
    try {
      final Map<String, dynamic> tx = rawTransaction.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      tx['__typename'] ??= 'PurchaseIOS';
      tx['productId'] ??= productId;
      tx['platform'] ??= fallbackItem?.platform.toJson() ?? 'ios';
      tx['purchaseState'] ??= fallbackItem?.purchaseState.toJson() ??
          PurchaseState.Purchased.toJson();
      tx['isAutoRenewing'] ??= fallbackItem?.isAutoRenewing ?? false;
      tx['quantity'] ??= fallbackItem?.quantity ?? 1;
      tx['transactionDate'] ??= fallbackItem?.transactionDate ??
          DateTime.now().millisecondsSinceEpoch;

      final String transactionId =
          tx['transactionId']?.toString() ?? tx['id']?.toString() ?? '';
      if (transactionId.isNotEmpty) {
        tx['transactionId'] = transactionId;
        tx['id'] ??= transactionId;
      }

      tx['originalTransactionIdentifierIOS'] ??=
          fallbackItem?.originalTransactionIdentifierIOS;
      tx['originalTransactionDateIOS'] ??=
          fallbackItem?.originalTransactionDateIOS;
      tx['expirationDateIOS'] ??= fallbackItem?.expirationDateIOS;
      tx['revocationDateIOS'] ??= fallbackItem?.revocationDateIOS;
      tx['subscriptionGroupIdIOS'] ??= fallbackItem?.subscriptionGroupIdIOS;
      tx['renewalInfoIOS'] ??= fallbackItem?.renewalInfoIOS?.toJson();
      tx['environmentIOS'] ??= fallbackItem?.environmentIOS;
      tx['purchaseToken'] ??= fallbackItem?.purchaseToken;

      return PurchaseIOS.fromJson(tx);
    } catch (e) {
      logger?.call(
        'Parse latest iOS transaction failed: $e | raw=$rawTransaction',
      );
      return fallbackItem;
    }
  }

  static Future<void> finishTransactionSafe({
    required MethodChannel channel,
    required Purchase item,
    required Future<void> Function(Purchase item) fallbackFinish,
    void Function(String message)? logger,
  }) async {
    try {
      if (item is PurchaseIOS) {
        final String transactionId = item.transactionIdFor ?? '';
        if (transactionId.isEmpty || transactionId == '0') {
          logger?.call(
            '跳过完成交易：无效的 iOS transactionId, id=${item.id}, tx=$transactionId',
          );
          return;
        }
        await channel.invokeMethod('finishTransaction', <String, dynamic>{
          'transactionId': transactionId,
          'purchase': item.toJson(),
          'isConsumable': false,
        });
        return;
      }

      await fallbackFinish(item);
    } catch (e) {
      logger?.call('完成交易失败: $e');
    }
  }

  static Future<bool> computeTrialEligibility({
    required FlutterInappPurchase iap,
    required List<ProductSubscriptionIOS> products,
    required List<String> subscriptionProductIds,
    void Function(String message)? logger,
  }) async {
    final bool productHasFreeTrial = products.any(
      (product) =>
          product.subscriptionInfoIOS?.introductoryOffer?.paymentMode ==
          PaymentModeIOS.FreeTrial,
    );

    String? groupId;
    for (final product in products) {
      if (product.subscriptionInfoIOS?.introductoryOffer?.paymentMode ==
          PaymentModeIOS.FreeTrial) {
        final String? candidateGroupId =
            product.subscriptionInfoIOS?.subscriptionGroupId;
        if ((candidateGroupId ?? '').isNotEmpty) {
          groupId = candidateGroupId;
          break;
        }
      }
    }

    if ((groupId ?? '').isNotEmpty) {
      final bool eligible = await iap.isEligibleForIntroOfferIOS(groupId!);
      logger?.call(
        '免费试用资格(StoreKit2): ${productHasFreeTrial && eligible} | 产品含试用: $productHasFreeTrial | groupId: $groupId | eligible: $eligible',
      );
      return productHasFreeTrial && eligible;
    }

    final List<Purchase> items = await iap.getAvailablePurchases();
    final bool userHasSubscriptionHistory = items.any((item) {
      if (item is! PurchaseIOS) {
        return false;
      }
      final String productId = normalizedProductId(item);
      return productId.isNotEmpty && subscriptionProductIds.contains(productId);
    });
    final bool eligible = productHasFreeTrial && !userHasSubscriptionHistory;
    logger?.call(
      '免费试用资格(回退): $eligible | 产品含试用: $productHasFreeTrial | 有订阅历史: $userHasSubscriptionHistory',
    );
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
