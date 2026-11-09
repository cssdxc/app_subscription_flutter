import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

import 'subscription_access_state.dart';
import 'subscription_snapshot.dart';
import 'subscription_failure.dart';
import 'subscription_plan.dart';
import 'subscription_store_adapter.dart';
import 'subscription_transaction.dart';
import 'android_subscription_helper.dart';

/// 负责 Google Play Billing 的购买、签名验证和权益映射。
///
/// 规则依据：
/// https://developer.android.com/google/play/billing/integrate
/// https://developer.android.com/google/play/billing/security
/// https://developer.android.com/google/play/billing/lifecycle/subscriptions
/// https://developer.android.com/google/play/billing/release-notes
/// https://developer.android.com/reference/com/android/billingclient/api/Purchase#getSignature()
class GooglePlaySubscriptionAdapter implements SubscriptionStoreAdapter {
  /// 使用 Play Console 公钥创建 Google Play 订阅适配器。
  const GooglePlaySubscriptionAdapter({this.licenseKey = ''});

  /// Play Console 提供的 Base64 编码 RSA 公钥。
  final String licenseKey;

  @override
  Future<Map<String, SubscriptionTrialEligibility>> queryTrialEligibility({
    required FlutterInappPurchase iap,
    required List<ProductSubscription> products,
  }) async => const {};

  @override
  bool supportsPurchase(Purchase purchase) =>
      purchase is PurchaseAndroid && purchase.storeId == StoreIds.play;

  @override
  SubscriptionFailureCode? purchaseFailure(Purchase purchase) {
    final item = purchase as PurchaseAndroid;
    if (item.isSuspendedAndroid == true)
      return SubscriptionFailureCode.subscriptionSuspended;
    if ((item.purchaseToken ?? '').isEmpty)
      return SubscriptionFailureCode.missingPurchaseToken;
    return null;
  }

  @override
  Future<void> requestPurchase({
    required FlutterInappPurchase iap,
    required ProductSubscription product,
    required SubscriptionOffer? offer,
    required SubscriptionPurchaseOptions options,
  }) {
    if (product is! ProductSubscriptionAndroid) {
      throw const SubscriptionStoreException(
        failureCode: SubscriptionFailureCode.invalidProductPlatform,
        message: 'The product is not a Google Play subscription.',
      );
    }
    final token = offer?.offerTokenAndroid;
    if (token == null ||
        token.isEmpty ||
        !product.subscriptionOffers.any(
          (item) => item.offerTokenAndroid == token,
        )) {
      throw const SubscriptionStoreException(
        failureCode: SubscriptionFailureCode.invalidOffer,
        message:
            'The selected Google Play offer does not belong to the product.',
      );
    }
    final replacement = options.replacementAndroid;
    if (replacement != null &&
        (replacement.purchaseToken.isEmpty ||
            replacement.oldProductId.isEmpty ||
            replacement.mode ==
                SubscriptionReplacementModeAndroid.UnknownReplacementMode)) {
      throw const SubscriptionStoreException(
        failureCode: SubscriptionFailureCode.invalidReplacement,
        message:
            'A replacement requires an old product, purchase token and supported mode.',
      );
    }
    return iap.requestPurchase(
      RequestPurchaseProps.subs((
        apple: null,
        google: RequestSubscriptionAndroidProps(
          skus: <String>[product.id],
          purchaseToken: replacement?.purchaseToken,
          subscriptionProductReplacementParams: replacement == null
              ? null
              : SubscriptionProductReplacementParamsAndroid(
                  oldProductId: replacement.oldProductId,
                  replacementMode: replacement.mode,
                ),
          subscriptionOffers: <AndroidSubscriptionOfferInput>[
            AndroidSubscriptionOfferInput(sku: product.id, offerToken: token),
          ],
          obfuscatedAccountId: options.obfuscatedAccountIdAndroid,
          obfuscatedProfileId: options.obfuscatedProfileIdAndroid,
          isOfferPersonalized: options.isOfferPersonalizedAndroid,
        ),
      )),
    );
  }

  @override
  Future<List<Purchase>> restorePurchases(FlutterInappPurchase iap) {
    return iap.getAvailablePurchases(includeSuspendedAndroid: true);
  }

  @override
  Future<void> finishTransaction({
    required FlutterInappPurchase iap,
    required Purchase purchase,
  }) async {
    final PurchaseAndroid item = purchase as PurchaseAndroid;
    if (item.isAcknowledgedAndroid == true) {
      return;
    }
    final String token = item.purchaseToken ?? '';
    if (token.isEmpty) {
      throw const SubscriptionStoreException(
        failureCode: SubscriptionFailureCode.missingPurchaseToken,
        message: 'Google Play purchase token is required for acknowledgement.',
      );
    }
    final bool acknowledged = await iap.acknowledgePurchaseAndroid(token);
    if (!acknowledged) {
      throw const SubscriptionStoreException(
        failureCode: SubscriptionFailureCode.acknowledgementFailed,
        message: 'Google Play did not acknowledge the subscription purchase.',
      );
    }
  }

  @override
  Future<void> verifyPurchaseLocally({
    required FlutterInappPurchase iap,
    required Purchase purchase,
  }) async {
    if (licenseKey.trim().isEmpty) {
      throw const SubscriptionStoreException(
        failureCode: SubscriptionFailureCode.missingLicenseKey,
        message: 'Google Play license key is required for local verification.',
      );
    }
    if (purchase is! PurchaseAndroid ||
        !AndroidSubscriptionHelper.verifyPurchaseSignature(
          purchase: purchase,
          licenseKey: licenseKey,
        )) {
      throw const SubscriptionStoreException(
        failureCode: SubscriptionFailureCode.localVerificationFailed,
        message: 'Google Play purchase signature verification failed.',
      );
    }
  }

  @override
  Future<SubscriptionSnapshot> resolveVerifiedAccessState({
    required FlutterInappPurchase iap,
    required List<ActiveSubscription> subscriptions,
    required List<ProductSubscription> products,
    required List<String>? productIds,
    DateTime? now,
  }) async {
    if (licenseKey.trim().isEmpty) {
      throw const SubscriptionStoreException(
        failureCode: SubscriptionFailureCode.missingLicenseKey,
        message: 'Google Play license key is required for local verification.',
      );
    }

    // 查询时包含 suspended 购买，确保账单问题不会被误判为无购买记录。
    final List<PurchaseAndroid> purchases =
        (await iap.getAvailablePurchases(includeSuspendedAndroid: true))
            .whereType<PurchaseAndroid>()
            .where(
              (purchase) => productIds == null
                  ? subscriptions.any((s) => s.productId == purchase.productId)
                  : productIds.contains(purchase.productId),
            )
            .toList(growable: false);
    final List<PurchaseAndroid> verifiedPurchases = purchases
        .where(
          (purchase) => AndroidSubscriptionHelper.verifyPurchaseSignature(
            purchase: purchase,
            licenseKey: licenseKey,
          ),
        )
        .toList(growable: false);

    // 当前插件两种令牌字段均有定义，必须同时匹配令牌和商品。
    // 两次查询间状态可能变化，购买记录已暂停或仍待付款时不能放行。
    final List<ActiveSubscription> verifiedSubscriptions = subscriptions
        .where((subscription) {
          final String token =
              subscription.purchaseTokenAndroid ??
              subscription.purchaseToken ??
              '';
          return token.isNotEmpty &&
              verifiedPurchases.any(
                (purchase) =>
                    purchase.purchaseToken == token &&
                    purchase.productId == subscription.productId &&
                    purchase.purchaseState == PurchaseState.Purchased &&
                    purchase.isSuspendedAndroid != true,
              );
        })
        .toList(growable: false);

    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final states = <SubscriptionAccessState>[
      for (final subscription in verifiedSubscriptions)
        AndroidSubscriptionHelper.resolveAccessStateFromActiveSubscription(
          subscription: subscription,
          now: now,
        ),
    ];
    for (final purchase in purchases) {
      if (states.any(
        (s) =>
            s.productId == purchase.productId &&
            s.transactionId == (purchase.transactionId ?? purchase.id),
      ))
        continue;
      final verified = verifiedPurchases.contains(purchase);
      states.add(
        SubscriptionAccessState(
          store: IapStore.Google,
          status: !verified
              ? SubscriptionAccessStatus.unavailable
              : purchase.isSuspendedAndroid == true
              ? SubscriptionAccessStatus.suspended
              : SubscriptionAccessStatus.expired,
          evaluatedAtMs: nowMs,
          productId: purchase.productId,
          transactionId: purchase.transactionId ?? purchase.id,
          reason: verified
              ? SubscriptionAccessReason.noCurrentSubscription
              : SubscriptionAccessReason.localVerificationFailed,
        ),
      );
    }
    return SubscriptionSnapshot(evaluatedAtMs: nowMs, subscriptions: states);
  }

  @override
  SubscriptionTransactionPayload transactionPayload(Purchase purchase) {
    final PurchaseAndroid item = purchase as PurchaseAndroid;
    final String purchaseToken = item.purchaseToken ?? '';
    return SubscriptionTransactionPayload(
      productId: item.productId,
      store: item.store,
      originalTransactionId: purchaseToken,
      currentTransactionId: item.transactionId ?? item.id,
      purchaseToken: purchaseToken,
      packageNameAndroid: item.packageNameAndroid,
      purchase: item,
    );
  }
}
