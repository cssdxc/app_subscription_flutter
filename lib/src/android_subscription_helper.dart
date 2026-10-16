import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:pointycastle/asn1/asn1_parser.dart';
import 'package:pointycastle/asn1/primitives/asn1_bit_string.dart';
import 'package:pointycastle/asn1/primitives/asn1_integer.dart';
import 'package:pointycastle/asn1/primitives/asn1_sequence.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/digests/sha1.dart';
import 'package:pointycastle/signers/rsa_signer.dart';

import 'subscription_access_state.dart';
import 'subscription_failure.dart';

/// 提供 Google Play 订阅字段归一化、签名验证和 offer 选择规则。
class AndroidSubscriptionHelper {
  const AndroidSubscriptionHelper._();

  /// 从购买对象中解析稳定的商品标识。
  static String normalizedProductId(PurchaseAndroid item) =>
      item.productId.trim();

  /// 判断购买是否仍在等待用户或商店处理。
  static bool isPending(PurchaseAndroid item) =>
      item.purchaseState == PurchaseState.Pending;

  /// 判断购买更新是否满足后续验证和确认条件。
  static bool shouldProcessPurchaseUpdate(PurchaseAndroid item) {
    return item.purchaseState == PurchaseState.Purchased &&
        item.isSuspendedAndroid != true &&
        normalizedProductId(item).isNotEmpty &&
        (item.purchaseToken ?? '').isNotEmpty;
  }

  /// 使用 Play Console 公钥验证购买签名及关键字段一致性。
  static bool verifyPurchaseSignature({
    required PurchaseAndroid purchase,
    required String licenseKey,
  }) {
    final String purchaseData = purchase.dataAndroid ?? '';
    final String signature = purchase.signatureAndroid ?? '';
    if (licenseKey.trim().isEmpty ||
        purchaseData.isEmpty ||
        signature.isEmpty) {
      return false;
    }

    try {
      // 签名只能证明原始购买数据未被篡改，仍需校验购买令牌、商品和包名。
      final RSAPublicKey publicKey = _parseLicenseKey(licenseKey);
      final Signer verifier = RSASigner(SHA1Digest(), '06052b0e03021a')
        ..init(false, PublicKeyParameter<RSAPublicKey>(publicKey));
      final bool signatureIsValid = verifier.verifySignature(
        Uint8List.fromList(utf8.encode(purchaseData)),
        RSASignature(Uint8List.fromList(base64.decode(signature))),
      );
      if (!signatureIsValid) {
        return false;
      }

      final dynamic decoded = jsonDecode(purchaseData);
      if (decoded is! Map) {
        return false;
      }
      final Map<String, dynamic> signedData = decoded.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      if (signedData['purchaseToken']?.toString() != purchase.purchaseToken) {
        return false;
      }

      final Set<String> signedProductIds = <String>{};
      final String signedProductId = signedData['productId']?.toString() ?? '';
      if (signedProductId.isNotEmpty) {
        signedProductIds.add(signedProductId);
      }
      final dynamic products = signedData['products'];
      if (products is List) {
        signedProductIds.addAll(products.map((product) => product.toString()));
      }
      if (!signedProductIds.contains(normalizedProductId(purchase))) {
        return false;
      }

      final String signedPackageName =
          signedData['packageName']?.toString() ?? '';
      return signedPackageName.isEmpty ||
          signedPackageName == purchase.packageNameAndroid;
    } catch (_) {
      return false;
    }
  }

  static RSAPublicKey _parseLicenseKey(String licenseKey) {
    final String normalizedKey = licenseKey
        .replaceAll('-----BEGIN PUBLIC KEY-----', '')
        .replaceAll('-----END PUBLIC KEY-----', '')
        .replaceAll(RegExp(r'\s'), '');
    final Uint8List keyBytes = base64.decode(normalizedKey);
    final ASN1Sequence subjectPublicKeyInfo =
        ASN1Parser(keyBytes).nextObject() as ASN1Sequence;
    final List<Object?> topLevel = subjectPublicKeyInfo.elements ?? const [];
    if (topLevel.length != 2 || topLevel[1] is! ASN1BitString) {
      throw const FormatException('Invalid Google Play license key.');
    }

    final ASN1BitString publicKeyBits = topLevel[1] as ASN1BitString;
    final Uint8List rsaKeyBytes = Uint8List.fromList(
      publicKeyBits.stringValues ?? const <int>[],
    );
    final ASN1Sequence rsaKey =
        ASN1Parser(rsaKeyBytes).nextObject() as ASN1Sequence;
    final List<Object?> keyParts = rsaKey.elements ?? const [];
    if (keyParts.length != 2 ||
        keyParts[0] is! ASN1Integer ||
        keyParts[1] is! ASN1Integer) {
      throw const FormatException('Invalid Google Play RSA public key.');
    }

    return RSAPublicKey(
      (keyParts[0] as ASN1Integer).integer!,
      (keyParts[1] as ASN1Integer).integer!,
    );
  }

  /// 将一个 Google Play 当前订阅映射为统一权益状态。
  static SubscriptionAccessState resolveAccessStateFromActiveSubscription({
    required ActiveSubscription subscription,
    DateTime? now,
  }) {
    final int nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return SubscriptionAccessState(
      status: subscription.isActive
          ? SubscriptionAccessStatus.active
          : SubscriptionAccessStatus.expired,
      evaluatedAtMs: nowMs,
      productId: subscription.productId,
      transactionId: subscription.transactionId,
      note: subscription.isActive
          ? 'active Google Play subscription'
          : 'inactive Google Play subscription',
    );
  }

  /// 从多个 Google Play 当前订阅中选择可授予权益的状态。
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
        note: 'no active Google Play subscription',
        reason: SubscriptionAccessReason.noCurrentSubscription,
      );
    }

    for (final ActiveSubscription subscription in subscriptions) {
      if (subscription.isActive) {
        return resolveAccessStateFromActiveSubscription(
          subscription: subscription,
          now: now,
        );
      }
    }
    return resolveAccessStateFromActiveSubscription(
      subscription: subscriptions.first,
      now: now,
    );
  }

  /// 返回包含有效购买令牌的订阅 offer。
  static List<SubscriptionOffer> purchasableOffers(
    ProductSubscriptionAndroid product,
  ) {
    return product.subscriptionOffers
        .where((offer) => (offer.offerTokenAndroid ?? '').isNotEmpty)
        .toList(growable: false);
  }

  /// 解析本次购买使用的 base plan 或 offer。
  static SubscriptionOffer resolvePurchaseOffer(
    ProductSubscriptionAndroid product, {
    SubscriptionOffer? requestedOffer,
  }) {
    final List<SubscriptionOffer> offers = purchasableOffers(product);
    if (requestedOffer != null) {
      final String token = requestedOffer.offerTokenAndroid ?? '';
      for (final SubscriptionOffer offer in offers) {
        if (token.isNotEmpty && offer.offerTokenAndroid == token) {
          return offer;
        }
      }
      throw const AndroidSubscriptionOfferException(
        failureCode: SubscriptionFailureCode.invalidOffer,
        message:
            'The selected Google Play offer does not belong to the product.',
      );
    }

    if (offers.length == 1) {
      return offers.single;
    }
    if (offers.isEmpty) {
      throw const AndroidSubscriptionOfferException(
        failureCode: SubscriptionFailureCode.offerUnavailable,
        message: 'No eligible Google Play subscription offer is available.',
      );
    }
    throw const AndroidSubscriptionOfferException(
      failureCode: SubscriptionFailureCode.offerRequired,
      message: 'Select a Google Play base plan or offer before purchasing.',
    );
  }
}

/// 表示 Google Play 订阅 offer 无法用于当前购买。
class AndroidSubscriptionOfferException implements Exception {
  /// 创建包含稳定错误码和说明的 offer 异常。
  const AndroidSubscriptionOfferException({
    required this.failureCode,
    required this.message,
  });

  /// 可供调用方分类处理的错误码。
  final SubscriptionFailureCode failureCode;
  String get code => failureCode.code;

  /// 面向日志或调用方的错误说明。
  final String message;

  @override
  String toString() => message;
}
