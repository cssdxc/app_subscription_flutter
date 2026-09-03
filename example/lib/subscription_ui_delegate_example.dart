import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:flutter/foundation.dart';

import 'subscription_service_example.dart';

/// 示例界面使用的本地化文案键。
class ExampleTextKey {
  /// 用户取消购买时展示的文案。
  static String get cancel => 'Cancelled';

  /// 购买失败时展示的文案。
  static String get buyFailed => 'Purchase failed';

  /// 恢复失败时展示的文案。
  static String get restoreFailed => 'Restore failed';
}

/// 演示界面层如何调用订阅服务并处理操作结果。
class ExampleSubscriptionUiDelegate {
  /// 创建示例订阅界面代理。
  ExampleSubscriptionUiDelegate(this.subscriptionService);

  /// 界面使用的订阅服务。
  final ExampleSubscriptionService subscriptionService;

  /// 购买调用方指定的订阅商品并处理结果提示。
  Future<SubscriptionActionResult> purchase({
    required ProductSubscription? product,
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

  /// 购买示例月订阅并处理结果提示。
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

  /// 恢复已有购买并处理结果提示。
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
