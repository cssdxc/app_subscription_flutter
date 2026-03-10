import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
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
    EasyLoading.show();
    final result = await subscriptionService.purchaseSubscription(
      product,
      source: source,
    );
    EasyLoading.dismiss();

    if (result.success) {
      FirebaseAnalytics.instance.logEvent(
        name: 'subscription_success',
        parameters: {
          'source': source,
          'product_id': result.productId ?? '',
        },
      );
      return result;
    }

    if (result.cancelled) {
      EasyLoading.showError(ExampleTextKey.cancel);
      return result;
    }

    EasyLoading.showError(ExampleTextKey.buyFailed);
    return result;
  }

  Future<SubscriptionActionResult> restore({
    required String source,
  }) async {
    EasyLoading.show();
    final result = await subscriptionService.restorePurchases(source: source);
    EasyLoading.dismiss();

    if (result.failed) {
      EasyLoading.showError(ExampleTextKey.restoreFailed);
    }
    return result;
  }
}
