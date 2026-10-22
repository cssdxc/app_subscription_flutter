import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:flutter_test/flutter_test.dart';

SubscriptionActionResult failure({
  SubscriptionActionType type = SubscriptionActionType.purchase,
  ErrorCode? store,
  SubscriptionFailureCode? core,
}) => SubscriptionActionResult.failure(
  type: type,
  storeErrorCode: store,
  failureCode: core,
);

void main() {
  test('购买、恢复与同步使用相同的固定数字码及未知兜底', () {
    for (final type in SubscriptionActionType.values) {
      expect(
        failure(type: type, store: ErrorCode.UserCancelled).numericCode,
        1001,
      );
      expect(
        failure(type: type, store: ErrorCode.NetworkError).numericCode,
        1005,
      );
      expect(
        failure(
          type: type,
          core: SubscriptionFailureCode.productNotFound,
        ).numericCode,
        2001,
      );
      expect(failure(type: type, store: ErrorCode.Unknown).numericCode, 1999);
      expect(failure(type: type).numericCode, 2999);
      expect(
        SubscriptionActionResult(
          type: type,
          outcome: SubscriptionActionOutcome.cancelled,
        ).numericCode,
        1001,
      );
    }
  });

  test('两组错误全部映射到独立编号，封装原因优先于附带的商店错误', () {
    // 直接指定失败状态以检查完整码表；正常工厂会把待处理错误归为 pending。
    final storeCodes = ErrorCode.values.map(
      (code) => SubscriptionActionResult(
        type: SubscriptionActionType.purchase,
        outcome: SubscriptionActionOutcome.failure,
        storeErrorCode: code,
      ).numericCode!,
    );
    final coreCodes = SubscriptionFailureCode.values.map(
      (code) => SubscriptionActionResult(
        type: SubscriptionActionType.purchase,
        outcome: SubscriptionActionOutcome.failure,
        failureCode: code,
      ).numericCode!,
    );
    expect(storeCodes.every((code) => code >= 1001 && code <= 1999), true);
    expect(coreCodes.every((code) => code >= 2001 && code <= 2999), true);
    final allCodes = [...storeCodes, ...coreCodes];
    expect(allCodes.toSet().length, allCodes.length);
    expect(
      failure(
        store: ErrorCode.Unknown,
        core: SubscriptionFailureCode.productNotFound,
      ).numericCode,
      2001,
    );
  });

  test('成功与待处理没有错误提示码', () {
    for (final type in SubscriptionActionType.values) {
      expect(SubscriptionActionResult.success(type: type).numericCode, isNull);
      for (final result in [
        const SubscriptionActionResult(
          type: SubscriptionActionType.purchase,
          outcome: SubscriptionActionOutcome.pending,
        ),
        failure(type: type, store: ErrorCode.Pending),
        failure(type: type, store: ErrorCode.DeferredPayment),
        failure(type: type, core: SubscriptionFailureCode.purchasePending),
      ]) {
        expect(result.pending, true);
        expect(result.numericCode, isNull);
      }
    }
  });

  test('数字码不改变原始枚举与诊断信息', () {
    final storeResult = failure(store: ErrorCode.NetworkError);
    expect(storeResult.numericCode, 1005);
    expect(storeResult.storeErrorCode, ErrorCode.NetworkError);
    expect(storeResult.code, ErrorCode.NetworkError.value);

    final coreResult = failure(core: SubscriptionFailureCode.productNotFound);
    expect(coreResult.numericCode, 2001);
    expect(coreResult.failureCode, SubscriptionFailureCode.productNotFound);
    expect(coreResult.code, SubscriptionFailureCode.productNotFound.code);
  });
}
