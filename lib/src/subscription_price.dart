import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:intl/intl.dart';

/// Google Billing 的 RecurrenceMode。插件以 int 暴露，只在此处转换。
/// https://developer.android.com/reference/com/android/billingclient/api/ProductDetails.RecurrenceMode
enum SubscriptionRecurrenceMode {
  infiniteRecurring(1),
  finiteRecurring(2),
  nonRecurring(3),
  unknown(0);

  const SubscriptionRecurrenceMode(this.nativeValue);
  final int nativeValue;

  static SubscriptionRecurrenceMode fromNative(int value) => values.firstWhere(
    (mode) => mode.nativeValue == value,
    orElse: () => unknown,
  );
}

/// 商店提供的数值价格和计费周期；displayPrice 始终保留商店原文。
class SubscriptionPrice {
  const SubscriptionPrice({
    required this.amount,
    required this.currencyCode,
    required this.displayPrice,
    this.period,
    this.recurrenceMode,
  });

  final double amount;
  final String currencyCode;
  final String displayPrice;
  final SubscriptionPeriod? period;
  final SubscriptionRecurrenceMode? recurrenceMode;

  /// 纯展示用平均价，不是实际扣款金额或权益期限。
  ///
  /// 除数由宿主明确给出，例如年价按 52 周或 12 个月展示；不隐式换算日历周期。
  /// locale/单位文案由宿主本地化；默认使用 ISO 货币代码，避免 $ 的币种歧义。
  String averagePrice({
    required int divisor,
    required String locale,
    required String unitLabel,
    String? currencySymbol,
    int? decimalDigits,
  }) {
    if (divisor <= 0)
      throw ArgumentError.value(divisor, 'divisor', 'Must be positive.');
    final format = NumberFormat.currency(
      locale: locale,
      name: currencyCode,
      symbol: currencySymbol,
      decimalDigits: decimalDigits,
    );
    return '${format.format(amount / divisor)}/$unitLabel';
  }

  /// Play 单一日期单位的 ISO 8601 周期；无法表达的组合保留为未知。
  static SubscriptionPeriod? parseBillingPeriod(String value) {
    final match = RegExp(r'^P([1-9][0-9]*)([DWMY])$').firstMatch(value);
    if (match == null) return null;
    final unit = switch (match.group(2)) {
      'D' => SubscriptionPeriodUnit.Day,
      'W' => SubscriptionPeriodUnit.Week,
      'M' => SubscriptionPeriodUnit.Month,
      'Y' => SubscriptionPeriodUnit.Year,
      _ => SubscriptionPeriodUnit.Unknown,
    };
    return SubscriptionPeriod(unit: unit, value: int.parse(match.group(1)!));
  }
}
