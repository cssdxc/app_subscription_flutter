# app_subscription_flutter

基于 `flutter_inapp_purchase` 的 iOS 订阅核心封装。

这个 package 只负责订阅核心流程：

- 商品拉取
- 发起购买
- 恢复购买
- 本地收据校验
- 原生活跃权益同步
- 订阅权益门禁状态缓存
- 免费试用资格判断
- 交易信息回传宿主工程
- 日志和流程事件回调

UI 行为不放在 package 里。`loading`、`toast`、埋点、路由跳转、多语言文案、订阅失效后的业务处理，都应由宿主工程通过 service 或 UI delegate 接入。

## 要求

- Flutter 项目
- iOS 15+
- `flutter_inapp_purchase`
- `shared_preferences`

## 安装

```yaml
dependencies:
  app_subscription_core:
    git:
      url: https://github.com/cssdxc/app_subscription_flutter.git
      ref: main
```

项目稳定后建议改成固定 tag：

```yaml
dependencies:
  app_subscription_core:
    git:
      url: https://github.com/cssdxc/app_subscription_flutter.git
      ref: v0.1.0
```

## 初始化

```dart
import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

late final SubscriptionCoordinator subscriptionCoordinator;

Future<void> setupSubscription() async {
  final prefs = await SharedPreferences.getInstance();

  subscriptionCoordinator = SubscriptionCoordinator(
    sharedPreferences: prefs,
    config: SubscriptionCoordinatorConfig(
      yearlyProductId: 'subscribe_year_1',
      products: const [
        SubscriptionProductConfig(
          id: 'subscribe_week_1',
          defaultPrice: '\$9.99',
        ),
        SubscriptionProductConfig(
          id: 'subscribe_month_1',
          defaultPrice: '\$19.99',
        ),
        SubscriptionProductConfig(
          id: 'subscribe_year_1',
          defaultPrice: '\$49.99',
        ),
      ],
      logger: _logSubscription,
      transactionReporter: _reportTransaction,
      actionObserver: _observeSubscriptionAction,
    ),
  );

  await subscriptionCoordinator.init();
}

void _logSubscription(String message) {
  debugPrint('[Subscription] $message');
}

Future<void> _reportTransaction(SubscriptionTransactionPayload payload) async {
  await api.userTransaction(
    payload.originalTransactionId,
    payload.currentTransactionId,
  );
}

void _observeSubscriptionAction(SubscriptionActionEvent event) {
  debugPrint(
    '[SubscriptionAction] phase=${event.phase} type=${event.type} source=${event.source}',
  );
}
```

`init()` 会完成这些事情：

- 先读取 6 小时内的本地权益快照
- 建立 StoreKit / `flutter_inapp_purchase` 连接
- 注册购买事件监听
- 静默恢复当前购买
- 加载商品
- 注册 App 前后台监听

如果首次启动时 iOS 网络权限尚未确认，StoreKit 暂不可用，`init()` 不会卡死。coordinator 会先使用可用缓存或给出 `unavailable`，并在 App 回到前台时自动重连、刷新权益和补加载商品。

## 判断是否放行

调用方只使用 `accessState.shouldGrantAccess` 判断是否给用户订阅权益：

```dart
final SubscriptionAccessState state =
    subscriptionCoordinator.accessState.value;

if (state.shouldGrantAccess) {
  // 放行订阅权益
} else {
  // 拦截，展示订阅页或恢复购买入口
}
```

监听状态变化：

```dart
subscriptionCoordinator.accessState.addListener(() {
  final state = subscriptionCoordinator.accessState.value;

  if (state.shouldGrantAccess) {
    // 放行
  } else {
    // 拦截
  }
});
```

不要用本地时间、`expirationDateIOS`、`SharedPreferences` 里的缓存值作为门禁依据。`isSubscribed` 只保留给旧代码兼容，新代码应使用：

```dart
subscriptionCoordinator.accessState.value.shouldGrantAccess
```

## 状态含义

```dart
enum SubscriptionAccessStatus {
  active,
  gracePeriod,
  billingRetry,
  revoked,
  expired,
  unavailable,
}
```

放行状态：

- `active`
- `gracePeriod`

拦截状态：

- `billingRetry`
- `revoked`
- `expired`
- `unavailable`

iOS 侧以 `flutter_inapp_purchase.getActiveSubscriptions(productIds)` 返回的原生活跃权益作为事实源。原生查询失败时，6 小时内使用最后一次已验证快照；缓存不存在或超过 6 小时则返回 `unavailable`。

## 商品、购买和恢复

加载商品：

```dart
await subscriptionCoordinator.loadProducts();

final product = subscriptionCoordinator.findProduct('subscribe_month_1');
final price = subscriptionCoordinator.findPrice(
  'subscribe_month_1',
  '\$19.99',
);
```

发起购买：

```dart
final result = await subscriptionCoordinator.purchase(
  subscriptionCoordinator.findProduct('subscribe_month_1'),
  source: 'paywall_main',
);

if (result.success) {
  // 购买成功
} else if (result.cancelled) {
  // 用户取消
} else {
  // 购买失败
}
```

恢复购买：

```dart
final result = await subscriptionCoordinator.restore(
  source: 'settings_restore',
);

if (result.success) {
  // 恢复成功或当前权益有效
} else {
  // 恢复失败
}
```

静默恢复：

```dart
await subscriptionCoordinator.restoreSilently(source: 'app_bootstrap');
```

## 推荐封装方式

宿主工程可以再包一层自己的 service，用来集中产品 ID、状态桥接和后端接入：

```dart
class AppSubscriptionService {
  final ValueNotifier<SubscriptionAccessState> accessState =
      ValueNotifier<SubscriptionAccessState>(
    const SubscriptionAccessState(
      status: SubscriptionAccessStatus.unavailable,
      evaluatedAtMs: 0,
      note: 'not evaluated',
    ),
  );

  late final SubscriptionCoordinator coordinator;

  bool get shouldGrantAccess => accessState.value.shouldGrantAccess;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();

    coordinator = SubscriptionCoordinator(
      sharedPreferences: prefs,
      config: SubscriptionCoordinatorConfig(
        yearlyProductId: 'subscribe_year_1',
        products: const [
          SubscriptionProductConfig(
            id: 'subscribe_month_1',
            defaultPrice: '\$19.99',
          ),
          SubscriptionProductConfig(
            id: 'subscribe_year_1',
            defaultPrice: '\$49.99',
          ),
        ],
        logger: (message) {
          debugPrint('[Subscription] $message');
        },
        transactionReporter: (payload) async {
          await api.userTransaction(
            payload.originalTransactionId,
            payload.currentTransactionId,
          );
        },
      ),
    );

    coordinator.accessState.addListener(() {
      accessState.value = coordinator.accessState.value;
    });

    await coordinator.init();
  }

  Future<SubscriptionActionResult> purchaseMonthly() {
    return coordinator.purchase(
      coordinator.findProduct('subscribe_month_1'),
      source: 'paywall_monthly',
    );
  }

  Future<SubscriptionActionResult> restore() {
    return coordinator.restore(source: 'settings_restore');
  }

  Future<void> dispose() {
    accessState.dispose();
    return coordinator.dispose();
  }
}
```

完整示例见：

- [example/lib/subscription_service_example.dart](./example/lib/subscription_service_example.dart)
- [example/lib/subscription_ui_delegate_example.dart](./example/lib/subscription_ui_delegate_example.dart)

## 生命周期

`SubscriptionCoordinator` 会监听 `AppLifecycleState.resumed`。App 从后台回到前台时会自动：

- 重试 StoreKit 连接
- 刷新 `accessState`
- 在商品列表为空时补加载商品

购买、恢复、前台刷新有并发保护。调用方不需要在页面生命周期里重复刷新订阅状态。

释放：

```dart
await subscriptionCoordinator.dispose();
```

## 宿主工程负责的内容

这些内容不属于 package：

- 后端 API 的具体实现
- loading / toast
- 页面跳转
- 埋点平台
- 多语言文案
- 功能解锁后的业务逻辑
- 订阅失效后的业务重置逻辑
