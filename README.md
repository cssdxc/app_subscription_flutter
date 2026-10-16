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

依赖版本核对日期：2026-10-16。当前版本使用：

- Flutter 3.41+ / Dart 3.11+（由 `shared_preferences 2.5.6` 要求）
- `flutter_inapp_purchase 11.0.3`
- OpenIAP Client Protocol `1.0.3`
- `openiap-apple 4.0.3`
- `openiap-google 4.0.3`
- Google Play Billing Library `9.1.0`

全部直接依赖的升级情况：

| 依赖 | 原约束 | 当前约束 | 说明 |
| --- | --- | --- | --- |
| `flutter_inapp_purchase` | `^10.6.0` | `^11.0.3` | 最新稳定版，包含主版本迁移 |
| `shared_preferences` | `^2.5.4` | `^2.5.6` | 最新稳定版，更新 SDK 下限与返回值文档 |
| `pointycastle` | `4.0.0` | `4.0.0` | 已是最新稳定版 |
| `flutter_lints` | `^6.0.0` | `^6.0.0` | 已是最新稳定版 |
| `intl` | 未直接依赖 | `^0.20.3` | 新增平均价格式化，使用 ISO 币种和本地化精度 |
| `platform` | `^3.1.6` | `>=3.1.6 <3.2.0` | 最新版为 3.2.0，但购买插件 11.0.3 要求 `<3.2.0`，保留最新兼容版 3.1.6 |

`flutter` 和 `flutter_test` 使用宿主 Flutter SDK 提供的版本。
`openiap-google 4.0.3` 的
[Maven POM](https://repo.maven.apache.org/maven2/io/github/hyochan/openiap/openiap-google/4.0.3/openiap-google-4.0.3.pom)
仍直接依赖 `com.android.billingclient:billing:9.1.0`。项目不额外覆盖
Billing Library 版本，以插件声明为准。

Android 要求：

- Android API 24+（当前解析的 `shared_preferences_android 2.4.28` 要求；购买插件自身为 API 23+）
- Java 17
- Google Play Console 中已创建订阅商品、base plan，并按需创建 offer
- 测试安装包的 application ID、签名和 Play Console 配置一致

从 10.7 起，购买插件会根据构建属性、flavor 和已连接的调试设备选择 Android 商店。
本封装的 Android adapter 只支持 Google Play；宿主请在
`android/gradle.properties` 中明确指定：

```properties
openiapStore=play
```

iOS 要求：iOS 15+，并在 App Store Connect 配置自动续期订阅。

## flutter_inapp_purchase 10.6 → 11.0.3 迁移

本次升级重点依据插件的
[完整变更记录](https://pub.dev/packages/flutter_inapp_purchase/changelog)、
[OpenIAP 发布说明](https://openiap.dev/docs/updates/releases) 与
[迁移指南](https://openiap.dev/docs/updates/migration#provider-contract-upgrade)。

- **11.0.0：稳定的 provider 协议与商店身份。** 新增社区商店 provider 支持，
  `PurchaseIOS`、`PurchaseAndroid` 手动构造时必须传 `storeId`，官方值分别为
  `apple`、`play`（Google Play）、`horizon`、`amazon`。`IapStore` 仍为固定商店枚举；
  宿主可通过 `payload.purchase.storeId` 记录商店身份。本封装继续支持 App Store 与
  Google Play，未新增其他商店 adapter。测试购买对象已补全 `storeId`。
- **11.0.0：错误与恢复行为。** 验证失败会保留具体原生错误码，不能一律按
  `purchase-verification-failed` 处理；移除旧的兑换接口，统一使用
  `openRedeemOfferCode`。`restorePurchases()` 改为调用原生同名恢复接口，再查询购买，
  相应 MethodChannel 测试替身已更新。iOS `hasActiveSubscriptions` 改为依据
  `isActive`，宽限期可能返回 `false`；本项目继续使用 StoreKit 状态与已验证权益
  共同判断，避免因此收回宽限期权益。
- **11.0.1：App 获取来源验证。** 新增 `verifyAppOwnership`，用于验证 App 是否通过
  商店合法获取，与订阅购买验证分开。本封装未调用该接口。宿主若自行实现
  `QueryResolver`，需要补上该成员；Google Play 的该功能需要服务端验证
  Play Integrity 证据，不能替代现有购买签名验证。
- **11.0.2：订阅状态、事件与确认修复。** iOS `subscriptionStatusIOS` 返回
  `subscribed`、`inGracePeriod` 等规范状态及已验证续订信息，修复之前可能返回
  `RenewalState(rawValue: 1)` 的问题。购买事件在多个插件实例之间共享；修复断线重连、
  Android 购买匹配与重复事件问题。直接 `acknowledgePurchaseAndroid` /
  `consumePurchaseAndroid` 被商店拒绝时返回 `false`，`finishTransaction` 则抛出错误，
  且只在商店确认后缓存成功。本封装继续检查 acknowledge 返回值，失败可在后续恢复中重试。
  受屏幕使用时间或 MDM 限制的 iOS 设备仍可连接、读取与恢复，购买请求才会报
  `iap-not-available`；不要仅凭连接成功判断设备可以付款。
- **11.0.3：Apple 获取来源验证的主动重试。** `verifyAppOwnership` 新增可选的
  `apple.refresh`，用于重新获取签名证据，可能触发 App Store 登录；只应由用户操作
  触发。自定义 ownership handler 需要接受可选命名参数
  `VerifyAppOwnershipOptionsIOS? apple`。本项目的启动和前台订阅查询无需接入该功能。

10.6.1–10.7.3 还包含 Android 商店选择、混淆后构建、Amazon/Horizon 与
user choice billing 修复；本项目主要受商店选择规则影响。

升级后宿主需要重新构建原生应用。Flutter 3.44+ 默认使用 Swift Package Manager
解析 Apple 原生依赖；使用 CocoaPods 的宿主需在 `flutter pub get` 后，在其 `ios/`
目录执行 `pod update openiap`，使已有锁文件中的 OpenIAP 更新到 4.0.3。
本仓库为 Dart package，没有可直接构建的 Android/iOS 宿主工程。

## 1.0.0 接入方式

本版直接替换旧接口，不保留 `SubscriptionProductConfig`、`purchase`、全局
`hasFreeTrial/isSubscribed`、`findOffer` 或字符串价格替换方法。包内不包含任何产品的
SKU、套餐业务枚举、文案、路由、埋点、提醒策略或 UI 框架依赖。

```yaml
dependencies:
  app_subscription_core:
    git:
      url: https://github.com/cssdxc/app_subscription_flutter.git
      ref: 1.0.0
```

该版本包含不兼容的接口调整，接入方应按下方示例迁移。

### 1. 配置逻辑套餐

宿主自己的枚举映射到 `SubscriptionPlan`，不需要再在购买和价格获取处判断平台。
iOS 的不同商品与 Android 同一商品下的不同 base plan 可以表示为同一逻辑套餐：

```dart
import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum Plan { monthly, yearly }

const plans = <Plan, SubscriptionPlan>{
  Plan.monthly: SubscriptionPlan(
    appStoreProductId: 'example.subscription.monthly',
    googlePlay: GooglePlayPlan(
      productId: 'example.subscription',
      basePlanId: 'monthly',
    ),
  ),
  Plan.yearly: SubscriptionPlan(
    appStoreProductId: 'example.subscription.yearly',
    googlePlay: GooglePlayPlan(
      productId: 'example.subscription',
      basePlanId: 'yearly',
      offerId: 'yearly-trial',
      fallbackToBasePlan: true,
    ),
  ),
};

final coordinator = SubscriptionCoordinator(
  sharedPreferences: await SharedPreferences.getInstance(),
  config: SubscriptionCoordinatorConfig(
    plans: plans.values.toList(),
    googlePlayLicenseKeyAndroid: googlePlayLicenseKey,
    transactionReporter: reportTransaction,
    logger: logSubscription,
  ),
);
await coordinator.init();
```

`offerId: null` 只选择普通 base plan；指定 offer 缺失时默认返回
`SubscriptionFailureCode.offerUnavailable`。只有显式设置 `fallbackToBasePlan: true`
才允许按同一 base plan 的普通价格购买。回退后展示也会使用该普通价格。
多重匹配返回 `offerRequired`，不按最低价、首项或商品首期价格猜测。

`purchasePlan` 接收配置中的套餐对象，拒绝购买未注册套餐。
Android 请求按当前平台去重 product ID；两个套餐共用一个商品只查询一次。
单平台套餐可以只配置对应映射，在另一平台返回 `invalidProductPlatform`。

### 2. 展示价格、平均价与试用资格

```dart
final yearly = coordinator.planDetails(plans[Plan.yearly]!);
final displayPrice = yearly.displayPrice;
final average = yearly.price?.averagePrice(
  divisor: 52,
  locale: 'zh_CN',
  unitLabel: '周',
  currencySymbol: 'US＄',
);
final canBuy = yearly.canPurchase;
final trialEligibility = yearly.trialEligibility;
final trialPeriod = yearly.trialPeriod;
```

界面直接监听 `coordinator.plans`（`ValueListenable<List<SubscriptionPlanDetails>>`），
商品、价格和资格变化会发布新快照。`planDetails` 也可在商品未加载时同步读取配置兜底。
宿主无须再转发通知器。

价格规则：

- `displayPrice` 保留商店格式；数值不可用时仍可展示商店明确返回的价格文案。
  缺少可展示的商店价格时使用套餐的 `fallbackPrice`，默认空字符串。
- iOS 正常价来自商品的 `price/currency/displayPrice`。
- Android 正常续费价来自所选 offer 唯一的 `INFINITE_RECURRING` 阶段。
  只有一个 `NON_RECURRING` 阶段时表示预付价。两者通过 `SubscriptionRecurrenceMode` 区分。
- 试用零元和首期折扣不能用作续费价。不认识或有歧义的计费阶段不会产生数值价格；
  原始阶段仍可从 `details.offer` 获取，交由宿主明确处理。
- 平均价直接使用商店数值，按 `intl` 的币种小数位和宿主 locale 格式化，不解析或替换展示字符串。
  默认显示 ISO 货币代码；可显式传入货币符号、小数位。JPY 的零位、KWD 的三位均遵循币种规则。
- 除数必须由宿主明确给出。年价除以 52 是展示约定，不是按每周扣款，也不能据此计算到期时间。
  没有真实数值价格时 `price == null`，不计算兜底字符串的平均价。

试用规则：

- `SubscriptionTrialEligibility` 区分 `unknown/eligible/ineligible`。
  `hasFreeTrial` 仅在明确 `eligible` 时为真。
- Apple 必须存在免费 introductory offer，再按订阅组调用
  `isEligibleForIntroOfferIOS`。所有订阅组分别查询，同组去重；缺少组信息或查询失败保持未知。
  不通过“没有当前购买”推断“没有使用过试用”。
- Google 按**已选 offer**中的免费有限计费阶段判断，不聚合其他套餐的优惠。
  `eligible` 表示本次商品查询返回的所选优惠包含免费阶段；开发者自行定义的额外资格规则
  由宿主在选择套餐前执行，最终能否成交仍由商店决定。
- `trialPeriod` 是商店定义的免费总周期，不代表资格保证。
  Apple 使用 `period × periodCount`；Google 使用 `billingPeriod × billingCycleCount`。
  使用官方 `SubscriptionPeriodUnit` 保留日、周、月、年，不将一个月假定为 30 天。

### 3. 购买、恢复与明确的结果分类

```dart
final result = await coordinator.purchasePlan(
  plans[Plan.yearly]!,
  source: 'paywall',
  options: SubscriptionPurchaseOptions(
    appAccountTokenIOS: accountUuid,
    obfuscatedAccountIdAndroid: accountIdHash,
  ),
);

switch (result.outcome) {
  case SubscriptionActionOutcome.success:
    // 已验证并完成或确认本次购买。
    break;
  case SubscriptionActionOutcome.cancelled:
    // 用户取消，通常无需错误提示。
    break;
  case SubscriptionActionOutcome.pending:
    // 等待付款或外部批准，不能按本次购买授予权益。
    break;
  case SubscriptionActionOutcome.failure:
    // 使用 result.failureCode 或官方 result.storeErrorCode 枚举决定提示。
    break;
}

final restored = await coordinator.restore(source: 'settings');
```

`failureCode` 只表示封装自身错误；`storeErrorCode` 保留插件官方 `ErrorCode`。
`code/message` 供诊断或上报，不能作为业务分支。
购买完成、取消、等待与失败由单一 `outcome` 派生，不会出现多份布尔状态互相矛盾。
`DeferredPayment/Pending` 商店错误也归为等待；`failed` 只表示 `failure`。

`restore` 成功仅表示恢复流程完成，可能 `restoredCount == 0`。
**权益门禁始终读取 `coordinator.accessState.value.shouldGrantAccess`。**
连接失败会返回 `storeUnavailable`，不能以缓存权益冒充本次商店恢复成功。

iOS 恢复调用插件原生 `restorePurchases` 再查询购买，可能触发 Apple ID 登录。
`restore(silent: true)` 只关闭宿主的阻断 loading 和标记事件静默，不阻止系统弹窗；
不用于启动或后台自动恢复。Android 直接查询当前购买，并包含 suspended 购买以阻断其权益。

普通 iOS 自动续期订阅由 StoreKit 自动应用符合资格的 introductory offer。
本接口没有实现需要服务端签名的 promotional offer，显式传入时返回 `unsupportedOffer`。
通常使用 `purchasePlan`；只有明确需要自行管理商店商品与 offer 时才使用低层
`purchaseProduct`。`purchasePlan` 不允许通过 `options.offer` 覆盖配置中的选择。

### 4. 加载态与生命周期

直接绑定 `coordinator.activity`：

| 属性 | 含义 |
| --- | --- |
| `isLoading` | 初始化、商品/资格/权益查询、购买、恢复或后台交易处理中 |
| `isBusy` | 正在购买、恢复或处理交易，不能再发起另一个购买或恢复 |
| `showBlockingLoading` | 非静默的购买或恢复，适合绑定宿主阻断式 loading |
| `isLoadingProducts` | 正在查询商品，适合套餐区域的占位样式 |
| `productId` | 当前用户购买关联的商品 |

库通过计数与 `finally` 结束状态，不依赖 UI 层成对调用 show/dismiss。
后台查询与静默恢复不自动遮挡界面；UI 组件、文案和失败提示由宿主实现。
重复调用初始化、商品加载、试用资格查询或权益刷新会共用进行中的 Future。
`loadProducts` 返回查询是否成功，成功时列表仍可能为空。购买前与回到前台会重新查询商品，
避免用长期缓存的 Google Play 商品详情和优惠令牌发起购买；重新查询失败时不发送购买请求。
购买事件排队处理，不会因另一个事件验证中而直接丢弃。

`actionObserver` 提供购买、恢复和事件同步的成对 started/finished 事件，保留调用方
传入的 `source`，可供埋点使用；被互斥规则直接拒绝的操作不会伪造开始事件。
日志、观察器和交易回传回调失败不会改变交易结果。

`init` 读取六小时内的权益缓存、注册生命周期与购买监听、连接商店、加载套餐、查询权益，
不触发 App Store 恢复。回到前台时重新查询商店；离线只采用六小时内的快照，
未来时间、损坏和超时快照不采用。缓存有效期仅用于快照新鲜度，不替代商店生命周期判断。

由持有协调器的宿主释放资源：

```dart
await coordinator.dispose();
```

释放会取消事件与生命周期监听，并完成等待中的购买 Future，返回 `disposed`。
释放后到达的异步查询不会再写入通知器。

## 权益验证与职责边界

两端维持设备端验证：Apple 使用 StoreKit 2 的已验证权益与订阅状态；Google 使用
Play Console RSA 公钥验证原始购买签名，并按购买令牌与商品关联当前订阅。
只有验证且权益有效后才完成或确认交易。Android acknowledge 返回 false 时返回
`acknowledgementFailed`，可在后续恢复中重试。
`transactionReporter` 是验证后的记录回调，不是授权依据，也不提供持久化重试队列。

Apple `subscribed/inGracePeriod` 结合已验证当前权益授予访问；宽限期不能只看插件的
`isActive` 布尔值。`inBillingRetryPeriod/expired/revoked` 不授予访问。未知状态仅可
使用 StoreKit 已验证且 `isActive` 的权益降级，日期字段不参与推测。
Google 的 pending、suspended/account hold 不授予新权益，也不确认待付款交易。

退款、撤销等在启动、恢复或前台查询时更新；需要 App 未运行时同步时，应由宿主接入
服务端通知和商店服务端验证，当前设备端封装不承担该职责。

| 文件/类型 | 单一职责 |
| --- | --- |
| `subscription_configuration.dart` | 套餐集合与宿主回调配置 |
| `SubscriptionPlan/GooglePlayPlan` | 逻辑套餐到商店标识的映射 |
| `SubscriptionCatalog` | 精确解析商品、优惠、正常价与试用周期 |
| `SubscriptionPrice` | 数值价格、官方周期和本地化平均价 |
| `SubscriptionOperationState` | 只读工作快照与 loading 派生 |
| `SubscriptionCoordinator` | 初始化、事件队列、购买与恢复编排 |
| `SubscriptionStoreAdapter` | 平台适配契约及购买账户参数 |
| `app_store_subscription_adapter.dart` | StoreKit 请求、验证、完成交易与权益映射 |
| `google_play_subscription_adapter.dart` | Play 请求、签名验证、确认与权益映射 |
| `SubscriptionEntitlementCache` | 内部缓存序列化与新鲜度检查 |

现有产品集成可以移除的重复代码：平台分支、商品去重、base plan/offer 筛选、
计费阶段反向查价、平均价拼接、全局试用资格猜测、购买互斥、loading 请求标志、
初始化合并与状态转发。

宿主保留：自己的套餐枚举和 SKU 配置、兜底价格值、本地化文案、业务资格规则、
账号标识生成、埋点、支付墙、路由、试用提醒和交易记录 API。

## 依据与验证

除上方版本说明外，封装语义对应以下官方文档与固定版本源码：

- [flutter_inapp_purchase 11.0.3](https://pub.dev/packages/flutter_inapp_purchase/versions/11.0.3)
  中的 `types.dart`、`flutter_inapp_purchase.dart`
- [OpenIAP Apple 4.0.3 字段转换](https://github.com/hyodotdev/openiap/blob/4.0.3/packages/apple/Sources/Helpers/StoreKitTypesBridge.swift)
- [OpenIAP Google 4.0.3 源码包](https://repo.maven.apache.org/maven2/io/github/hyochan/openiap/openiap-google/4.0.3/openiap-google-4.0.3-sources.jar)
  中的 `BillingConverters.kt`
- [统一 SubscriptionOffer 字段](https://openiap.dev/docs/types/subscription-offer)
- [Apple 试用资格查询](https://openiap.dev/docs/apis/ios/is-eligible-for-intro-offer-ios)
- [StoreKit 订阅状态](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/status)
- [Google PricingPhase](https://developer.android.com/reference/com/android/billingclient/api/ProductDetails.PricingPhase)
- [Google RecurrenceMode](https://developer.android.com/reference/com/android/billingclient/api/ProductDetails.RecurrenceMode)
- [Google 订阅生命周期](https://developer.android.com/google/play/billing/lifecycle/subscriptions)
- [Google 购买验证建议](https://developer.android.com/google/play/billing/security)

```sh
flutter pub get
flutter analyze
flutter test
```

测试覆盖价格与币种精度、多 base plan、优惠回退、试用分组查询、真实 Dart 插件的
MethodChannel 参数与事件解析、取消/待付款/失败/释放、并发 loading、权益缓存及两端验证。
本仓库没有原生宿主；商店沙盒和真机购买需要在宿主工程中验证。

完整示例：
[服务装配](example/lib/subscription_service_example.dart) 与
[界面绑定](example/lib/subscription_ui_delegate_example.dart)。
