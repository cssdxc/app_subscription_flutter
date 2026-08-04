import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

class SubscriptionTransactionPayload {
  const SubscriptionTransactionPayload({
    required this.productId,
    required this.store,
    required this.originalTransactionId,
    required this.currentTransactionId,
    required this.purchase,
    this.purchaseToken,
    this.packageNameAndroid,
  });

  final String productId;
  final IapStore store;
  final String originalTransactionId;
  final String currentTransactionId;
  final String? purchaseToken;
  final String? packageNameAndroid;
  final Purchase purchase;
}
