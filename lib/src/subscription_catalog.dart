import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

class SubscriptionCatalog {
  const SubscriptionCatalog({
    required this.defaultPrices,
    this.yearlyProductId,
  });

  final Map<String, String> defaultPrices;
  final String? yearlyProductId;

  List<String> get productIds => defaultPrices.keys.toList(growable: false);

  String findDefaultPrice(String productId) {
    return defaultPrices[productId] ?? '';
  }

  ProductSubscriptionIOS? findProduct(
    List<ProductSubscriptionIOS> products,
    String productId,
  ) {
    for (final product in products) {
      if (product.id == productId) {
        return product;
      }
    }
    return null;
  }

  String findDisplayPrice(
    List<ProductSubscriptionIOS> products,
    String productId,
    String fallbackPrice,
  ) {
    final ProductSubscriptionIOS? product = findProduct(products, productId);
    final String displayPrice =
        product?.displayPrice ?? findDefaultPrice(productId);
    return displayPrice.isNotEmpty ? displayPrice : fallbackPrice;
  }

  String yearlyPricePerWeek(
    List<ProductSubscriptionIOS> products, {
    required String fallbackPrice,
    required String weekLabel,
  }) {
    final String? targetProductId = yearlyProductId;
    if (targetProductId == null || targetProductId.isEmpty) {
      return '$fallbackPrice / $weekLabel';
    }

    final ProductSubscriptionIOS? product =
        findProduct(products, targetProductId);
    if (product == null) {
      return '$fallbackPrice / $weekLabel';
    }

    final double rawPrice = product.price ?? 0.0;
    final String displayPrice = product.displayPrice;

    String symbol = displayPrice.replaceAll(RegExp(r'[0-9.,，\s]'), '');
    if (symbol.isEmpty && displayPrice.isNotEmpty) {
      symbol = displayPrice.substring(0, 1);
    }

    final double weeklyPrice = rawPrice / 52.0;
    return '$symbol${weeklyPrice.toStringAsFixed(2)} / $weekLabel';
  }
}
