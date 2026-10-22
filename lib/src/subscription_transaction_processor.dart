import 'dart:async';

import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

import 'subscription_access_state.dart';
import 'subscription_action_result.dart';
import 'subscription_configuration.dart';
import 'subscription_failure.dart';
import 'subscription_store_adapter.dart';
import 'subscription_transaction.dart';

/// 处理单笔交易的验证、完成和记录，不修改全局权益或缓存。
class SubscriptionTransactionProcessor {
  SubscriptionTransactionProcessor({
    required this.iap,
    required this.adapter,
    required this.productIds,
    required this.resolveAccess,
    required this.isDisposed,
    required this.log,
    this.reporter,
    required this.onStoreError,
  });

  final FlutterInappPurchase iap;
  final SubscriptionStoreAdapter adapter;
  final List<String> productIds;
  final Future<SubscriptionAccessState?> Function(String productId)
  resolveAccess;
  final bool Function() isDisposed;
  final SubscriptionLogger log;
  final SubscriptionTransactionReporter? reporter;
  final Future<void> Function(ErrorCode?) onStoreError;

  Future<SubscriptionActionResult> process(
    Purchase purchase, {
    required SubscriptionActionType type,
    required String source,
    bool silent = false,
  }) async {
    final productId = purchase.productId;
    SubscriptionActionResult failure(
      SubscriptionFailureCode code, {
      String? message,
    }) => SubscriptionActionResult.failure(
      type: type,
      silent: silent,
      productId: productId,
      failureCode: code,
      message: message,
      purchase: purchase,
    );

    if (isDisposed()) return failure(SubscriptionFailureCode.disposed);
    if (productId.isEmpty || !productIds.contains(productId)) {
      return failure(SubscriptionFailureCode.unknownSku);
    }
    if (purchase.purchaseState == PurchaseState.Pending) {
      return failure(SubscriptionFailureCode.purchasePending);
    }
    if (purchase.purchaseState != PurchaseState.Purchased) {
      return failure(SubscriptionFailureCode.ignoredState);
    }
    if (adapter.purchaseFailure(purchase) case final code?) {
      return failure(code);
    }

    try {
      await adapter.verifyPurchaseLocally(iap: iap, purchase: purchase);
      if (isDisposed()) return failure(SubscriptionFailureCode.disposed);
      final access = await resolveAccess(productId);
      if (isDisposed()) return failure(SubscriptionFailureCode.disposed);
      if (access?.shouldGrantAccess != true) {
        return failure(
          access?.reason == SubscriptionAccessReason.storeQueryFailed
              ? SubscriptionFailureCode.storeQueryFailed
              : SubscriptionFailureCode.subscriptionInactive,
        );
      }

      await adapter.finishTransaction(iap: iap, purchase: purchase);
      if (isDisposed()) return failure(SubscriptionFailureCode.disposed);
      // 商店交易完成后独立记录，回调不属于购买完成条件。
      unawaited(_report(purchase));
      return SubscriptionActionResult.success(
        type: type,
        silent: silent,
        productId: productId,
        purchase: purchase,
        message: source,
      );
    } on SubscriptionStoreException catch (error) {
      log('处理交易失败: code=${error.code}, message=${error.message}');
      return failure(error.failureCode, message: error.message);
    } on PurchaseError catch (error) {
      await onStoreError(error.code);
      return SubscriptionActionResult.failure(
        type: type,
        silent: silent,
        productId: productId,
        storeErrorCode: error.code,
        failureCode: error.code == null
            ? SubscriptionFailureCode.processingException
            : null,
        message: error.message,
        purchase: purchase,
      );
    } catch (error) {
      log('处理交易异常: $error');
      return failure(
        SubscriptionFailureCode.processingException,
        message: error.toString(),
      );
    }
  }

  Future<void> _report(Purchase purchase) async {
    if (isDisposed() || reporter == null) return;
    try {
      final SubscriptionTransactionPayload payload = adapter.transactionPayload(
        purchase,
      );
      if (payload.currentTransactionId.isEmpty &&
          payload.originalTransactionId.isEmpty &&
          (payload.purchaseToken ?? '').isEmpty) {
        return;
      }
      await reporter!(payload);
    } catch (error) {
      log('记录交易失败: $error');
    }
  }
}
