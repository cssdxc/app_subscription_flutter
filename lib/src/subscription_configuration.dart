import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

import 'subscription_action_result.dart';
import 'subscription_plan.dart';
import 'subscription_snapshot.dart';
import 'subscription_store_adapter.dart';
import 'subscription_transaction.dart';

/// 接收订阅模块诊断日志。
typedef SubscriptionLogger = void Function(String message);

/// 独立记录通过验证且已完成商店交易的载荷，不阻塞购买或恢复结果。
typedef SubscriptionTransactionReporter =
    Future<void> Function(SubscriptionTransactionPayload payload);

/// 观察购买、恢复和同步操作的开始与结束事件。
typedef SubscriptionActionObserver =
    void Function(SubscriptionActionEvent event);

/// 查询当前订阅；productIds 为 null 时查询本 App 全部订阅。
typedef ActiveSubscriptionQuery =
    Future<List<ActiveSubscription>> Function(List<String>? productIds);

/// 宿主服务端验证后的商店快照；需验证账号归属、交易、当前与未来 line item。
/// 不得将未验证的客户端购买或业务会员布尔值直接转换成有效快照。
typedef VerifiedSubscriptionQuery =
    Future<SubscriptionSnapshot> Function(
      SubscriptionVerificationRequest request,
    );

/// 服务端验证请求；购买事件包含原始购买，刷新时 purchase 为空。
class SubscriptionVerificationRequest {
  SubscriptionVerificationRequest({
    required this.store,
    required List<String>? productIds,
    this.purchase,
  }) : productIds = productIds == null ? null : List.unmodifiable(productIds);

  final IapStore store;

  /// null 表示本 App 全部订阅，空列表表示不查询任何商品。
  final List<String>? productIds;
  final Purchase? purchase;
}

/// 订阅协调器的商品、验证和回调配置。
class SubscriptionCoordinatorConfig {
  /// 创建订阅协调器配置。
  const SubscriptionCoordinatorConfig({
    required this.plans,
    this.subscriptionProductIds,
    this.accessStateStorageKey,
    this.googlePlayLicenseKeyAndroid = '',
    this.logger,
    this.transactionReporter,
    this.actionObserver,
    this.activeSubscriptionQuery,
    this.verifiedSubscriptionQuery,
    this.subscriptionStatusQueryIOS,
    this.purchaseTimeout = const Duration(minutes: 2),
  });

  /// 只限制调用方等待，不取消商店交易或重试付款。
  final Duration purchaseTimeout;

  /// 当前提供购买和价格展示的套餐，不需要加入历史商品。
  final List<SubscriptionPlan> plans;

  /// 当前商店的权益识别范围，独立于在售套餐；null 查询本 App 全部订阅。
  /// 仅需识别部分订阅时显式传入商品 ID，空列表不授予订阅权益。
  final List<String>? subscriptionProductIds;

  /// 权益快照在 SharedPreferences 中的自定义存储键。
  final String? accessStateStorageKey;

  /// Play Console 提供的 Base64 编码 RSA 公钥。
  final String googlePlayLicenseKeyAndroid;

  /// 可选的诊断日志回调。
  final SubscriptionLogger? logger;

  /// 可选的交易记录回调；异常仅记日志，不参与授权或重试。
  final SubscriptionTransactionReporter? transactionReporter;

  /// 可选的订阅操作生命周期观察器。
  final SubscriptionActionObserver? actionObserver;

  /// 配置后作为权益查询来源；失败不回退到权限信息较少的设备端查询。
  /// Android 显式替换需要此回调返回官方 API 的已验证 line item。
  final VerifiedSubscriptionQuery? verifiedSubscriptionQuery;

  /// 可选的当前订阅查询替身；未提供时直接查询商店。
  final ActiveSubscriptionQuery? activeSubscriptionQuery;

  /// 可选的 StoreKit 2 订阅状态查询替身；未提供时直接调用插件。
  final SubscriptionStatusQueryIOS? subscriptionStatusQueryIOS;
}
