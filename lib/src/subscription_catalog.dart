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

    final double? rawPrice = product.price;
    if (rawPrice == null) {
      return '$fallbackPrice / $weekLabel';
    }

    final double weeklyPrice = rawPrice / 52.0;
    final String displayPrice =
        product.displayPrice.isNotEmpty ? product.displayPrice : fallbackPrice;
    final String weeklyDisplayPrice =
        _replaceDisplayPriceAmount(displayPrice, weeklyPrice);
    return '$weeklyDisplayPrice / $weekLabel';
  }

  String _replaceDisplayPriceAmount(String displayPrice, double amount) {
    final RegExp amountPattern = RegExp(r'\d(?:[\d.,，]|\s(?=\d))*');
    final RegExpMatch? match = amountPattern.firstMatch(displayPrice);
    if (match == null) {
      return amount.toStringAsFixed(2);
    }

    final String originalAmount = match.group(0)!;
    final String formattedAmount = _formatAmountLike(originalAmount, amount);
    return displayPrice.replaceRange(match.start, match.end, formattedAmount);
  }

  String _formatAmountLike(String originalAmount, double amount) {
    final String decimalSeparator = _decimalSeparatorOf(originalAmount);
    final String formatted = amount.toStringAsFixed(2);
    if (decimalSeparator == ',') {
      return formatted.replaceAll('.', ',');
    }
    return formatted;
  }

  String _decimalSeparatorOf(String amount) {
    final int lastDot = amount.lastIndexOf('.');
    final int lastComma = amount.lastIndexOf(',');
    final int lastFullWidthComma = amount.lastIndexOf('，');
    final int lastCommaLike =
        lastComma > lastFullWidthComma ? lastComma : lastFullWidthComma;

    if (lastCommaLike > lastDot && _digitsAfter(amount, lastCommaLike) == 2) {
      return ',';
    }
    return '.';
  }

  int _digitsAfter(String value, int index) {
    int count = 0;
    for (int i = index + 1; i < value.length; i++) {
      final int codeUnit = value.codeUnitAt(i);
      if (codeUnit < 0x30 || codeUnit > 0x39) {
        continue;
      }
      count++;
    }
    return count;
  }
}
