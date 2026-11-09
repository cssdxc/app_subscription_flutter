import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

import 'subscription_access_state.dart';
import 'subscription_snapshot.dart';
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
  Future<SubscriptionSnapshot> resolveVerifiedAccessState({
    required FlutterInappPurchase iap,
    required List<ActiveSubscription> subscriptions,
    required List<ProductSubscription> products,
    required List<String>? productIds,
    DateTime? now,
  }) async {
    final List<_AppStoreSubscriptionGroup> groups = _resolveSubscriptionGroups(
      products: products,
      subscriptions: subscriptions,
      productIds: productIds,
    );
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
        groupStates.addAll(
          IosSubscriptionHelper.resolveAccessStateFromSubscriptionStatuses(
                statuses,
                verifiedEntitlements: verifiedEntitlements,
                fallbackProductId: group.productIds.first,
                now: now,
              )
              .map(
                (state) => state.copyWith(
                  subscriptionGroupIdIOS: group.subscriptionGroupId,
                ),
              )
              .where((state) => group.productIds.contains(state.productId)),
        );
      } catch (error) {
        queryFailedProductIds.addAll(group.productIds);
        groupStates.add(
          SubscriptionAccessState(
            store: IapStore.Apple,
            status: SubscriptionAccessStatus.unavailable,
            evaluatedAtMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
            productId: group.productIds.first,
            note: 'StoreKit subscription status unavailable: $error',
            reason: SubscriptionAccessReason.storeQueryFailed,
          ),
        );
      }
    }

    return SubscriptionSnapshot(
      evaluatedAtMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
      subscriptions: groupStates,
      queryFailedProductIds: queryFailedProductIds,
    );
  }

  List<_AppStoreSubscriptionGroup> _resolveSubscriptionGroups({
    required List<ProductSubscription> products,
    required List<ActiveSubscription> subscriptions,
    required List<String>? productIds,
  }) {
    final groupByProduct = <String, String?>{
      for (final product in products.whereType<ProductSubscriptionIOS>())
        product.id: product.subscriptionGroupIdIOS,
    };
    for (final subscription in subscriptions) {
      groupByProduct[subscription.productId] ??=
          IosSubscriptionHelper.subscriptionGroupId(subscription);
    }
    final idsByGroup = <String, Set<String>>{};
    // 已加载商品优先作为组内查询入口，历史交易不需要再次注册或上架。
    for (final id in {...groupByProduct.keys, ...?productIds}) {
      final groupId = groupByProduct[id]?.trim() ?? '';
      final key = groupId.isEmpty ? 'product:$id' : 'group:$groupId';
      idsByGroup.putIfAbsent(key, () => <String>{}).add(id);
    }
    return [
      for (final ids in idsByGroup.values)
        if (productIds == null || ids.any(productIds.contains))
          _AppStoreSubscriptionGroup(
            representativeProductId: ids.first,
            productIds: productIds == null
                ? ids
                : ids.where(productIds.contains).toSet(),
            subscriptionGroupId: groupByProduct[ids.first],
          ),
    ];
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
    this.subscriptionGroupId,
  });

  /// 用于调用 `subscriptionStatusIOS` 的组内代表商品。
  final String representativeProductId;

  final String? subscriptionGroupId;

  /// 本次查询识别出的同组商品，包含仍有效的历史商品。
  final Set<String> productIds;
}
