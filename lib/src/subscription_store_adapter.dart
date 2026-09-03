import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

import 'android_subscription_helper.dart';
import 'ios_subscription_helper.dart';
import 'subscription_access_state.dart';
import 'subscription_transaction.dart';

/// 查询一个 App Store 订阅组的 StoreKit 2 状态；主要用于测试替换默认查询。
typedef SubscriptionStatusQueryIOS = Future<List<SubscriptionStatusIOS>>
    Function(String productId);

/// 发起订阅购买时传给对应商店的可选参数。
class SubscriptionPurchaseOptions {
  /// 创建平台购买参数；未提供的字段由商店使用默认行为。
  const SubscriptionPurchaseOptions({
    this.offer,
    this.appAccountTokenIOS,
    this.obfuscatedAccountIdAndroid,
    this.obfuscatedProfileIdAndroid,
    this.isOfferPersonalizedAndroid,
  });

  /// 要购买的 base plan 或促销 offer；当前仅 Android 使用。
  final SubscriptionOffer? offer;

  /// 关联 App Store 交易与应用账户的 UUID 字符串。
  final String? appAccountTokenIOS;

  /// 经过不可逆散列的 Google Play 账户标识。
  final String? obfuscatedAccountIdAndroid;

  /// 经过不可逆散列的 Google Play 用户资料标识。
  final String? obfuscatedProfileIdAndroid;

  /// Google Play 促销价格是否基于用户个性化处理。
  final bool? isOfferPersonalizedAndroid;
}

/// 隔离 App Store 与 Google Play 差异的订阅商店适配契约。
abstract interface class SubscriptionStoreAdapter {
  /// 根据插件当前平台创建对应的商店适配器。
  factory SubscriptionStoreAdapter.forIap(
    FlutterInappPurchase iap, {
    String googlePlayLicenseKeyAndroid = '',
    SubscriptionStatusQueryIOS? subscriptionStatusQueryIOS,
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
      return AppStoreSubscriptionAdapter(
        subscriptionStatusQuery: subscriptionStatusQueryIOS,
      );
    }
    throw UnsupportedError(
        'Subscriptions are supported only on iOS and Android.');
  }

  /// 当前适配器是否支持该商品类型。
  bool supportsProduct(ProductSubscription product);

  /// 当前适配器是否支持该购买对象类型。
  bool supportsPurchase(Purchase purchase);

  /// 返回商品在当前商店可购买的 offer。
  List<SubscriptionOffer> offersFor(ProductSubscription product);

  /// 将平台购买对象中的商品标识归一化。
  String normalizedProductId(Purchase purchase);

  /// 判断交易是否仍在等待处理。
  bool isPending(Purchase purchase);

  /// 判断购买更新是否可以进入验证流程。
  bool shouldProcessPurchaseUpdate(Purchase purchase);

  /// 返回能够立即阻断权益的商店状态，否则返回空。
  SubscriptionAccessState? blockingAccessState(Purchase purchase);

  /// 向当前商店发起订阅购买。
  Future<void> requestPurchase({
    required FlutterInappPurchase iap,
    required ProductSubscription product,
    required SubscriptionPurchaseOptions options,
  });

  /// 恢复或重新查询当前商店中的已有购买。
  Future<List<Purchase>> restorePurchases(FlutterInappPurchase iap);

  /// 完成 App Store 交易或确认 Google Play 购买。
  Future<void> finishTransaction({
    required FlutterInappPurchase iap,
    required Purchase purchase,
  });

  /// 使用平台提供的数据在设备端验证购买真实性。
  Future<void> verifyPurchaseLocally({
    required FlutterInappPurchase iap,
    required Purchase purchase,
  });

  /// 将已验证的商店订阅解析为统一权益状态。
  Future<SubscriptionAccessState> resolveVerifiedAccessState({
    required FlutterInappPurchase iap,
    required List<ActiveSubscription> subscriptions,
    required List<ProductSubscription> products,
    required List<String> productIds,
    required String fallbackProductId,
    DateTime? now,
  });

  /// 计算当前商品集合是否包含用户可用的免费试用。
  Future<bool> computeTrialEligibility({
    required FlutterInappPurchase iap,
    required List<ProductSubscription> products,
    required List<String> productIds,
    void Function(String message)? logger,
  });

  /// 将平台购买对象转换为统一交易回传载荷。
  SubscriptionTransactionPayload transactionPayload(Purchase purchase);
}

/// 负责 App Store 购买、验证和权益映射。
class AppStoreSubscriptionAdapter implements SubscriptionStoreAdapter {
  /// 创建 App Store 订阅适配器。
  const AppStoreSubscriptionAdapter({this.subscriptionStatusQuery});

  /// 可选的 StoreKit 状态查询替身；生产环境直接使用插件接口。
  final SubscriptionStatusQueryIOS? subscriptionStatusQuery;

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
    required List<ProductSubscription> products,
    required List<String> productIds,
    required String fallbackProductId,
    DateTime? now,
  }) async {
    final List<_AppStoreSubscriptionGroup> groups =
        _resolveSubscriptionGroups(products: products, productIds: productIds);
    if (groups.isEmpty) {
      return SubscriptionAccessState(
        status: SubscriptionAccessStatus.unavailable,
        evaluatedAtMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
        productId: fallbackProductId,
        note: 'no App Store subscription product configured',
      );
    }

    final SubscriptionStatusQueryIOS query =
        subscriptionStatusQuery ?? iap.subscriptionStatusIOS;
    final List<SubscriptionAccessState> groupStates =
        <SubscriptionAccessState>[];

    for (final _AppStoreSubscriptionGroup group in groups) {
      try {
        final List<SubscriptionStatusIOS> statuses =
            await query(group.representativeProductId);
        final List<ActiveSubscription> verifiedEntitlements = subscriptions
            .where(
              (subscription) => group.productIds.contains(
                subscription.productId,
              ),
            )
            .toList(growable: false);
        groupStates.add(
          IosSubscriptionHelper.resolveAccessStateFromSubscriptionStatuses(
            statuses,
            verifiedEntitlements: verifiedEntitlements,
            fallbackProductId: group.representativeProductId,
            now: now,
          ),
        );
      } catch (error) {
        groupStates.add(
          SubscriptionAccessState(
            status: SubscriptionAccessStatus.unavailable,
            evaluatedAtMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
            productId: group.representativeProductId,
            note: 'StoreKit subscription status unavailable: $error',
          ),
        );
      }
    }

    return IosSubscriptionHelper.selectMostRelevantAccessState(groupStates);
  }

  List<_AppStoreSubscriptionGroup> _resolveSubscriptionGroups({
    required List<ProductSubscription> products,
    required List<String> productIds,
  }) {
    final Set<String> configuredProductIds = productIds.toSet();
    final Map<String, Set<String>> productIdsByGroup = <String, Set<String>>{};

    for (final ProductSubscriptionIOS product
        in products.whereType<ProductSubscriptionIOS>()) {
      if (!configuredProductIds.contains(product.id)) {
        continue;
      }
      final String subscriptionGroupId =
          (product.subscriptionGroupIdIOS ?? '').trim();
      final String groupKey = subscriptionGroupId.isEmpty
          ? 'product:${product.id}'
          : 'group:$subscriptionGroupId';
      productIdsByGroup.putIfAbsent(groupKey, () => <String>{}).add(product.id);
    }

    final Set<String> resolvedProductIds =
        productIdsByGroup.values.expand((ids) => ids).toSet();
    for (final String productId in productIds) {
      if (!resolvedProductIds.contains(productId)) {
        productIdsByGroup['product:$productId'] = <String>{productId};
      }
    }

    return productIdsByGroup.values
        .map(
          (ids) => _AppStoreSubscriptionGroup(
            representativeProductId: ids.first,
            productIds: ids,
          ),
        )
        .toList(growable: false);
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

/// 保存一次 StoreKit 状态查询所覆盖的订阅组商品。
class _AppStoreSubscriptionGroup {
  const _AppStoreSubscriptionGroup({
    required this.representativeProductId,
    required this.productIds,
  });

  /// 用于调用 `subscriptionStatusIOS` 的组内代表商品。
  final String representativeProductId;

  /// 属于该订阅组且由当前应用管理的商品标识。
  final Set<String> productIds;
}

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
    required List<ProductSubscription> products,
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

    // 查询时包含 suspended 购买，确保账单问题不会被误判为无购买记录。
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

    // 优先用购买令牌关联两类返回值，旧载荷缺少令牌时才按商品标识关联。
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

/// 表示商店适配、验证或交易完成过程中的可分类错误。
class SubscriptionStoreException implements Exception {
  /// 创建包含稳定错误码和说明的商店异常。
  const SubscriptionStoreException({
    required this.code,
    required this.message,
  });

  /// 可供调用方分类处理的错误码。
  final String code;

  /// 面向日志或调用方的错误说明。
  final String message;

  @override
  String toString() => message;
}
