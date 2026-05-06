import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

import 'subscription_service_example.dart';

class ExampleTextKey {
  static String get cancel => 'Cancelled';
  static String get buyFailed => 'Purchase failed';
  static String get restoreFailed => 'Restore failed';
}

class ExampleSubscriptionUiDelegate {
  ExampleSubscriptionUiDelegate(this.subscriptionService);

  final ExampleSubscriptionService subscriptionService;

  Future<SubscriptionActionResult> purchase({
    required ProductSubscriptionIOS? product,
    required String source,
  }) async {
    debugPrint('[SubscriptionUI] loading');
    final result = await subscriptionService.purchaseSubscription(
      product,
      source: source,
    );
    debugPrint('[SubscriptionUI] done');

    if (result.success) {
      debugPrint(
        '[SubscriptionUI] success source=$source productId=${result.productId ?? ''}',
      );
      return result;
    }

    if (result.cancelled) {
      debugPrint(ExampleTextKey.cancel);
      return result;
    }

    debugPrint(ExampleTextKey.buyFailed);
    return result;
  }

  Future<SubscriptionActionResult> purchaseMonthly({
    String source = 'paywall_monthly',
  }) async {
    debugPrint('[SubscriptionUI] loading');
    final result = await subscriptionService.purchaseMonthly(source: source);
    debugPrint('[SubscriptionUI] done');

    if (result.success) {
      debugPrint(
        '[SubscriptionUI] success source=$source productId=${result.productId ?? ''}',
      );
      return result;
    }

    if (result.cancelled) {
      debugPrint(ExampleTextKey.cancel);
      return result;
    }

    debugPrint(ExampleTextKey.buyFailed);
    return result;
  }

  Future<SubscriptionActionResult> restore({
    required String source,
  }) async {
    debugPrint('[SubscriptionUI] loading');
    final result = await subscriptionService.restorePurchases(source: source);
    debugPrint('[SubscriptionUI] done');

    if (result.failed) {
      debugPrint(ExampleTextKey.restoreFailed);
    }
    return result;
  }
}
