# 订阅变更实现与迁移

日期：2026-11-09。发布版本为 `2.0.2`。
代码和模拟通道测试已实现；真实商店验收需在宿主工程执行。

## 通用契约

插件输出商店事实。宿主定义商品对应哪些功能、额度或会员名称。
Apple 组内等级由 App Store Connect 管理；Android 使用平台替换策略。
`SubscriptionPlan` 不增加 `tier/level`，购买仍只有 `purchasePlan` 入口。

```text
SubscriptionSnapshot
  evaluatedAtMs                    本次查询时间
  queryFailedProductIds            查询失败范围
  subscriptions[]
    store / productId              当前商店商品
    transactionId
    originalTransactionId?         Apple 原始交易
    subscriptionGroupIdIOS?        商店返回的订阅组
    purchaseTokenAndroid?
    basePlanIdAndroid?             只有可靠证据才填写
    status / effectiveUntilMs?
    evaluatedAtMs                  此项证据的原始时间
    fromCache                      是否离线回退
    renewal?
      autoRenewEnabled
      nextProductId?
      nextBasePlanIdAndroid?
      expectedRenewalAtMs?
```

`activeSubscriptions` 为有效或宽限期记录，全部保留，不按最晚到期或最高价挑一项。
顶层 `shouldGrantAccess` 仅表示存在有效订阅。续订目标、付款待批准、用户当前选择的套餐
都不增加当前权益；关闭续订也不立即移除当前权益。未知身份保持 `null`。

宿主应集中维护商品身份到功能的映射；Android 同时匹配 product/base plan，offer 不作为权益身份。
例如 `am_year_1` 开通录制，`am_year_2` 开通录制和导航，这份配置只存在于 App 权限服务。
插件不要求所有 App 都有基础/高级两档，也不要求功能按等级继承。

## 在售套餐与权益识别

`plans` 仅配置当前可购买套餐。默认 `subscriptionProductIds: null` 查询本 App 全部订阅，
仍有效的历史商品会自动进入快照，不要求补齐历史 ID，也不会加入支付墙或价格请求。
只有一套付费权益时，直接监听 `snapshot.shouldGrantAccess`。

需要限制识别范围时显式传入当前商店商品 ID；这个范围独立于在售套餐，同样过滤
恢复、服务端返回和缓存。空列表表示不识别任何订阅。只查询权益可以传 `plans: []`，
仍使用正常验证流程，不发起空 SKU 商品查询，购买则要求目标在已注册套餐中。

全量查询限定在本 App 的订阅。Apple 使用原生已验证当前权益及订阅组状态，
同组历史商品通过已验证 JWS 中的组标识关联，无需重新上架；状态查询失败时仍遵守缓存规则。
Google 通过原生 SUBS 查询识别订阅，再关联签名购买。普通内购不会因此获得订阅权益或被自动确认。

## 购买结果

| outcome / effect | 含义 | 宿主处理 |
| --- | --- | --- |
| `success / applied` | 已完成交易且验证目标身份当前有效 | 按当前快照开放功能 |
| `success / scheduled` | 商店已确认未来切换 | 保留当前商品功能，显示预约信息 |
| `pending` | 付款或外部批准未完成 | 等待事件，不开放新功能 |
| `unconfirmed` | 等待结束，证据仍不足 | 可主动刷新；不能据此自动重试付款 |
| `cancelled / failure` | 取消或明确失败 | 根据枚举显示结果，权限仍读快照 |

恢复和静默同步的 success 不承诺某个目标套餐已生效，其 `effect` 为空。
默认 `purchaseTimeout` 为两分钟，只限制调用方等待；不会取消商店购买。
原生请求已发出后即使调用超时，交易仍可能稍后完成，后续事件继续处理。

## Apple

同组切换直接请求目标商品，计费与生效由 StoreKit 决定。升级通常即时生效并由 Apple
处理未使用部分退款；降级在下次续订生效；同级相同周期通常即时切换，不同周期在下次续订切换。
插件不自行计算退款或按价格判断切换方向。

已验证的 renewal JSON 使用当前 `productId` 和原始交易身份关联状态，
`autoRenewPreference` 是下一次续订商品。多组及同商品的多份原始交易分别保留。
已验证历史交易可以完成；当前有效性必须来自当前权益和关联状态。

底层 `SubscriptionStatusIOS` 没有完整交易对象，本实现使用原生仅为已验证 renewalInfo
输出的 JSON，并从原生已验证当前交易 JWS 取得原始交易身份。
无法可靠关联时返回 unavailable，不用价格、时间或未来 SKU 补齐身份。
这依赖当前固定版本的数据契约，升级底层需重新核对。

## Google Play

显式替换使用：

```dart
SubscriptionPurchaseOptions(
  replacementAndroid: GooglePlayReplacement(
    purchaseToken: current.purchaseTokenAndroid!,
    oldProductId: current.productId,
    mode: SubscriptionReplacementModeAndroid.Deferred,
  ),
)
```

插件先确认旧购买当前持有并验证签名，再传递官方参数；不根据业务等级选择 mode。
`WithoutProration` 立即变更权益、下次续费开始按新价收费，不能当作延后切换。
各 mode 的可用范围及费用由 Google Play 检查，库不自动替换模式或退化为新购。

底层本地订阅查询会根据商品目录补全 base plan，不能证明实际购买身份，因此本地路径保留未知值。
普通购买可以获得商品维度的有效状态，但缺少精确 base plan 时不能确认 `applied`。
显式替换必须配置 `verifiedSubscriptionQuery`，否则返回 `verificationRequired`（2026）。
旧购买不匹配等替换参数错误返回 `invalidReplacement`（2025）。

## 服务端回调契约

`verifiedSubscriptionQuery(request)` 在刷新时接收商店和可选权益识别范围（`productIds`），在交易完成前还接收原始 Purchase。
该范围为 `null` 时，宿主后端应查询当前账号已关联的全部订阅证据；
不能只返回支付墙中的商品。Google 服务端查询仍需要后端保存的购买令牌，
不会凭空列出商店账号的全部购买。配置后它是唯一权益来源，不再退回设备端查询。它负责：

- 验证应用身份、账号关联、Apple 签名/交易或 Google token；无效证据抛出 `localVerificationFailed`。
- Google 调用 `purchases.subscriptionsv2.get`，使用实际 `lineItems` 与 `offerDetails.basePlanId`，
  正确区分当前和延后替换明细，处理 `linkedPurchaseToken`，停止旧 token 授权。
- Deferred 新 token 在购买后就需要处理/确认，回调将它关联到尚有效的当前商品明细；未来目标只写入 renewal。
- Apple 使用 App Store Server API / 已验证 JWS 返回当前记录与续订设置，不能用业务会员布尔值代替商店证据。
- 返回真实 `store/productId`、逐记录证据时间、状态和可取得的身份/期限；不把未生效明细标成 active。
- 查询失败可抛出 `storeQueryFailed`，或在 `queryFailedProductIds` 声明部分失败；失败范围不代表已过期。
  回调不应把过往缓存包装成新鲜有效证据。明确无当前权益时返回空记录或准确失效记录。

Google 本地签名验证仍保留；acknowledge 前必须有相同 token 的新鲜有效记录，查询失败不能代替验证。
若服务端也承担确认，需要协调客户端与服务端的并发并保证幂等；此回调本身只要求验证。
`transactionReporter` 只异步记录已完成交易，不承担授权或可靠投递。
账号切换应使用账号隔离的 `accessStateStorageKey` 并重建协调器，避免跨账号缓存复用。

宿主服务端自行处理 App Store Server Notifications / Google RTDN，实现应用未运行时的续订、退款和撤销同步。

## 从 2.0.1 及以前版本迁移

1. 将 `ValueListenable<SubscriptionAccessState>` 改为 `ValueListenable<SubscriptionSnapshot>`，
   `refreshAccessState()` 返回值同样更新。
2. 从 `snapshot.activeSubscriptions` 读取有效商品并映射业务功能。顶层不再有单一的 status/productId/reason。
3. 购买结果 switch 增加 `unconfirmed`；success 读取 `effect`，不能一律提示新权益已开通或直接关闭业务门禁。
4. Android 有多个 base plan 或需要替换时接入权威验证回调，并从已验证记录取得旧 token。
5. 自定义 adapter 的 `resolveVerifiedAccessState` 返回完整快照，移除全局 `fallbackProductId` 参数；
   `productIds` 改为可空，`null` 表示本 App 全部订阅，空列表不授权。服务端回调同样遵守这个范围。
6. 从 `plans` 移除只为识别历史权益而添加的套餐；默认全量查询仍识别历史商品。
   原本依赖在售列表过滤权益的接入方需显式配置 `subscriptionProductIds`。
7. 缓存 schema v2 读取旧单记录，保留原始时间；旧数据没有 store 时保持 Unknown，不能凭空补齐平台身份。
   每条记录受六小时期限和已知权益截止限制，部分刷新不延长其他记录证据时间。

`speedometer_flt` 当前固定 Git 依赖 `1.0.6`；本轮未修改宿主，需另行迁移并升级依赖。
插件使用 `2.0.2` Git 标签接入，包含公共接口变更，宿主升级前需完成上述迁移。

## 发布前商店验收

模拟通道测试覆盖状态和参数，真实计费必须在宿主中验证：

- 无历史 ID 的老订阅恢复、历史商品下架、纯权益查询、普通内购不被完成或确认。
- Apple 即时升级、预约降级、同级相同/不同周期、关闭续订、改回当前商品取消预约。
- 多组及家庭共享、多原始交易、宽限期、重试扣款、旧交易退款不影响新交易。
- Google 跨商品/同商品 base plan 替换、实际可用 mode、新旧 token、Deferred 当前/未来明细、待付款和确认。
- 商店管理页与其他设备变更、无目标事件、迟到/重复事件、断网与部分失败缓存、跨边界刷新。
- 两端账号归属、服务端通知、恢复与后台确认的幂等性。

本轮没有 Sandbox / Play 账号和可运行原生宿主，不宣称已完成真实交易验收。

## 官方依据

- [Apple 订阅组与升降级规则](https://developer.apple.com/app-store/subscriptions/)
- [Apple 当前权益查询](https://developer.apple.com/documentation/storekit/transaction/currententitlements)
- [Google 当前购买查询](https://developer.android.com/google/play/billing/integrate#fetch)
- [Apple 续订 JSON](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/renewalinfo/jsonrepresentation)
- [Apple autoRenewPreference](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/renewalinfo/autorenewpreference)
- [Google 订阅替换](https://developer.android.com/google/play/billing/subscriptions)
- [Google subscriptionsv2.get](https://developers.google.com/android-publisher/api-ref/rest/v3/purchases.subscriptionsv2/get)
- [Google 购买验证](https://developer.android.com/google/play/billing/security)
- [OpenIAP Apple 4.0.3 实现](https://github.com/hyodotdev/openiap/blob/4.0.3/packages/apple/Sources/OpenIapStoreKitModule.swift)
- [OpenIAP Google 4.0.3 源码](https://repo.maven.apache.org/maven2/io/github/hyochan/openiap/openiap-google/4.0.3/openiap-google-4.0.3-sources.jar)
