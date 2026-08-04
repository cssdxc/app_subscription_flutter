import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

import 'android_subscription_helper.dart';
import 'ios_subscription_helper.dart';
import 'subscription_access_state.dart';
import 'subscription_transaction.dart';

class SubscriptionPurchaseOptions {
  const SubscriptionPurchaseOptions({
    this.offer,
    this.appAccountTokenIOS,
    this.obfuscatedAccountIdAndroid,
    this.obfuscatedProfileIdAndroid,
    this.isOfferPersonalizedAndroid,
  });

  final SubscriptionOffer? offer;
  final String? appAccountTokenIOS;
  final String? obfuscatedAccountIdAndroid;
  final String? obfuscatedProfileIdAndroid;
  final bool? isOfferPersonalizedAndroid;
}

abstract interface class SubscriptionStoreAdapter {
  factory SubscriptionStoreAdapter.forIap(
    FlutterInappPurchase iap, {
    String googlePlayLicenseKeyAndroid = '',
  }) {
    if (iap.isAndroid) {
      if (googlePlayLicenseKeyAndroid.trim().isEmpty) {
        throw ArgumentError.value(
          googlePlayLicenseKeyAndroid,
          'googlePlayLicenseKeyAndroid',
          'A Google Play license key is required on Android.',
        );
      }
      return GooglePlaySubscriptionAdapter(
        licenseKey: googlePlayLicenseKeyAndroid,
      );
    }
    if (iap.isIOS) {
      return const AppStoreSubscriptionAdapter();
    }
    throw UnsupportedError(
        'Subscriptions are supported only on iOS and Android.');
  }

  bool supportsProduct(ProductSubscription product);
  bool supportsPurchase(Purchase purchase);
  List<SubscriptionOffer> offersFor(ProductSubscription product);
  String normalizedProductId(Purchase purchase);
  bool isPending(Purchase purchase);
  bool shouldProcessPurchaseUpdate(Purchase purchase);
  SubscriptionAccessState? blockingAccessState(Purchase purchase);

  Future<void> requestPurchase({
    required FlutterInappPurchase iap,
    required ProductSubscription product,
    required SubscriptionPurchaseOptions options,
  });

  Future<List<Purchase>> restorePurchases(FlutterInappPurchase iap);
  Future<void> finishTransaction({
    required FlutterInappPurchase iap,
    required Purchase purchase,
  });

  Future<void> verifyPurchaseLocally({
    required FlutterInappPurchase iap,
    required Purchase purchase,
  });

  Future<SubscriptionAccessState> resolveVerifiedAccessState({
    required FlutterInappPurchase iap,
    required List<ActiveSubscription> subscriptions,
    required List<String> productIds,
    required String fallbackProductId,
    DateTime? now,
  });

  Future<bool> computeTrialEligibility({
    required FlutterInappPurchase iap,
    required List<ProductSubscription> products,
    required List<String> productIds,
    void Function(String message)? logger,
  });

  SubscriptionTransactionPayload transactionPayload(Purchase purchase);
}

class AppStoreSubscriptionAdapter implements SubscriptionStoreAdapter {
  const AppStoreSubscriptionAdapter();

  @override
  bool supportsProduct(ProductSubscription product) =>
      product is ProductSubscriptionIOS;

  @override
  bool supportsPurchase(Purchase purchase) => purchase is PurchaseIOS;

  @override
  List<SubscriptionOffer> offersFor(ProductSubscription product) {
    if (product is! ProductSubscriptionIOS) {
      return const <SubscriptionOffer>[];
    }
    return product.subscriptionOffers ?? const <SubscriptionOffer>[];
  }

  @override
  String normalizedProductId(Purchase purchase) =>
      IosSubscriptionHelper.normalizedProductId(purchase as PurchaseIOS);

  @override
  bool isPending(Purchase purchase) =>
      purchase.purchaseState == PurchaseState.Pending;

  @override
  bool shouldProcessPurchaseUpdate(Purchase purchase) =>
      purchase is PurchaseIOS &&
      IosSubscriptionHelper.shouldProcessPurchaseUpdate(purchase);

  @override
  SubscriptionAccessState? blockingAccessState(Purchase purchase) => null;

  @override
  Future<void> requestPurchase({
    required FlutterInappPurchase iap,
    required ProductSubscription product,
    required SubscriptionPurchaseOptions options,
  }) {
    if (product is! ProductSubscriptionIOS) {
      throw const SubscriptionStoreException(
        code: 'invalid-product-platform',
        message: 'The product is not an App Store subscription.',
      );
    }
    if (options.offer != null) {
      throw const SubscriptionStoreException(
        code: 'unsupported-offer',
        message: 'Signed App Store promotional offers are not configured.',
      );
    }
    return iap.requestPurchase(
      RequestPurchaseProps.subs((
        apple: RequestSubscriptionIosProps(
          sku: product.id,
          appAccountToken: options.appAccountTokenIOS,
        ),
        google: null,
      )),
    );
  }

  @override
  Future<List<Purchase>> restorePurchases(FlutterInappPurchase iap) async {
    await iap.restorePurchases();
    return iap.getAvailablePurchases();
  }

  @override
  Future<void> finishTransaction({
    required FlutterInappPurchase iap,
    required Purchase purchase,
  }) {
    return iap.finishTransaction(purchase: purchase, isConsumable: false);
  }

  @override
  Future<void> verifyPurchaseLocally({
    required FlutterInappPurchase iap,
    required Purchase purchase,
  }) async {
    final PurchaseIOS item = purchase as PurchaseIOS;
    final String productId = normalizedProductId(item);
    if (productId.isEmpty || !await iap.isTransactionVerifiedIOS(productId)) {
      throw const SubscriptionStoreException(
        code: 'local-verification-failed',
        message: 'StoreKit could not verify the subscription transaction.',
      );
    }
  }

  @override
  Future<SubscriptionAccessState> resolveVerifiedAccessState({
    required FlutterInappPurchase iap,
    required List<ActiveSubscription> subscriptions,
    required List<String> productIds,
    required String fallbackProductId,
    DateTime? now,
  }) {
    // StoreKit currentEntitlements contains only locally verified transactions.
    return Future<SubscriptionAccessState>.value(
      IosSubscriptionHelper.resolveAccessStateFromActiveSubscriptions(
        subscriptions,
        fallbackProductId: fallbackProductId,
        now: now,
      ),
    );
  }

  @override
  Future<bool> computeTrialEligibility({
    required FlutterInappPurchase iap,
    required List<ProductSubscription> products,
    required List<String> productIds,
    void Function(String message)? logger,
  }) {
    return IosSubscriptionHelper.computeTrialEligibility(
      iap: iap,
      products: products.whereType<ProductSubscriptionIOS>().toList(),
      subscriptionProductIds: productIds,
      logger: logger,
    );
  }

  @override
  SubscriptionTransactionPayload transactionPayload(Purchase purchase) {
    final PurchaseIOS item = purchase as PurchaseIOS;
    return SubscriptionTransactionPayload(
      productId: normalizedProductId(item),
      store: item.store,
      originalTransactionId: item.originalTransactionIdentifierIOS ?? '',
      currentTransactionId: item.transactionId,
      purchaseToken: item.purchaseToken,
      purchase: item,
    );
  }
}

/// Google Play Billing contract owner.
///
/// Sources:
/// https://developer.android.com/google/play/billing/integrate
/// https://developer.android.com/google/play/billing/security
/// https://developer.android.com/google/play/billing/lifecycle/subscriptions
/// https://developer.android.com/google/play/billing/release-notes
/// https://developer.android.com/reference/com/android/billingclient/api/Purchase#getSignature()
class GooglePlaySubscriptionAdapter implements SubscriptionStoreAdapter {
  const GooglePlaySubscriptionAdapter({this.licenseKey = ''});

  final String licenseKey;

  @override
  bool supportsProduct(ProductSubscription product) =>
      product is ProductSubscriptionAndroid;

  @override
  bool supportsPurchase(Purchase purchase) => purchase is PurchaseAndroid;

  @override
  List<SubscriptionOffer> offersFor(ProductSubscription product) {
    if (product is! ProductSubscriptionAndroid) {
      return const <SubscriptionOffer>[];
    }
    return AndroidSubscriptionHelper.purchasableOffers(product);
  }

  @override
  String normalizedProductId(Purchase purchase) =>
      AndroidSubscriptionHelper.normalizedProductId(
        purchase as PurchaseAndroid,
      );

  @override
  bool isPending(Purchase purchase) =>
      purchase is PurchaseAndroid &&
      AndroidSubscriptionHelper.isPending(purchase);

  @override
  bool shouldProcessPurchaseUpdate(Purchase purchase) =>
      purchase is PurchaseAndroid &&
      AndroidSubscriptionHelper.shouldProcessPurchaseUpdate(purchase);

  @override
  SubscriptionAccessState? blockingAccessState(Purchase purchase) {
    if (purchase is! PurchaseAndroid || purchase.isSuspendedAndroid != true) {
      return null;
    }
    return SubscriptionAccessState(
      status: SubscriptionAccessStatus.billingRetry,
      evaluatedAtMs: DateTime.now().millisecondsSinceEpoch,
      productId: normalizedProductId(purchase),
      transactionId: purchase.transactionId ?? purchase.id,
      note: 'Google Play subscription is suspended',
    );
  }

  @override
  Future<void> requestPurchase({
    required FlutterInappPurchase iap,
    required ProductSubscription product,
    required SubscriptionPurchaseOptions options,
  }) {
    if (product is! ProductSubscriptionAndroid) {
      throw const SubscriptionStoreException(
        code: 'invalid-product-platform',
        message: 'The product is not a Google Play subscription.',
      );
    }
    late final SubscriptionOffer offer;
    try {
      offer = AndroidSubscriptionHelper.resolvePurchaseOffer(
        product,
        requestedOffer: options.offer,
      );
    } on AndroidSubscriptionOfferException catch (error) {
      throw SubscriptionStoreException(
        code: error.code,
        message: error.message,
      );
    }
    return iap.requestPurchase(
      RequestPurchaseProps.subs((
        apple: null,
        google: RequestSubscriptionAndroidProps(
          skus: <String>[product.id],
          subscriptionOffers: <AndroidSubscriptionOfferInput>[
            AndroidSubscriptionOfferInput(
              sku: product.id,
              offerToken: offer.offerTokenAndroid!,
            ),
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
        code: 'missing-purchase-token',
        message: 'Google Play purchase token is required for acknowledgement.',
      );
    }
    final bool acknowledged = await iap.acknowledgePurchaseAndroid(token);
    if (!acknowledged) {
      throw const SubscriptionStoreException(
        code: 'acknowledgement-failed',
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
        code: 'missing-license-key',
        message: 'Google Play license key is required for local verification.',
      );
    }
    if (purchase is! PurchaseAndroid ||
        !AndroidSubscriptionHelper.verifyPurchaseSignature(
          purchase: purchase,
          licenseKey: licenseKey,
        )) {
      throw const SubscriptionStoreException(
        code: 'local-verification-failed',
        message: 'Google Play purchase signature verification failed.',
      );
    }
  }

  @override
  Future<SubscriptionAccessState> resolveVerifiedAccessState({
    required FlutterInappPurchase iap,
    required List<ActiveSubscription> subscriptions,
    required List<String> productIds,
    required String fallbackProductId,
    DateTime? now,
  }) async {
    if (licenseKey.trim().isEmpty) {
      throw const SubscriptionStoreException(
        code: 'missing-license-key',
        message: 'Google Play license key is required for local verification.',
      );
    }

    final List<PurchaseAndroid> purchases = (await iap.getAvailablePurchases(
      includeSuspendedAndroid: true,
    ))
        .whereType<PurchaseAndroid>()
        .where(
          (purchase) => productIds.contains(normalizedProductId(purchase)),
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

    final Set<String> verifiedTokens = verifiedPurchases
        .map((purchase) => purchase.purchaseToken ?? '')
        .where((token) => token.isNotEmpty)
        .toSet();
    final Set<String> verifiedProductIds = verifiedPurchases
        .map(normalizedProductId)
        .where((productId) => productId.isNotEmpty)
        .toSet();
    final List<ActiveSubscription> verifiedSubscriptions = subscriptions.where(
      (subscription) {
        final String token = subscription.purchaseTokenAndroid ??
            subscription.purchaseToken ??
            '';
        return token.isNotEmpty
            ? verifiedTokens.contains(token)
            : verifiedProductIds.contains(subscription.productId);
      },
    ).toList(growable: false);

    if (verifiedSubscriptions.any((subscription) => subscription.isActive)) {
      return AndroidSubscriptionHelper
          .resolveAccessStateFromActiveSubscriptions(
        verifiedSubscriptions,
        fallbackProductId: fallbackProductId,
        now: now,
      );
    }

    for (final PurchaseAndroid purchase in verifiedPurchases) {
      final SubscriptionAccessState? blocked = blockingAccessState(purchase);
      if (blocked != null) {
        return blocked;
      }
    }

    final bool hasUnverifiedOwnedPurchase = purchases.any(
      (purchase) =>
          purchase.purchaseState == PurchaseState.Purchased &&
          !verifiedPurchases.contains(purchase),
    );
    if (hasUnverifiedOwnedPurchase) {
      return SubscriptionAccessState(
        status: SubscriptionAccessStatus.revoked,
        evaluatedAtMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
        productId: fallbackProductId,
        note: 'Google Play purchase signature verification failed',
      );
    }

    return AndroidSubscriptionHelper.resolveAccessStateFromActiveSubscriptions(
      const <ActiveSubscription>[],
      fallbackProductId: fallbackProductId,
      now: now,
    );
  }

  @override
  Future<bool> computeTrialEligibility({
    required FlutterInappPurchase iap,
    required List<ProductSubscription> products,
    required List<String> productIds,
    void Function(String message)? logger,
  }) async {
    final bool eligible = AndroidSubscriptionHelper.hasFreeTrial(
      products.whereType<ProductSubscriptionAndroid>().toList(),
    );
    logger?.call('Google Play eligible offers include free trial: $eligible');
    return eligible;
  }

  @override
  SubscriptionTransactionPayload transactionPayload(Purchase purchase) {
    final PurchaseAndroid item = purchase as PurchaseAndroid;
    final String purchaseToken = item.purchaseToken ?? '';
    return SubscriptionTransactionPayload(
      productId: normalizedProductId(item),
      store: item.store,
      originalTransactionId: purchaseToken,
      currentTransactionId: item.transactionId ?? item.id,
      purchaseToken: purchaseToken,
      packageNameAndroid: item.packageNameAndroid,
      purchase: item,
    );
  }
}

class SubscriptionStoreException implements Exception {
  const SubscriptionStoreException({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() => message;
}
