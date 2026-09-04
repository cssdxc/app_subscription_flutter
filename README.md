# app_subscription_flutter

基于 `flutter_inapp_purchase` 的 iOS 与 Android 订阅核心封装。两端共用
`SubscriptionCoordinator`、`ProductSubscription`、`Purchase` 和
`SubscriptionActionResult`，商店差异由内部 adapter 负责。

这个 package 负责：

- 拉取订阅商品与可用 offer
- 发起购买、恢复购买和前台权益刷新
- 处理 purchased、pending、grace period、suspended/account hold 等状态
- 在验证成功后完成 App Store 交易或确认 Google Play 交易
- 缓存最近一次已验证权益快照
- 使用商店原生数据在设备端验证购买，并按需回传统一交易 payload

UI、文案、路由、埋点和订阅失效后的业务处理仍由宿主工程负责。

## SDK 基线

当前版本使用：

- Dart 3.2+
- `flutter_inapp_purchase 10.6.0`
- `openiap-apple 3.4.0`
- `openiap-google 3.5.0`
- Google Play Billing Library `9.1.0`

`openiap-google 3.5.0` 直接依赖
`com.android.billingclient:billing:9.1.0`。截至 2026-08-04，Google Maven
元数据中的最新稳定版也是 `9.1.0`。项目不再额外覆盖 Billing Library
版本，避免插件与宿主使用两份不一致的版本事实源。

Android 要求：

- Android API 23+
- Java 17
- Google Play Console 中已创建订阅商品、base plan，并按需创建 offer
- 测试安装包的 application ID、签名和 Play Console 配置一致

iOS 要求：iOS 15+，并在 App Store Connect 配置自动续期订阅。

## 安装

```yaml
dependencies:
  app_subscription_core:
    git:
      url: https://github.com/cssdxc/app_subscription_flutter.git
      ref: v0.2.4
```

正式项目建议固定到明确 tag。

## 统一初始化

```dart
import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

late final SubscriptionCoordinator subscriptionCoordinator;

Future<void> setupSubscription() async {
  final preferences = await SharedPreferences.getInstance();

  subscriptionCoordinator = SubscriptionCoordinator(
    sharedPreferences: preferences,
    config: SubscriptionCoordinatorConfig(
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
      googlePlayLicenseKeyAndroid: googlePlayLicenseKey,
      transactionReporter: reportVerifiedTransaction,
      logger: logSubscription,
    ),
  );

  await subscriptionCoordinator.init();
}
```

`googlePlayLicenseKeyAndroid` 是 Play Console 提供的 Base64 编码 RSA 公钥。
Android 在本地使用 BillingClient 返回的原始购买数据和签名进行
RSASSA-PKCS1-v1_5 校验；key、原始数据或签名缺失以及校验失败时均不会授予权益，
也不会 acknowledge。iOS 使用 StoreKit 2 的已验证 current entitlements 确认交易
真实性，并使用 `subscriptionStatusIOS` 获取 Apple 维护的订阅生命周期状态。两端都不
依赖后端验证回调。

Google 官方仍建议将购买验证迁移到可信后端。本 package 按当前项目要求采用
client-only 模式，因此无法抵御已完全控制客户端进程的攻击，也无法在 App 未启动时
通过 RTDN 立即处理退款或撤销。

`transactionReporter` 是可选的交易记录回调，只在本地验证且权益有效后调用，
不承担购买真实性判断。

## 权益门禁

调用方只使用：

```dart
final bool canAccess =
    subscriptionCoordinator.accessState.value.shouldGrantAccess;
```

放行状态是 `active` 和 `gracePeriod`；`billingRetry`、`revoked`、`expired`
与 `unavailable` 均不放行。

Android 端遵循以下规则：

- `PURCHASED` 且当前订阅有效时才授予权益。
- `PENDING` 不授予权益、不确认交易，结果的 `pending` 为 `true`。
- grace period 中 Google Play 仍会返回当前购买，因此继续放行。
- suspended/account hold 不放行，并映射为 `billingRetry` 或失效状态。
- 新购通过验证后才 acknowledge；确认失败会返回失败，不能视为购买成功。

iOS 端遵循以下规则：

- `subscribed` 映射为 `active`，`inGracePeriod` 映射为 `gracePeriod`，两者继续放行。
- `inBillingRetryPeriod`、`expired` 和 `revoked` 均不放行。
- 可放行状态必须同时存在 StoreKit 已验证的 current entitlement。
- 状态查询按 `subscriptionGroupIdIOS` 去重，同一订阅组只查询一个代表商品。
- `expirationDateIOS` 和 `gracePeriodExpirationDate` 只用于展示与审计，不参与权益判断。
- 未知状态或某个订阅组查询失败时，该组返回 `unavailable`；只有其他订阅组没有可放行状态时，
  整体才会保持不可用，不会把失败误判为过期或有效。

client-only 模式会在启动、恢复和回到前台时重新查询商店状态。App 未运行期间的
退款或撤销只能在下次商店查询时生效；若未来需要实时处理，应改用 RTDN 和
`purchases.subscriptionsv2.get` 维护服务端权益。

## 商品与 offer

商品类型在两端统一为 `ProductSubscription`：

```dart
await subscriptionCoordinator.loadProducts();

final ProductSubscription? product =
    subscriptionCoordinator.findProduct('subscribe_month_1');
final String price = subscriptionCoordinator.findPrice(
  'subscribe_month_1',
  '\$19.99',
);
```

Google Play 每次购买都使用商品查询返回的 offer token。只有一个合格 offer 时会
自动选择；存在多个 base plan/offer 时必须明确选择，package 不会猜测价格方案：

```dart
final SubscriptionOffer? offer = subscriptionCoordinator.findOffer(
  'subscribe_month_1',
  basePlanIdAndroid: 'monthly',
  offerId: 'intro-trial',
);

final result = await subscriptionCoordinator.purchase(
  product,
  source: 'paywall_monthly',
  options: SubscriptionPurchaseOptions(
    offer: offer,
    obfuscatedAccountIdAndroid: accountIdHash,
  ),
);
```

当筛选条件没有唯一匹配项时，`findOffer` 返回 `null`。Android 商品存在多个 offer
但购买未传入明确 offer 时，结果 code 为 `offer-required`。

普通 iOS 自动续期订阅不需要传 `offer`；StoreKit 会自行应用符合条件的 introductory
offer。签名 promotional offer 尚未纳入本 package 的统一购买参数，传入时会显式
返回 `unsupported-offer`。

## 购买结果

```dart
final result = await subscriptionCoordinator.purchase(
  product,
  source: 'paywall_main',
);

if (result.success) {
  // 已验证并完成/确认交易
} else if (result.pending) {
  // Google Play 等待付款确认
} else if (result.cancelled) {
  // 用户取消
} else {
  // 根据 result.code 处理失败
}
```

## 恢复购买

两端使用同一个方法：

```dart
final result = await subscriptionCoordinator.restore(
  source: 'settings_restore',
);
```

iOS 会先触发 App Store sync，再查询当前购买。Android 不存在独立的“恢复”弹窗，
会直接查询当前订阅，并包含 suspended purchase 以便正确阻断权益。

如果用户主动点击恢复按钮，但宿主不希望展示自己的操作提示，可以使用静默结果模式：

```dart
await subscriptionCoordinator.restoreSilently(source: 'settings_restore');
```

`restoreSilently` 只表示宿主不主动展示操作提示，不会跳过 iOS 的 App Store sync。
它仍可能触发 Apple ID 登录弹窗，因此不能用于启动或后台自动恢复；启动和前台刷新使用本机
权益查询，不调用恢复。

## 生命周期与缓存

`init()` 会读取 6 小时内的本地权益快照、连接商店、注册购买监听、加载商品并查询本机
当前权益，不执行 App Store sync。App 回到前台时重新连接并查询当前权益。

商店查询失败时仅在 6 小时内使用最后一次已验证快照；缓存不存在或过期时返回
`unavailable`。不要直接用本地时间、Android purchase token、iOS expiration date
或 `SharedPreferences` 值自行重新判断权益。

释放资源：

```dart
await subscriptionCoordinator.dispose();
```

## 官方文档

- [Apple StoreKit 订阅状态](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/status)
- [App Store Connect Billing Grace Period](https://developer.apple.com/help/app-store-connect/manage-subscriptions/enable-billing-grace-period-for-auto-renewable-subscriptions/)

- [Google Play Billing 集成](https://developer.android.com/google/play/billing/integrate)
- [防范欺诈和滥用](https://developer.android.com/google/play/billing/security)
- [订阅生命周期](https://developer.android.com/google/play/billing/lifecycle/subscriptions)
- [BillingClient Purchase 签名字段](https://developer.android.com/reference/com/android/billingclient/api/Purchase#getSignature())
- [Google Play Billing Library 发布说明](https://developer.android.com/google/play/billing/release-notes)
- [Google Play Developer API subscriptions v2](https://developers.google.com/android-publisher/api-ref/rest/v3/purchases.subscriptionsv2)
- [Real-time Developer Notifications](https://developer.android.com/google/play/billing/rtdn-reference)
- [Google Maven Billing 元数据](https://dl.google.com/dl/android/maven2/com/android/billingclient/billing/maven-metadata.xml)

完整宿主封装示例见：

- `example/lib/subscription_service_example.dart`
- `example/lib/subscription_ui_delegate_example.dart`
