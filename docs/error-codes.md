# 数字错误码

调用方直接读取 `SubscriptionActionResult.numericCode`。这些数字由本库定义，
并非 Apple、Google 或 `flutter_inapp_purchase` 的原始响应值。
数字码用于提示、客服定位和上报；业务分支仍使用 `outcome`、`failureCode` 和 `storeErrorCode` 枚举。
本库不包含提示文案或 UI，宿主自行组合本地化文案，例如 `取消 (1001)`。

规则：

- 成功和待处理返回 `null`，不按失败提示。
- 取消固定返回 `1001`。
- 失败优先按 `failureCode` 返回封装错误码；没有封装原因时按 `storeErrorCode` 返回商店错误码。
- 商店未知错误返回 `1999`；两类原因都没有的失败返回 `2999`。
- 编号显式固定，不使用枚举下标；新增错误类型分配新编号。

## 商店错误：1001–1999

枚举依据 `flutter_inapp_purchase 11.0.3` 源码 `lib/types.dart`，参见
[`ErrorCode` 官方 API](https://pub.dev/documentation/flutter_inapp_purchase/11.0.3/types/ErrorCode.html)。
本库映射集中在 `lib/src/subscription_error_codes.dart`。

| 官方枚举 | 数字码 |
| --- | --- |
| `UserCancelled` | 1001 |
| `UserError` | 1002 |
| `ItemUnavailable` | 1003 |
| `RemoteError` | 1004 |
| `NetworkError` | 1005 |
| `ServiceError` | 1006 |
| `PurchaseVerificationFailed` | 1007 |
| `PurchaseVerificationFinished` | 1008 |
| `PurchaseVerificationFinishFailed` | 1009 |
| `NotPrepared` | 1010 |
| `NotEnded` | 1011 |
| `AlreadyOwned` | 1012 |
| `DeveloperError` | 1013 |
| `BillingResponseJsonParseError` | 1014 |
| `DeferredPayment` | 1015 |
| `Interrupted` | 1016 |
| `IapNotAvailable` | 1017 |
| `PurchaseError` | 1018 |
| `SyncError` | 1019 |
| `TransactionValidationFailed` | 1020 |
| `ActivityUnavailable` | 1021 |
| `AlreadyPrepared` | 1022 |
| `Pending` | 1023 |
| `ConnectionClosed` | 1024 |
| `InitConnection` | 1025 |
| `ServiceDisconnected` | 1026 |
| `ServiceTimeout` | 1027 |
| `QueryProduct` | 1028 |
| `SkuNotFound` | 1029 |
| `SkuOfferMismatch` | 1030 |
| `ItemNotOwned` | 1031 |
| `BillingUnavailable` | 1032 |
| `FeatureNotSupported` | 1033 |
| `EmptySkuList` | 1034 |
| `DuplicatePurchase` | 1035 |
| `Unknown` | 1999 |

## 封装错误：2001–2999

| `SubscriptionFailureCode` | 数字码 |
| --- | --- |
| `productNotFound` | 2001 |
| `unsupportedPlatform` | 2002 |
| `invalidProductPlatform` | 2003 |
| `busy` | 2004 |
| `disposed` | 2005 |
| `planNotConfigured` | 2006 |
| `storeUnavailable` | 2007 |
| `requestFailed` | 2008 |
| `restoreException` | 2009 |
| `restoreInactive` | 2010 |
| `purchasePending` | 2011 |
| `subscriptionSuspended` | 2012 |
| `ignoredState` | 2013 |
| `unknownSku` | 2014 |
| `subscriptionInactive` | 2015 |
| `storeQueryFailed` | 2016 |
| `processingException` | 2017 |
| `invalidOffer` | 2018 |
| `offerRequired` | 2019 |
| `offerUnavailable` | 2020 |
| `acknowledgementFailed` | 2021 |
| `localVerificationFailed` | 2022 |
| `missingLicenseKey` | 2023 |
| `missingPurchaseToken` | 2024 |
| 无具体分类的失败 | 2999 |

`DeferredPayment`、`Pending` 和 `purchasePending` 在码表中保留编号，
但正常通过 `SubscriptionActionResult.failure` 创建的结果属于待处理，`numericCode` 返回 `null`。
