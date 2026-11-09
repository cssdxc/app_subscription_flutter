# app_subscription_flutter

基于 `flutter_inapp_purchase` 的 iOS 与 Android 订阅核心封装。两端共用
`SubscriptionCoordinator`、`ProductSubscription`、`Purchase` 和
`SubscriptionActionResult`，商店差异由内部 adapter 负责。

这个 package 负责：

- 拉取订阅商品与可用 offer
- 发起购买、恢复购买和前台权益刷新
- 处理已购买、待付款、宽限期与商店明确返回的暂停等状态
- 在验证成功后完成 App Store 交易或确认 Google Play 交易
- 缓存最近一次已验证权益快照
- 验证商店购买，支持宿主服务端返回权威订阅快照，并独立回传交易 payload

业务功能权限、UI、文案、路由和埋点由宿主负责。插件不定义业务档位，不复制 Apple 等级配置。
当前权益与未来续订目标分别输出，多种商品可以同时有效。

## SDK 基线

依赖版本核对日期：2026-10-16。当前版本使用：

- Flutter 3.41+ / Dart 3.11+（由 `shared_preferences 2.5.6` 要求）
- `flutter_inapp_purchase 11.0.3`
- OpenIAP Client Protocol `1.0.3`
- `openiap-apple 4.0.3`
- `openiap-google 4.0.3`
- Google Play Billing Library `9.1.0`

直接依赖基线（历史升级记录，非实时版本查询）：

| 依赖 | 原约束 | 当前约束 | 说明 |
| --- | --- | --- | --- |
| `flutter_inapp_purchase` | `^10.6.0` | `11.0.3` | 固定已核对的数据契约；升级需重新验证原生字段 |
| `shared_preferences` | `^2.5.4` | `^2.5.6` | 更新 SDK 下限与返回值文档 |
| `pointycastle` | `4.0.0` | `4.0.0` | RSA 验证 |
| `flutter_lints` | `^6.0.0` | `^6.0.0` | 静态检查 |
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

## 接入方式（当前源码）

接入方配置套餐并直接持有协调器。包内不包含产品专属的 SKU、套餐业务枚举、
文案、路由、埋点、提醒策略或 UI 组件。

当前版本为 `2.0.2`，使用固定 Git 标签接入：

```yaml
dependencies:
  app_subscription_core:
    git:
      url: https://github.com/cssdxc/app_subscription_flutter.git
      ref: 2.0.2
```

从旧版升级需要迁移 `accessState` 和操作结果分支，见
[订阅变更与迁移说明](docs/subscription-tier-change-plan.md)。

### 1. 配置逻辑套餐

宿主自己的枚举映射到 `SubscriptionPlan`，只配置当前提供购买的套餐，不需要加入历史商品。
iOS 的不同商品与 Android 同一商品下的不同 base plan 可以表示为同一逻辑套餐：

```dart
import 'package:app_subscription_core/app_subscription_core.dart';

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
  config: SubscriptionCoordinatorConfig(
    plans: plans.values.toList(),
    googlePlayLicenseKeyAndroid: googlePlayLicenseKey,
    transactionReporter: reportTransaction,
    logger: logSubscription,
  ),
);
await coordinator.init();
```

构造函数同步完成装配，缓存由库延迟创建；测试或已有存储实例可通过可选的
`sharedPreferences` 参数注入。宿主直接持有 `SubscriptionCoordinator`，
无须再创建转发状态和操作的服务类。若使用 Provider，只负责创建实例、注入回调和释放资源。
`init()` 是唯一初始化入口，缓存读取由内部管理；无需另行等待就绪状态或单独加载缓存。

Android 普通套餐只配置 `productId` 和 `basePlanId`，不需要填写 `offerId`。
指定优惠时，在对应套餐中配置一次 `offerId`；页面展示和购买都不需要再传优惠标识。
同一商品有多个优惠时，可以分别配置成套餐，例如“月度普通价”和“月度首购优惠”，
二者使用相同的 `productId/basePlanId`，仅后者填写对应的 `offerId`。
库不根据价格或返回顺序自动选择优惠；宿主决定向用户展示哪些套餐。

`offerId: null` 只选择普通 base plan；指定 offer 缺失时默认返回
`SubscriptionFailureCode.offerUnavailable`。只有显式设置 `fallbackToBasePlan: true`
才允许按同一 base plan 的普通价格购买。回退后展示也会使用该普通价格。
多重匹配返回 `offerRequired`，不按最低价、首项或商品首期价格猜测。

`purchasePlan` 接收配置中的套餐对象，拒绝购买未注册套餐。
Android 请求按当前平台去重 product ID；两个套餐共用一个商品只查询一次。
单平台套餐可以只配置对应映射，在另一平台返回 `invalidProductPlatform`。

权益识别独立于在售套餐。`subscriptionProductIds` 默认 `null`，查询本 App 全部订阅，
包括仍有效的历史商品；历史商品不会加入套餐或价格展示列表。单一权益 App 直接监听：

```dart
final hasPaidAccess = coordinator.accessState.value.shouldGrantAccess;
```

不需要维护历史 SKU 白名单。插件仍验证订阅及当前状态，不将普通内购、待付款或已失效记录授权。
需要限定识别范围时，可以显式设置当前商店的 `subscriptionProductIds`；该过滤也作用于
恢复、服务端快照和缓存，不随支付墙套餐的变化而改变。空列表表示不识别任何订阅。
只查询权益时可传 `plans: []`，不会请求空商品价格列表；购买仍要求目标套餐已注册。

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
final trialDays = yearly.trialDays;
```

界面直接监听 `coordinator.plans`（`ValueListenable<List<SubscriptionPlanDetails>>`），
商品、价格和资格变化会发布新快照。`planDetails` 也可在商品未加载时同步读取配置兜底。
宿主无须再转发通知器。
商品刷新时保留上一份完整数据，待新商品及试用资格查询完成后一起发布，
不先发布临时的“资格未知”。实际查询失败仍更新为未知，不继续承诺试用。

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
  金额与单位使用 `/` 直接连接，例如 `$1.00/week`，保留币种本地化格式本身的间距。
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
- `trialDays` 仅在明确符合试用资格且周期能精确按天表示时返回总天数：日直接取值，周乘以 7。
  月、年、未知单位、缺失或无效周期，以及资格未知或不符合时返回 `null`。
  `null` 不等于没有试用资格；资格仍读取 `trialEligibility/hasFreeTrial`，月、年文案使用 `trialPeriod`。

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
    // effect 为 applied（当前生效）或 scheduled（已确认预约）。
    // 功能门禁始终读取 accessState，不根据 success 直接放行。
    break;
  case SubscriptionActionOutcome.cancelled:
    // 用户取消，通常无需错误提示。
    break;
  case SubscriptionActionOutcome.pending:
    // 等待付款或外部批准，不能按本次购买授予权益。
    break;
  case SubscriptionActionOutcome.unconfirmed:
    // 尚无足够证据；允许刷新，不自动重试付款。
    break;
  case SubscriptionActionOutcome.failure:
    // 使用 result.failureCode 或官方 result.storeErrorCode 枚举决定提示。
    break;
}

final restored = await coordinator.restore(source: 'settings');
```

`failureCode` 只表示封装自身错误；`storeErrorCode` 保留插件官方 `ErrorCode`。
`code/message` 供诊断或上报，不能作为业务分支。
`numericCode` 是本库统一定义的固定数字错误码，并非 Apple 或 Google 的原生响应值。
宿主直接读取该属性，并自行组合本地化文案，例如 `取消 (1001)`，无需再维护映射表。
商店错误为 1001–1999，封装错误为 2001–2999；取消为 1001，未知商店错误为 1999，
无具体分类的失败为 2999。成功、待付款和未确认返回 `null`。失败同时包含两类错误时优先使用封装原因。
完整编号见[数字错误码](docs/error-codes.md)；编号显式固定，不随枚举顺序变化，业务判断继续使用枚举。
商品查询及交易处理遇到 `PurchaseError` 时保留原错误码，不统一改为连接失败。
未查到有效权益返回 `subscriptionInactive`；StoreKit 分组状态查询失败返回
`storeQueryFailed`，不把查询异常解释为订阅到期。
购买完成、取消、等待与失败由单一 `outcome` 派生，不会出现多份布尔状态互相矛盾。
`DeferredPayment/Pending` 商店错误也归为等待；`failed` 只表示 `failure`。

`restore` 成功仅表示恢复流程完成，可能 `restoredCount == 0`。
**权益门禁始终读取 `coordinator.accessState.value.shouldGrantAccess`。**
连接失败会返回 `storeUnavailable`，不能以缓存权益冒充本次商店恢复成功。

iOS 恢复调用插件原生 `restorePurchases` 再查询购买，可能触发 Apple ID 登录。
`restore(silent: true)` 仅影响工作快照中的提示标志和操作事件，不调用宿主 UI，也不阻止系统弹窗；
不用于启动或后台自动恢复。Android 直接查询当前购买，并包含 suspended 购买以阻断其权益。

购买统一使用 `purchasePlan`，只传配置中选中的套餐；账户关联等参数通过
`SubscriptionPurchaseOptions` 提供，优惠由套餐解析，不接受购买时覆盖。
普通 iOS 自动续期订阅由 StoreKit 自动应用符合资格的 introductory offer，无需配置
Android 的 `offerId`。本封装未提供需要签名的 App Store promotional offer 购买能力。

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
插件只提供只读状态，不提供 loading Widget、弹层、遮罩或 show/dismiss 回调。
`showBlockingLoading` 是供宿主选择使用的状态提示，不会自动显示任何界面。
宿主在自己的展示层监听 `activity`，决定采用按钮转圈、页面占位还是全屏遮罩，
并负责颜色、尺寸、动画、文案、交互拦截和失败提示。
重复调用初始化、商品加载、试用资格查询或权益刷新会共用进行中的 Future。
`loadProducts` 返回查询是否成功，成功时列表仍可能为空。初始化和回到前台时查询商品，
也可显式调用 `loadProducts(force: true)` 刷新。权益在已知到期、续订或缓存期限边界安排一次查询，
不根据定时器自行切换商品，也不设置固定轮询。
购买复用已加载的商品和所选优惠；有商品刷新正在进行时等待完成，缺少商品时先查询。
OpenIAP Google `4.0.3` 的原生 `requestPurchase` 已在构造购买参数前查询最新 `ProductDetails`，
并校验传入的优惠令牌，core 不重复执行一次商品查询。失效优惠返回商店错误，不自动另选套餐。
Google 未规定商品详情的固定失效分钟数。Apple 按商品 ID 发起购买，最终试用资格由 StoreKit 判断。
恢复批次和购买事件使用同一队列，恢复期间到达的新交易仍会处理；仅跳过本次恢复中
已成功处理的同一笔交易的重复事件，不建立永久去重缓存。
事件按到达时正在等待的购买关联；排队的旧交易和其他商品交易按静默同步处理，
不结束后来发起或商品不匹配的购买。
连接检查使用插件维护的共享状态；重连前等待上一次关闭完成，并合并进行中的连接或关闭操作。
商品或权益查询超时不会主动关闭连接；只对插件明确返回的连接类错误使连接失效，
供后续操作重新连接。正常空查询结果不做固定次数轮询。

`actionObserver` 为实际执行的购买、恢复和事件同步提供 started/finished 事件，保留调用方
传入的 `source`，可供埋点使用；配置无效或忙碌时只发布 finished 失败结果。
释放后不再调用宿主观察器或启动交易回传。
日志、观察器和交易回传回调失败不会改变交易结果。

购买与恢复会等待同一次初始化，调用者无须维护初始化 Future 或每次手动调用 `init`。
页面展示前可主动调用 `init` 提前加载商品；重复调用会共用同一个 Future。

`isConfigured` 表示当前平台与必需验证配置可用于订阅工作，不代表已有可购买套餐、
商店已连接或用户已订阅。具体问题由 `configurationFailure` 返回枚举：
不支持的平台为 `unsupportedPlatform`，在售与权益识别范围都显式为空时为 `planNotConfigured`，
默认 Google Play 适配器缺公钥为 `missingLicenseKey`。
`plans: []` 默认仍查询全部订阅；同时设置 `subscriptionProductIds: []` 才禁用订阅工作。

`init` 读取六小时内的权益缓存、注册生命周期与购买监听、连接商店、加载套餐、查询权益，
不触发 App Store 恢复。回到前台时重新查询商店；离线只采用六小时内的快照，
未来时间、损坏、超时，以及显式识别范围之外的缓存均不采用。
默认全量识别时，不因商品停止展示或从在售套餐移除而过滤其有效缓存。
缓存有效期仅用于快照新鲜度，不替代商店生命周期判断。
StoreKit 状态查询异常以 `SubscriptionAccessReason.storeQueryFailed` 区分，采用缓存时保留
原始快照与时间戳，不延长有效期。商店明确返回过期、撤销，或缺少已验证权益时，
仍按本次商店结果更新，不能一律借助缓存放行。
多个订阅组中只有部分组查询失败时，只允许采用失败组对应商品的有效快照，
不会因为另一组查询异常而恢复已确认过期商品的缓存权益。

由持有协调器的宿主释放资源：

```dart
await coordinator.dispose();
```

释放会取消事件与生命周期监听，并完成等待中的购买 Future，返回 `disposed`。
释放后到达的异步查询不会再写入通知器。

## 当前权益、续订与服务端验证

`accessState.value` 现在为 `SubscriptionSnapshot`，保留识别范围内的订阅记录，默认覆盖本 App 全部订阅。
`activeSubscriptions` 只包含 `active/gracePeriod`；顶层 `shouldGrantAccess` 仅表示存在有效订阅。
多功能 App 应将具体商品映射为功能，不能用这个布尔值开放所有付费能力：

```dart
// 只属于宿主 App 的业务配置。
const featuresByAppleProduct = {
  'am_year_1': {'recording'},
  'am_year_2': {'recording', 'navigation'},
};
final enabledFeatures = <String>{
  for (final record in coordinator.accessState.value.activeSubscriptions)
    if (record.store == IapStore.Apple)
      ...(featuresByAppleProduct[record.productId] ?? <String>{}),
};
```

Android 按 `store/productId/basePlanIdAndroid` 映射；同一 base plan 的 offer 不改变权益身份。
未配置业务映射或身份未知时，宿主自行决定权限策略，插件不按价格或 SKU 名称猜等级。
`renewal.nextProductId/nextBasePlanIdAndroid` 仅表示未来续订，不能授权目标功能。
关闭自动续订保留当前已付费权益。

Apple 在 App Store Connect 的同一订阅组内配置等级；仍通过 `purchasePlan(target)` 切换。
升级、降级及同级跨周期的计费和生效时间由 StoreKit 决定，插件依据实际结果输出
`applied/scheduled`，不自行退款或计算差价。底层 Dart 请求丢弃原生返回载荷，
因此本库在请求返回后刷新，并等待交易事件；默认两分钟未取得证据返回 `unconfirmed`。
`purchaseTimeout` 仅限制调用等待，不取消商店付款，迟到事件仍会同步。

Apple 使用 StoreKit 已验证当前权益及其关联状态。`subscribed/inGracePeriod` 需要存在对应的
已验证当前交易；不把同组其他交易的状态或 `autoRenewPreference` 当成当前商品。
`billingRetry/expired/revoked` 不授权。原生已验证的历史交易可以 finish，当前权益另行判断。

Google 本地路径验证 RSA 签名、商品与令牌，并排除 pending/suspended。
底层 `4.0.3` 的 `getActiveSubscriptions` 会从商品目录补全 base plan，不能证明实际已购套餐，
所以本库的本地结果将 `basePlanIdAndroid` 保留为 `null`。本地路径可提供商品维度的权益，
但无法确认精确 base plan 的购买效果，结果可能为 `unconfirmed`。

需要准确套餐身份、账号统一权益或 Android 替换时，配置 `verifiedSubscriptionQuery`。
配置后它是权益快照的唯一查询来源，失败不会静默改用设备查询：

```dart
SubscriptionCoordinatorConfig(
  plans: plans.values.toList(),
  googlePlayLicenseKeyAndroid: googlePlayLicenseKey,
  verifiedSubscriptionQuery: (request) async {
    // 宿主调用自己的后端，后端验证账号归属和商店证据。
    // request.productIds 为 null 时返回该账号的全部已验证订阅。
    // request.purchase 在交易完成/确认前提供；普通刷新时为空。
    return backend.verifyAndQuerySubscriptions(request);
  },
);
```

该回调返回商店事实，不能直接返回业务会员布尔值。服务端必须维护账号关联的购买证据，并验证应用、账号关联、交易/令牌，
区分当前与未来明细；Google 使用 `purchases.subscriptionsv2.get` 的实际 `lineItems/offerDetails`，
处理 `linkedPurchaseToken` 的旧令牌失效。收到无效证据应抛出 `localVerificationFailed`，
查询暂时失败可抛出 `storeQueryFailed` 或返回精确的 `queryFailedProductIds`。
记录必须携带实际 `store/productId`、各自证据时间和可取得的身份字段。

Android 显式替换还需要旧购买上下文及官方策略：

```dart
final result = await coordinator.purchasePlan(
  targetPlan,
  source: 'change_subscription',
  options: SubscriptionPurchaseOptions(
    replacementAndroid: GooglePlayReplacement(
      purchaseToken: current.purchaseTokenAndroid!,
      oldProductId: current.productId,
      mode: SubscriptionReplacementModeAndroid.Deferred,
    ),
  ),
);
```

此选项仅用于 Google Play，必须配置权威验证回调，否则返回 `verificationRequired`。
库核对当前持有的旧购买并验证签名，传递旧 token、旧商品和替换方式，不声明升降级方向。
策略支持范围由 Google 决定；`WithoutProration` 会立即切换权益，不能当作 `Deferred`。
延后替换的新购买也需要及时确认，回调应将新 token 关联到仍有效的当前明细及已证实的未来目标，
不能提前开放未来功能。Google 仅在对应 token 有新鲜有效权益后 acknowledge；失败返回
`acknowledgementFailed`，后续恢复可重试。

`transactionReporter` 在交易完成后独立执行，仅用于记录，异常只记日志；不保证持久化和重试，
不能作为授权回调。全局快照按独立的权益识别范围刷新，单笔失败不会直接覆盖其他有效商品。
退款、续订、外部变更依靠启动、事件、前台、恢复和边界查询同步；App 未运行时的同步由
宿主服务端处理 App Store Server Notifications / Google RTDN。

| 文件/类型 | 单一职责 |
| --- | --- |
| `subscription_configuration.dart` | 套餐集合与宿主回调配置 |
| `SubscriptionPlan/GooglePlayPlan` | 逻辑套餐到商店标识的映射 |
| `SubscriptionCatalog` | 精确解析商品、优惠、正常价与试用周期 |
| `SubscriptionPrice` | 数值价格、官方周期和本地化平均价 |
| `SubscriptionOperationState` | 只读工作快照与 loading 派生 |
| `SubscriptionCoordinator` | 初始化、事件队列、购买与恢复编排 |
| `SubscriptionTransactionProcessor` | 内部单笔交易验证、完成与独立记录 |
| `SubscriptionStoreAdapter` | 平台适配契约及购买账户参数 |
| `app_store_subscription_adapter.dart` | StoreKit 请求、验证、完成交易与权益映射 |
| `google_play_subscription_adapter.dart` | Play 请求、签名验证、确认与权益映射 |
| `SubscriptionSnapshot/SubscriptionAccessState` | 多项商店记录、当前状态与续订设置 |
| `SubscriptionEntitlementCache` | 版本化缓存、逐记录新鲜度与已知到期检查 |

默认入口仅导出接入所需的公共 API 与适配契约；平台 Helper、具体适配器、交易处理器和
缓存实现保留在内部。一般接入方只需配置套餐、持有协调器并监听只读状态。

现有产品集成可以移除的重复代码：平台分支、商品去重、base plan/offer 筛选、
计费阶段反向查价、平均价拼接、全局试用资格猜测、购买互斥、loading 请求标志、
初始化合并与状态转发。

宿主保留：自己的套餐枚举和 SKU 配置、兜底价格值、本地化文案、业务资格规则、
账号标识生成、埋点、支付墙、路由、试用提醒和交易记录 API。

## 依据与验证

全局模块审查、已修正问题及保留结构的理由见
[架构与逻辑审查](docs/architecture-review.md)。

除上方版本说明外，封装语义对应以下官方文档与固定版本源码：

- [flutter_inapp_purchase 11.0.3](https://pub.dev/packages/flutter_inapp_purchase/versions/11.0.3)
  中的 `types.dart`、`flutter_inapp_purchase.dart`
- [OpenIAP Apple 4.0.3 字段转换](https://github.com/hyodotdev/openiap/blob/4.0.3/packages/apple/Sources/Helpers/StoreKitTypesBridge.swift)
- [OpenIAP Apple 4.0.3 商店实现](https://github.com/hyodotdev/openiap/blob/4.0.3/packages/apple/Sources/OpenIapStoreKitModule.swift)
- [OpenIAP Google 4.0.3 源码包](https://repo.maven.apache.org/maven2/io/github/hyochan/openiap/openiap-google/4.0.3/openiap-google-4.0.3-sources.jar)
  中的 `BillingConverters.kt`、`OpenIapModule.kt`
- [统一 SubscriptionOffer 字段](https://openiap.dev/docs/types/subscription-offer)
- [Apple 试用资格查询](https://openiap.dev/docs/apis/ios/is-eligible-for-intro-offer-ios)
- [Apple 订阅组、等级与升降级](https://developer.apple.com/app-store/subscriptions/)
- [Apple 已验证续订 JSON](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/renewalinfo/jsonrepresentation)
- [Google 订阅替换](https://developer.android.com/google/play/billing/subscriptions)
- [Google 权威订阅明细](https://developers.google.com/android-publisher/api-ref/rest/v3/purchases.subscriptionsv2/get)
- [Apple 当前权益查询](https://developer.apple.com/documentation/storekit/transaction/currententitlements)
- [StoreKit 订阅状态](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/status)
- [Google PricingPhase](https://developer.android.com/reference/com/android/billingclient/api/ProductDetails.PricingPhase)
- [Google RecurrenceMode](https://developer.android.com/reference/com/android/billingclient/api/ProductDetails.RecurrenceMode)
- [Google 订阅生命周期](https://developer.android.com/google/play/billing/lifecycle/subscriptions)
- [Google 购买验证建议](https://developer.android.com/google/play/billing/security)
- [Google Billing 错误处理](https://developer.android.com/google/play/billing/errors)
- [Google Billing 接入与购买事件](https://developer.android.com/google/play/billing/integrate)

```sh
flutter pub get
flutter analyze
flutter test
```

测试覆盖价格与币种精度、多 base plan、优惠回退、试用分组查询、真实 Dart 插件的
MethodChannel 参数与事件解析、取消/待付款/失败/释放、并发 loading、权益缓存及两端验证，
还覆盖恢复期间新事件与重复事件、排队旧事件关联、原生断连通知和关闭期间重连。
本仓库没有原生宿主；商店沙盒和真机购买需要在宿主工程中验证。

完整示例：
[服务装配](example/lib/subscription_service_example.dart) 与
[界面绑定](example/lib/subscription_ui_delegate_example.dart)。
`example/` 中的界面代码仅演示宿主用法，其组件与样式不属于插件 API，也不由插件导出。
