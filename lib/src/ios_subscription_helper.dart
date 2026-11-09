import 'dart:convert';

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

/// 提供 App Store 订阅状态关联、权益映射和试用资格判断。
class IosSubscriptionHelper {
  const IosSubscriptionHelper._();

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
    final state = StoreKitSubscriptionState.fromNative(status.state);
    final entitlement = verifiedEntitlement;
    final accessStatus = switch (state) {
      StoreKitSubscriptionState.subscribed => SubscriptionAccessStatus.active,
      StoreKitSubscriptionState.inGracePeriod =>
        SubscriptionAccessStatus.gracePeriod,
      StoreKitSubscriptionState.inBillingRetryPeriod =>
        SubscriptionAccessStatus.billingRetry,
      StoreKitSubscriptionState.expired => SubscriptionAccessStatus.expired,
      StoreKitSubscriptionState.revoked => SubscriptionAccessStatus.revoked,
      StoreKitSubscriptionState.unknown =>
        entitlement?.isActive == true
            ? SubscriptionAccessStatus.active
            : SubscriptionAccessStatus.unavailable,
    };
    final needsEntitlement =
        accessStatus == SubscriptionAccessStatus.active ||
        accessStatus == SubscriptionAccessStatus.gracePeriod;
    final renewal = status.renewalInfo;
    final identity = _renewalIdentity(renewal?.jsonRepresentation);
    return SubscriptionAccessState(
      store: IapStore.Apple,
      status: needsEntitlement && entitlement == null
          ? SubscriptionAccessStatus.unavailable
          : accessStatus,
      evaluatedAtMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
      productId:
          entitlement?.productId ?? identity?.productId ?? fallbackProductId,
      transactionId: entitlement?.transactionId ?? '',
      originalTransactionId:
          _transactionOriginalId(entitlement) ?? identity?.originalId,
      effectiveUntilMs: state == StoreKitSubscriptionState.inGracePeriod
          ? renewal?.gracePeriodExpirationDate?.toInt()
          : entitlement?.expirationDateIOS?.toInt(),
      renewal: renewal == null
          ? null
          : SubscriptionRenewal(
              autoRenewEnabled: renewal.willAutoRenew,
              nextProductId: renewal.willAutoRenew
                  ? renewal.autoRenewPreference
                  : null,
              expectedRenewalAtMs: renewal.renewalDate?.toInt(),
            ),
      note: 'StoreKit state: ${status.state}',
    );
  }

  /// 状态只能与其对应的已验证当前交易匹配，不能按组取最新一笔。
  static List<SubscriptionAccessState>
  resolveAccessStateFromSubscriptionStatuses(
    List<SubscriptionStatusIOS> statuses, {
    required List<ActiveSubscription> verifiedEntitlements,
    required String fallbackProductId,
    DateTime? now,
  }) {
    if (verifiedEntitlements.isEmpty) {
      final identified = statuses.where(
        (status) =>
            _renewalIdentity(status.renewalInfo?.jsonRepresentation) != null,
      );
      if (identified.isNotEmpty) {
        return identified
            .map(
              (status) => resolveAccessStateFromSubscriptionStatus(
                status: status,
                verifiedEntitlement: null,
                fallbackProductId: fallbackProductId,
                now: now,
              ),
            )
            .toList(growable: false);
      }
      final status = statuses.length == 1
          ? statuses.single
          : SubscriptionStatusIOS(state: 'expired');
      return [
        resolveAccessStateFromSubscriptionStatus(
          status: status,
          verifiedEntitlement: null,
          fallbackProductId: fallbackProductId,
          now: now,
        ),
      ];
    }
    return verifiedEntitlements
        .map((entitlement) {
          final originalId = _transactionOriginalId(entitlement);
          final matching = statuses.where((status) {
            // 原生 subscriptionStatusIOS 仅为 verified renewalInfo 提供该 JSON。
            // productId 是当前商品；autoRenewPreference 是未来目标，不能用它匹配。
            final identity = _renewalIdentity(
              status.renewalInfo?.jsonRepresentation,
            );
            return identity != null &&
                identity.productId == entitlement.productId &&
                (originalId == null || identity.originalId == originalId);
          }).toList();
          final status = matching.length == 1
              ? matching.single
              : statuses.length == 1 &&
                    verifiedEntitlements.length == 1 &&
                    statuses.single.renewalInfo?.jsonRepresentation == null
              ? statuses.single
              : null;
          if (status == null) {
            return SubscriptionAccessState(
              store: IapStore.Apple,
              status: SubscriptionAccessStatus.unavailable,
              evaluatedAtMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
              productId: entitlement.productId,
              transactionId: entitlement.transactionId,
              note:
                  'StoreKit status cannot be associated with this transaction',
            );
          }
          return resolveAccessStateFromSubscriptionStatus(
            status: status,
            verifiedEntitlement: entitlement,
            fallbackProductId: entitlement.productId,
            now: now,
          );
        })
        .toList(growable: false);
  }

  static ({String productId, String? originalId})? _renewalIdentity(
    String? raw,
  ) {
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map;
      final productId = json['productId'];
      return productId is String
          ? (
              productId: productId,
              originalId: json['originalTransactionId']?.toString(),
            )
          : null;
    } catch (_) {
      return null;
    }
  }

  static String? _transactionOriginalId(ActiveSubscription? entitlement) {
    return _transactionPayload(
      entitlement,
    )?['originalTransactionId']?.toString();
  }

  /// 此字段来自原生已验证的当前订阅，不依赖商品仍在售。
  static String? subscriptionGroupId(ActiveSubscription entitlement) =>
      _transactionPayload(
        entitlement,
      )?['subscriptionGroupIdentifier']?.toString();

  static Map? _transactionPayload(ActiveSubscription? entitlement) {
    // 此 JWS 来自已由 StoreKit 验证的 currentEntitlements；不接受外部未验证 token。
    try {
      final payload = entitlement?.purchaseToken?.split('.')[1];
      if (payload == null) return null;
      return jsonDecode(
            utf8.decode(base64Url.decode(base64Url.normalize(payload))),
          )
          as Map;
    } catch (_) {
      return null;
    }
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
}
