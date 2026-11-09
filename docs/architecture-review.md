# 订阅核心架构

核对日期：2026-11-09。实现基线为 `flutter_inapp_purchase 11.0.3`、
OpenIAP Apple / Google `4.0.3`。发布版本为 `2.0.2`。

## 职责

| 模块 | 负责内容 |
| --- | --- |
| `SubscriptionPlan / GooglePlayPlan` | 当前在售商品及 base plan/offer 映射，不包含业务等级 |
| `subscriptionProductIds` | 独立的可选权益识别范围，默认查询本 App 全部订阅 |
| `SubscriptionCatalog / SubscriptionPrice` | 精确商品与优惠选择、续费价、试用周期、平均价展示 |
| `SubscriptionSnapshot` | 全部查询记录与失败商品范围；不压缩为单一会员档位 |
| `SubscriptionAccessState / SubscriptionRenewal` | 一项当前订阅的商店身份、有效状态，以及独立续订设置 |
| `SubscriptionCoordinator` | 初始化、操作互斥、交易队列、快照刷新及有限等待 |
| `SubscriptionTransactionProcessor` | 单笔交易验证、完成/确认、独立记录，不直接授予业务功能 |
| Apple / Google adapter 与 helper | 平台调用、签名/状态关联、原生参数转换 |
| `SubscriptionEntitlementCache` | schema 版本、逐记录时间与到期检查，不生成新付费周期 |
| 宿主验证回调 | 服务端核验商店与账号证据，返回权威商店事实 |
| 宿主权限服务 | 商店商品身份到功能、额度、业务档位的映射 |

商店的 subscription group、base plan、offer 与 App 内会员等级分别表达不同概念。
库不按价格、周期、SKU 名称或购买时间推断权益高低，不复制 App Store Connect 等级表。

`plans` 只用于商品加载和购买，历史 SKU 不需要加入在售配置。
`subscriptionProductIds == null` 使用两端原生全量订阅查询；传列表时限制识别范围，空列表不授权。
`plans: []` 可以只查询权益，不请求商品价格。单一权益读取快照的 `shouldGrantAccess`；
多权益由宿主按记录映射功能。范围在构造时复制，之后修改原配置列表不会改变运行中的范围。

## 数据与交易时序

1. 初始化先监听交易，再连接、加载商品和查询当前快照；不自动触发 Apple 账号同步。
2. 购买复用已解析商品/优惠。Google 替换先验证旧购买，再传官方旧 token、旧商品和策略。
3. 购买事件与恢复批次串行处理，事件到达时关联正在等待的购买；旧事件不能关联之后的操作。
4. 本地验证后调用可选服务端验证。Apple 历史已验证交易可以 finish；Google 需要对应 token 的有效证据再 acknowledge。
5. 完成后刷新权益识别范围，并用当前/未来身份判断 `applied/scheduled`；结果不替代权益快照。
6. 没有目标新事件时，请求返回后的刷新也可以证实预约。等待超时返回 `unconfirmed`，迟到事件继续同步。
7. 交易报告异步执行，仅用于记录；观察器、日志与报告异常不改变商店交易结果。

购买/恢复互斥，商品与权益查询可合并进行中的 Future。前台刷新不因正在等待购买而丢弃。
计数器负责 loading 收尾；释放取消监听与边界定时器，结束等待中的购买，异步结果不再更新通知器。

## 证据边界

Apple 当前权益来自原生已验证的 `Transaction.currentEntitlements`，原生已排除 `isUpgraded`。
订阅组状态通过已验证 renewal JSON 中的当前 `productId/originalTransactionId` 关联，
不能使用未来的 `autoRenewPreference` 匹配当前交易。
历史交易的组标识从原生已验证当前交易 JWS 取得，同组优先借助已加载商品查询状态，
没有已加载同组商品时查询实际发现的订阅商品，未取得可靠状态仍保留失败和缓存边界。无法唯一关联时不借用其他记录的状态。
只有一项权益与一项状态、且原生没有提供 JSON 时，才保留单项关联路径；损坏或矛盾的 JSON 不回退。

全量模式下，Apple 未注册交易需要原生订阅组标识；Google 购买必须关联到原生 SUBS 查询或权威订阅快照，
避免将普通内购自动完成或确认。

Google 本地结果验证原始签名并关联当前购买令牌、商品与已购买/未暂停状态。
底层从目录补全的 base plan 不作为购买证据。显式替换需要服务端使用
`purchases.subscriptionsv2.get` 验证实际明细，包括未来替换及旧 token 失效；
库不为缺失字段生成猜测值。服务端回调一旦配置，即为唯一权益来源。

缓存最长六小时，每条记录保留原始证据时间，已知权益到期后不继续授权。
部分查询失败只回退失败商品；明确失效或验证失败不回退缓存。全量失败不重写证据时间。
已知到期、预计续订与缓存期限只触发一次查询，定时器不授予新权益。
六小时是本库离线策略，不是商店保证。账号切换时宿主需使用账号隔离的缓存键并重建协调器。

## 验证范围

本仓库测试实际 Dart 插件与模拟 MethodChannel，覆盖参数、事件、状态关联、验证与确认顺序、
预约/即时结果、迟到事件、缓存及边界刷新。它不能验证商店真实扣费、退款或跨设备传播时序。
发布前的 Sandbox / Play 验收及官方链接见[订阅变更与迁移说明](subscription-tier-change-plan.md)。
