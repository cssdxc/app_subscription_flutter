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

class AndroidSubscriptionHelper {
  const AndroidSubscriptionHelper._();

  static String normalizedProductId(PurchaseAndroid? item) {
    if (item == null) {
      return '';
    }

    final String productId = item.productId.trim();
    if (productId.isNotEmpty && productId != '0') {
      return productId;
    }

    final List<String> ids = item.ids ?? const <String>[];
    return ids.isEmpty ? '' : ids.first.trim();
  }

  static bool isPending(PurchaseAndroid item) =>
      item.purchaseState == PurchaseState.Pending;

  static bool shouldProcessPurchaseUpdate(PurchaseAndroid item) {
    return item.purchaseState == PurchaseState.Purchased &&
        item.isSuspendedAndroid != true &&
        normalizedProductId(item).isNotEmpty &&
        (item.purchaseToken ?? '').isNotEmpty;
  }

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
      final RSAPublicKey publicKey = _parseLicenseKey(licenseKey);
      final Signer verifier = RSASigner(
        SHA1Digest(),
        '06052b0e03021a',
      )..init(false, PublicKeyParameter<RSAPublicKey>(publicKey));
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
    final Uint8List rsaKeyBytes =
        Uint8List.fromList(publicKeyBits.stringValues ?? const <int>[]);
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

  static List<SubscriptionOffer> purchasableOffers(
    ProductSubscriptionAndroid product,
  ) {
    return product.subscriptionOffers
        .where((offer) => (offer.offerTokenAndroid ?? '').isNotEmpty)
        .toList(growable: false);
  }

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
        code: 'invalid-offer',
        message:
            'The selected Google Play offer does not belong to the product.',
      );
    }

    if (offers.length == 1) {
      return offers.single;
    }
    if (offers.isEmpty) {
      throw const AndroidSubscriptionOfferException(
        code: 'offer-unavailable',
        message: 'No eligible Google Play subscription offer is available.',
      );
    }
    throw const AndroidSubscriptionOfferException(
      code: 'offer-required',
      message: 'Select a Google Play base plan or offer before purchasing.',
    );
  }

  static bool hasFreeTrial(List<ProductSubscriptionAndroid> products) {
    return products.any(
      (product) => product.subscriptionOffers.any(
        (offer) => offer.paymentMode == PaymentMode.FreeTrial,
      ),
    );
  }
}

class AndroidSubscriptionOfferException implements Exception {
  const AndroidSubscriptionOfferException({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() => message;
}
