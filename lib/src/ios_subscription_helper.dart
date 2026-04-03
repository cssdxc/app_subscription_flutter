import 'package:flutter/services.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

class SubscriptionVerificationResult {
  const SubscriptionVerificationResult({
    required this.isActive,
    this.resolvedItem,
  });

  final bool isActive;
  final PurchaseIOS? resolvedItem;
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

  static bool isPurchaseActive(PurchaseIOS? item) {
    if (item == null) {
      return false;
    }

    if (item.purchaseState != PurchaseState.Purchased) {
      return false;
    }

    if (item.revocationDateIOS != null && item.revocationDateIOS! > 0) {
      return false;
    }

    final double? expirationDateMs = item.expirationDateIOS;
    if (expirationDateMs == null || expirationDateMs <= 0) {
      return false;
    }

    return expirationDateMs > DateTime.now().millisecondsSinceEpoch;
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
}
