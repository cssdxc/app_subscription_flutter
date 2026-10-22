import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

import 'subscription_access_state.dart';
import 'subscription_failure.dart';
import 'subscription_plan.dart';
import 'subscription_store_adapter.dart';
import 'subscription_transaction.dart';
import 'ios_subscription_helper.dart';

/// 负责 App Store 购买、验证和权益映射。
class AppStoreSubscriptionAdapter implements SubscriptionStoreAdapter {
  /// 创建 App Store 订阅适配器。
  const AppStoreSubscriptionAdapter({this.subscriptionStatusQuery});

  /// 可选的 StoreKit 状态查询替身；生产环境直接使用插件接口。
  final SubscriptionStatusQueryIOS? subscriptionStatusQuery;

  @override
  Future<Map<String, SubscriptionTrialEligibility>> queryTrialEligibility({
    required FlutterInappPurchase iap,
    required List<ProductSubscription> products,
  }) => IosSubscriptionHelper.queryTrialEligibility(
    iap: iap,
    products: products.whereType<ProductSubscriptionIOS>().toList(),
  );

  @override
  bool supportsPurchase(Purchase purchase) =>
      purchase is PurchaseIOS && purchase.storeId == StoreIds.apple;

  @override
  SubscriptionFailureCode? purchaseFailure(Purchase purchase) => null;

  @override
  Future<void> requestPurchase({
    required FlutterInappPurchase iap,
    required ProductSubscription product,
    required SubscriptionOffer? offer,
    required SubscriptionPurchaseOptions options,
  }) {
    if (product is! ProductSubscriptionIOS) {
      throw const SubscriptionStoreException(
        failureCode: SubscriptionFailureCode.invalidProductPlatform,
        message: 'The product is not an App Store subscription.',
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
    final String productId = item.productId;
    if (productId.isEmpty || !await iap.isTransactionVerifiedIOS(productId)) {
      throw const SubscriptionStoreException(
        failureCode: SubscriptionFailureCode.localVerificationFailed,
        message: 'StoreKit could not verify the subscription transaction.',
      );
    }
  }

  @override
  Future<SubscriptionAccessResolution> resolveVerifiedAccessState({
    required FlutterInappPurchase iap,
    required List<ActiveSubscription> subscriptions,
    required List<ProductSubscription> products,
    required List<String> productIds,
    required String fallbackProductId,
    DateTime? now,
  }) async {
    final List<_AppStoreSubscriptionGroup> groups = _resolveSubscriptionGroups(
      products: products,
      productIds: productIds,
    );
    if (groups.isEmpty) {
      return (
        state: SubscriptionAccessState(
          status: SubscriptionAccessStatus.unavailable,
          evaluatedAtMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
          productId: fallbackProductId,
          note: 'no App Store subscription product configured',
        ),
        queryFailedProductIds: const <String>{},
      );
    }

    final SubscriptionStatusQueryIOS query =
        subscriptionStatusQuery ?? iap.subscriptionStatusIOS;
    final List<SubscriptionAccessState> groupStates =
        <SubscriptionAccessState>[];
    final queryFailedProductIds = <String>{};

    for (final _AppStoreSubscriptionGroup group in groups) {
      try {
        final List<SubscriptionStatusIOS> statuses = await query(
          group.representativeProductId,
        );
        final List<ActiveSubscription> verifiedEntitlements = subscriptions
            .where(
              (subscription) =>
                  group.productIds.contains(subscription.productId),
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
        queryFailedProductIds.addAll(group.productIds);
        groupStates.add(
          SubscriptionAccessState(
            status: SubscriptionAccessStatus.unavailable,
            evaluatedAtMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
            productId: group.representativeProductId,
            note: 'StoreKit subscription status unavailable: $error',
            reason: SubscriptionAccessReason.storeQueryFailed,
          ),
        );
      }
    }

    final state = IosSubscriptionHelper.selectMostRelevantAccessState(
      groupStates,
    );
    return (
      state: !state.shouldGrantAccess && queryFailedProductIds.isNotEmpty
          ? groupStates.firstWhere(
              (state) =>
                  state.reason == SubscriptionAccessReason.storeQueryFailed,
            )
          : state,
      queryFailedProductIds: Set.unmodifiable(queryFailedProductIds),
    );
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
      final String subscriptionGroupId = (product.subscriptionGroupIdIOS ?? '')
          .trim();
      final String groupKey = subscriptionGroupId.isEmpty
          ? 'product:${product.id}'
          : 'group:$subscriptionGroupId';
      productIdsByGroup.putIfAbsent(groupKey, () => <String>{}).add(product.id);
    }

    final Set<String> resolvedProductIds = productIdsByGroup.values
        .expand((ids) => ids)
        .toSet();
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
  SubscriptionTransactionPayload transactionPayload(Purchase purchase) {
    final PurchaseIOS item = purchase as PurchaseIOS;
    return SubscriptionTransactionPayload(
      productId: item.productId,
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
