import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

/// 管理订阅商品查找和价格展示规则。
class SubscriptionCatalog {
  /// 使用配置价格创建商品目录。
  const SubscriptionCatalog({
    required this.defaultPrices,
  });

  /// 商店价格不可用时使用的默认展示价格。
  final Map<String, String> defaultPrices;

  /// 已配置的全部订阅商品标识。
  List<String> get productIds => defaultPrices.keys.toList(growable: false);

  /// 查找指定商品的默认展示价格。
  String findDefaultPrice(String productId) {
    return defaultPrices[productId] ?? '';
  }

  /// 从已加载商品中查找指定商品。
  ProductSubscription? findProduct(
    List<ProductSubscription> products,
    String productId,
  ) {
    for (final product in products) {
      if (product.id == productId) {
        return product;
      }
    }
    return null;
  }

  /// 优先返回商店展示价格，缺失时依次使用配置价格和调用方兜底价格。
  String findDisplayPrice(
    List<ProductSubscription> products,
    String productId,
    String fallbackPrice,
  ) {
    final ProductSubscription? product = findProduct(products, productId);
    final String displayPrice =
        product?.displayPrice ?? findDefaultPrice(productId);
    return displayPrice.isNotEmpty ? displayPrice : fallbackPrice;
  }

  /// 将年订阅价格换算为每周展示价格。
  String yearlyPricePerWeek(
    List<ProductSubscription> products, {
    required String productId,
    required String fallbackPrice,
    required String weekLabel,
  }) {
    if (productId.isEmpty) {
      return '$fallbackPrice / $weekLabel';
    }

    final ProductSubscription? product = findProduct(products, productId);
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
