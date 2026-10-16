import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

import 'subscription_action_result.dart';
import 'subscription_plan.dart';
import 'subscription_store_adapter.dart';
import 'subscription_transaction.dart';

/// 接收订阅模块诊断日志。
typedef SubscriptionLogger = void Function(String message);

/// 接收通过验证且已获得权益的交易载荷。
typedef SubscriptionTransactionReporter =
    Future<void> Function(SubscriptionTransactionPayload payload);

/// 观察购买、恢复和同步操作的开始与结束事件。
typedef SubscriptionActionObserver =
    void Function(SubscriptionActionEvent event);

/// 查询指定商品对应的当前订阅；主要用于测试或替换默认商店查询。
typedef ActiveSubscriptionQuery =
    Future<List<ActiveSubscription>> Function(List<String>? productIds);

/// 订阅协调器的商品、验证和回调配置。
class SubscriptionCoordinatorConfig {
  /// 创建订阅协调器配置。
  const SubscriptionCoordinatorConfig({
    required this.plans,
    this.accessStateStorageKey,
    this.googlePlayLicenseKeyAndroid = '',
    this.logger,
    this.transactionReporter,
    this.actionObserver,
    this.activeSubscriptionQuery,
    this.subscriptionStatusQueryIOS,
  });

  /// 应用支持的逻辑套餐及其各平台映射。
  final List<SubscriptionPlan> plans;

  /// 权益快照在 SharedPreferences 中的自定义存储键。
  final String? accessStateStorageKey;

  /// Play Console 提供的 Base64 编码 RSA 公钥。
  final String googlePlayLicenseKeyAndroid;

  /// 可选的诊断日志回调。
  final SubscriptionLogger? logger;

  /// 可选的已验证交易回传回调。
  final SubscriptionTransactionReporter? transactionReporter;

  /// 可选的订阅操作生命周期观察器。
  final SubscriptionActionObserver? actionObserver;

  /// 可选的当前订阅查询替身；未提供时直接查询商店。
  final ActiveSubscriptionQuery? activeSubscriptionQuery;

  /// 可选的 StoreKit 2 订阅状态查询替身；未提供时直接调用插件。
  final SubscriptionStatusQueryIOS? subscriptionStatusQueryIOS;
}
