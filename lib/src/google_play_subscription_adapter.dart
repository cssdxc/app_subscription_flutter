import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

import 'subscription_access_state.dart';
import 'subscription_snapshot.dart';
import 'subscription_failure.dart';
import 'subscription_plan.dart';
import 'subscription_store_adapter.dart';
import 'subscription_transaction.dart';
import 'android_subscription_helper.dart';

/// 同一次 Play 查询获得的权益和对应的已验签购买。
typedef GooglePlayPurchaseSnapshot = ({
  SubscriptionSnapshot access,
  List<PurchaseAndroid> currentPurchases,
});

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

  static const _billingChannel = MethodChannel('flutter_inapp');

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
    void Function(GooglePlayAcknowledgementError?)? onAcknowledgement,
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
    Never fail(GooglePlayAcknowledgementError error) {
      onAcknowledgement?.call(error);
      throw const SubscriptionStoreException(
        failureCode: SubscriptionFailureCode.acknowledgementFailed,
        message: 'Google Play did not acknowledge the subscription purchase.',
      );
    }

    final Object? reply;
    try {
      // 11.0.3 的 Dart 布尔接口会丢弃原生异常；直接使用同一确认通道。
      reply = await _billingChannel.invokeMethod<Object?>(
        'acknowledgePurchaseAndroid',
        {'purchaseToken': token},
      );
    } on PlatformException catch (error) {
      fail(
        _billingFailure(
          error.details,
          nativeCode: error.code,
          nativeMessage: error.message,
        ),
      );
    } on MissingPluginException catch (error) {
      fail(GooglePlayAcknowledgementError(nativeMessage: error.message));
    }

    final Object? result;
    try {
      result = reply is String ? jsonDecode(reply) : reply;
    } on FormatException {
      fail(const GooglePlayAcknowledgementError());
    }
    if (result != true && (result is! Map || result['responseCode'] != 0)) {
      fail(_billingFailure(result));
    }
    onAcknowledgement?.call(null);
  }

  static GooglePlayAcknowledgementError _billingFailure(
    Object? details, {
    String? nativeCode,
    String? nativeMessage,
  }) {
    final fields = details is Map ? details : null;
    final responseCode = fields?['responseCode'];
    final debugMessage = fields?['debugMessage'];
    return GooglePlayAcknowledgementError(
      responseCode: responseCode is int ? responseCode : null,
      debugMessage: debugMessage is String ? debugMessage : null,
      nativeCode: nativeCode,
      nativeMessage: nativeMessage,
    );
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
  }) async => (await queryVerifiedPurchases(
    iap: iap,
    subscriptions: subscriptions,
    productIds: productIds,
    now: now,
  )).access;

  Future<GooglePlayPurchaseSnapshot> queryVerifiedPurchases({
    required FlutterInappPurchase iap,
    required List<ActiveSubscription> subscriptions,
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
            .where(supportsPurchase)
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
    final eligible = <(String, String), PurchaseAndroid>{};
    for (final purchase in verifiedPurchases) {
      final token = purchase.purchaseToken;
      if (token == null ||
          token.isEmpty ||
          purchase.purchaseState != PurchaseState.Purchased ||
          purchase.isSuspendedAndroid == true) {
        continue;
      }
      final key = (purchase.productId, token);
      if (purchase.isAcknowledgedAndroid == true ||
          !eligible.containsKey(key)) {
        eligible[key] = purchase;
      }
    }
    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final currentPurchases = <PurchaseAndroid>{};
    final states = <SubscriptionAccessState>[];
    for (final subscription in subscriptions) {
      final key = (
        subscription.productId,
        subscription.purchaseTokenAndroid ?? subscription.purchaseToken ?? '',
      );
      final purchase = eligible[key];
      if (purchase == null) continue;
      final state =
          AndroidSubscriptionHelper.resolveAccessStateFromActiveSubscription(
            subscription: subscription,
            now: now,
          );
      states.add(state);
      if (state.shouldGrantAccess) currentPurchases.add(purchase);
    }
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
    return (
      access: SubscriptionSnapshot(evaluatedAtMs: nowMs, subscriptions: states),
      currentPurchases: currentPurchases.toList(growable: false),
    );
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
