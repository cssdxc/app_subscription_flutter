# app_subscription_flutter

基于 `flutter_inapp_purchase` 的 iOS 订阅通用封装。

目标是把这几件事统一收口：

- 商品拉取
- 发起购买
- 恢复购买
- 本地订阅校验
- 订阅状态和过期时间缓存
- 免费试用资格判断
- 交易回传你自己的后端
- 统一的日志和动作事件回调

这个仓库只负责“订阅核心层”。  
`loading`、`toast`、埋点、路由跳转这类 UI 行为建议放在宿主工程里，通过回调或单独的 UI delegate 处理。

## 特性

- iOS 本地校验，不依赖 `verifyReceipt + shared secret`
- 返回统一的 `SubscriptionActionResult`
- 调用方只需要配置产品 ID 和默认价格
- 后端接口通过 `transactionReporter` 回调接入
- 日志通过 `logger` 回调接入
- 流程事件通过 `actionObserver` 回调接入
- 支持宿主项目再包一层 `SubscriptionUiDelegate`

## 要求

- Flutter 项目
- iOS 15+
- 依赖 `flutter_inapp_purchase`

## 安装

```yaml
dependencies:
  app_subscription_core:
    git:
      url: https://github.com/cssdxc/app_subscription_flutter.git
      ref: main
```

更推荐你在项目稳定后改成 tag：

```yaml
dependencies:
  app_subscription_core:
    git:
      url: https://github.com/cssdxc/app_subscription_flutter.git
      ref: v0.1.0
```

## 导出内容

- `SubscriptionCoordinator`
- `SubscriptionCoordinatorConfig`
- `SubscriptionProductConfig`
- `SubscriptionActionResult`
- `SubscriptionActionEvent`
- `SubscriptionTransactionPayload`
- `IosSubscriptionHelper`
- `SubscriptionCatalog`

## 核心用法

### 1. 初始化 `SubscriptionCoordinator`

```dart
import 'package:app_subscription_core/app_subscription_core.dart';
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

### 2. 读取状态

```dart
final bool subscribed = subscriptionCoordinator.isSubscribed.value;
final bool hasFreeTrial = subscriptionCoordinator.hasFreeTrial.value;
final List<ProductSubscriptionIOS> products = subscriptionCoordinator.products.value;
```

如果你在 `GetX`、`Provider`、`Riverpod` 里使用，建议把这几个 `ValueNotifier` 再桥接到你自己的状态管理层。

### 3. 加载商品

```dart
await subscriptionCoordinator.loadProducts();

final monthProduct = subscriptionCoordinator.findProduct('subscribe_month_1');
final monthPrice = subscriptionCoordinator.findPrice(
  'subscribe_month_1',
  '\$19.99',
);
```

### 4. 发起购买

```dart
final result = await subscriptionCoordinator.purchase(
  subscriptionCoordinator.findProduct('subscribe_month_1'),
  source: 'paywall_main',
);

if (result.success) {
  // 已订阅成功
} else if (result.cancelled) {
  // 用户取消
} else {
  // 购买失败
}
```

### 5. 恢复购买

```dart
final result = await subscriptionCoordinator.restore(
  source: 'settings_restore',
);

if (result.success) {
  print('restoredCount=${result.restoredCount}');
}
```

## 推荐的宿主工程包装层

虽然可以直接在页面里调用 `SubscriptionCoordinator`，但更推荐每个项目再包一层自己的 service。

这样可以把这些内容留在业务层：

- 当前项目的产品常量
- 订阅失效后要重置的配置
- 非订阅业务限制逻辑
- 项目自己的状态管理桥接

示例思路见：

- [example/lib/subscription_service_example.dart](./example/lib/subscription_service_example.dart)

## `transactionReporter` 怎么用

这个回调就是给你接后端的，不要写死在 package 里。

```dart
Future<void> _reportTransaction(SubscriptionTransactionPayload payload) async {
  await api.userTransaction(
    payload.originalTransactionId,
    payload.currentTransactionId,
  );
}
```

如果你的后端以后要收更多字段，也可以直接从 `payload` 里扩展。

## `logger` 怎么用

推荐你在宿主项目统一接自己的 logger：

```dart
logger: (message) {
  AppLogger.d('[Subscription] $message');
},
```

这样后续所有项目的订阅日志格式都能统一。

## `actionObserver` 怎么用

这个回调适合做：

- loading 生命周期
- 埋点
- 调试排查

```dart
actionObserver: (event) {
  debugPrint(
    '[SubscriptionAction] phase=${event.phase} type=${event.type} source=${event.source}',
  );
},
```

## 推荐的 `SubscriptionUiDelegate`

这个类不放进 package，本意是让每个宿主工程用自己的 UI 框架和国际化系统实现。

如果你的项目用的是：

- `EasyLoading`
- `FirebaseAnalytics`
- `GetX .tr`

那可以直接按下面这个模式写：

```dart
class SubscriptionUiDelegate {
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
      EasyLoading.showError(TextKey.cancel.tr);
      return result;
    }

    EasyLoading.showError(TextKey.buyFailed.tr);
    return result;
  }

  Future<SubscriptionActionResult> restore({
    required String source,
  }) async {
    EasyLoading.show();
    final result = await subscriptionService.restorePurchases(source: source);
    EasyLoading.dismiss();

    if (result.failed) {
      EasyLoading.showError(TextKey.restoreFailed.tr);
    }
    return result;
  }
}
```

重点是：

- 国际化消息放宿主项目里处理
- 成功埋点放宿主项目里处理
- loading / toast 放宿主项目里处理
- package 只返回结果，不直接弹 UI

完整示例见：

- [example/lib/subscription_ui_delegate_example.dart](./example/lib/subscription_ui_delegate_example.dart)

## 一个完整接入流程

1. 在宿主工程初始化 `SharedPreferences`
2. 创建 `SubscriptionCoordinator`
3. 配置产品 ID、默认价格、`logger`、`transactionReporter`
4. 调用 `await coordinator.init()`
5. 用你自己的 service 把 `ValueNotifier` 状态桥接出去
6. 页面层通过自己的 `SubscriptionUiDelegate` 调用购买/恢复

## Example

示例代码在：

- [example/lib/subscription_service_example.dart](./example/lib/subscription_service_example.dart)
- [example/lib/subscription_ui_delegate_example.dart](./example/lib/subscription_ui_delegate_example.dart)

这些示例不是完整 App，而是“集成模板”。

## 当前边界

当前主要面向 iOS 订阅场景。

没有放进 package 的东西：

- 你的后端 API 实现
- `EasyLoading`
- 多语言文案
- 页面跳转
- 埋点平台具体实现
- 导航限制、功能解锁这类强业务逻辑

这些都应该留在宿主工程里。
