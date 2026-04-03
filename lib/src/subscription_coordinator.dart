import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ios_subscription_helper.dart';
import 'subscription_action_result.dart';
import 'subscription_catalog.dart';

typedef SubscriptionLogger = void Function(String message);
typedef SubscriptionTransactionReporter = Future<void> Function(
  SubscriptionTransactionPayload payload,
);
typedef SubscriptionActionObserver = void Function(
    SubscriptionActionEvent event);

class SubscriptionTransactionPayload {
  const SubscriptionTransactionPayload({
    required this.productId,
    required this.originalTransactionId,
    required this.currentTransactionId,
    this.purchase,
  });

  final String productId;
  final String originalTransactionId;
  final String currentTransactionId;
  final PurchaseIOS? purchase;
}

enum SubscriptionActionPhase {
  started,
  finished,
}

class SubscriptionActionEvent {
  const SubscriptionActionEvent({
    required this.phase,
    required this.type,
    required this.source,
    this.silent = false,
    this.productId,
    this.result,
  });

  final SubscriptionActionPhase phase;
  final SubscriptionActionType type;
  final String source;
  final bool silent;
  final String? productId;
  final SubscriptionActionResult? result;
}

class SubscriptionProductConfig {
  const SubscriptionProductConfig({
    required this.id,
    required this.defaultPrice,
  });

  final String id;
  final String defaultPrice;
}

class SubscriptionCoordinatorConfig {
  const SubscriptionCoordinatorConfig({
    required this.products,
    this.yearlyProductId,
    this.expirationStorageKey = 'subscription_expiration_time',
    this.debugOverride = false,
    this.logger,
    this.transactionReporter,
    this.actionObserver,
  });

  final List<SubscriptionProductConfig> products;
  final String? yearlyProductId;
  final String expirationStorageKey;
  final bool debugOverride;
  final SubscriptionLogger? logger;
  final SubscriptionTransactionReporter? transactionReporter;
  final SubscriptionActionObserver? actionObserver;
}

class SubscriptionCoordinator {
  SubscriptionCoordinator({
    required this.sharedPreferences,
    required this.config,
    FlutterInappPurchase? iap,
    MethodChannel? channel,
  })  : _iap = iap ?? FlutterInappPurchase.instance,
        _channel = channel ?? const MethodChannel('flutter_inapp'),
        catalog = SubscriptionCatalog(
          defaultPrices: {
            for (final product in config.products)
              product.id: product.defaultPrice,
          },
          yearlyProductId: config.yearlyProductId,
        );

  final SharedPreferences sharedPreferences;
  final SubscriptionCoordinatorConfig config;
  final FlutterInappPurchase _iap;
  final MethodChannel _channel;
  final SubscriptionCatalog catalog;

  final ValueNotifier<bool> isSubscribed = ValueNotifier<bool>(false);
  final ValueNotifier<bool> hasFreeTrial = ValueNotifier<bool>(true);
  final ValueNotifier<List<ProductSubscriptionIOS>> products =
      ValueNotifier<List<ProductSubscriptionIOS>>(<ProductSubscriptionIOS>[]);

  final Completer<void> _readyCompleter = Completer<void>();

  StreamSubscription<Purchase?>? _purchaseUpdatedSubscription;
  StreamSubscription<PurchaseError>? _purchaseErrorSubscription;

  _PendingPurchaseAction? _pendingPurchaseAction;
  bool _isProcessingPurchase = false;
  bool _isRestoring = false;
  bool _isBuying = false;

  Future<void> get ready => _readyCompleter.future;
  bool get isReady => _readyCompleter.isCompleted;
  List<String> get productIds =>
      config.products.map((product) => product.id).toList(growable: false);

  Future<void> init() async {
    try {
      await loadStoredStatus();

      final bool connected = await _iap.initConnection();
      if (!connected) {
        _log('应用内购买不可用');
        return;
      }

      _purchaseUpdatedSubscription =
          _iap.purchaseUpdated.listen((Purchase? purchase) async {
        if (purchase == null || purchase is! PurchaseIOS) {
          return;
        }

        _log(
          '收到购买更新: state=${purchase.purchaseState}, id=${purchase.id}, tx=${purchase.transactionIdFor}',
        );
        if (!IosSubscriptionHelper.shouldProcessPurchaseUpdate(purchase)) {
          _log('跳过非完成态购买更新: state=${purchase.purchaseState}');
          return;
        }
        if (_isRestoring) {
          _log('恢复购买进行中，忽略 purchaseUpdated 里的重复恢复事件');
          return;
        }
        if (_isProcessingPurchase) {
          _log('购买处理进行中，忽略重复购买更新');
          return;
        }

        final SubscriptionActionType actionType = _pendingPurchaseAction != null
            ? SubscriptionActionType.purchase
            : SubscriptionActionType.sync;
        final SubscriptionActionResult result = await _handlePurchasedItem(
          purchase,
          actionType: actionType,
          source: _pendingPurchaseAction?.source ?? 'purchase_update',
        );
        _completePendingPurchaseAction(result);
      });

      _purchaseErrorSubscription =
          _iap.purchaseErrorListener.listen((PurchaseError event) {
        final String errorCode = event.code?.value ?? '';
        _log('购买错误: code=$errorCode, message=${event.message}');
        _isBuying = false;
        final _PendingPurchaseAction? pendingAction = _pendingPurchaseAction;
        if (pendingAction != null && !pendingAction.completer.isCompleted) {
          final SubscriptionActionResult result =
              SubscriptionActionResult.failure(
            type: SubscriptionActionType.purchase,
            productId: pendingAction.productId,
            code: errorCode,
            message: event.message,
            cancelled: event.code == ErrorCode.UserCancelled,
          );
          pendingAction.completer.complete(result);
          _notifyFinished(pendingAction.source, result);
        }
        _pendingPurchaseAction = null;
      });

      await restore(source: 'bootstrap', silent: true);
      await loadProducts();
    } finally {
      if (!_readyCompleter.isCompleted) {
        _readyCompleter.complete();
      }
    }
  }

  Future<void> loadProducts() async {
    if (products.value.isNotEmpty) {
      return;
    }
    final List<ProductSubscriptionIOS> rawList = await _iap.fetchProducts(
      skus: productIds,
      type: ProductQueryType.Subs,
    );
    products.value = rawList;
    await refreshTrialEligibility();
  }

  Future<void> loadStoredStatus() async {
    if (config.debugOverride) {
      isSubscribed.value = true;
      return;
    }
    final int expirationMs =
        sharedPreferences.getInt(config.expirationStorageKey) ?? 0;
    isSubscribed.value = expirationMs > DateTime.now().millisecondsSinceEpoch;
  }

  Future<void> refreshTrialEligibility() async {
    try {
      hasFreeTrial.value = await IosSubscriptionHelper.computeTrialEligibility(
        iap: _iap,
        products: products.value,
        subscriptionProductIds: productIds,
        logger: _log,
      );
    } catch (e) {
      _log('检查订阅历史失败: $e');
      hasFreeTrial.value = false;
    }
  }

  Future<SubscriptionActionResult> purchase(
    ProductSubscriptionIOS? product, {
    required String source,
  }) async {
    if (product == null) {
      await loadProducts();
      final SubscriptionActionResult result = SubscriptionActionResult.failure(
        type: SubscriptionActionType.purchase,
        code: 'product-not-found',
        message: 'Subscription product is unavailable.',
      );
      _notifyFinished(source, result);
      return result;
    }

    if (_hasInFlightOperation) {
      _log('正在处理购买，请勿重复操作');
      final SubscriptionActionResult result = SubscriptionActionResult.failure(
        type: SubscriptionActionType.purchase,
        productId: product.id,
        code: 'busy',
        message: 'Another purchase flow is already in progress.',
      );
      _notifyFinished(source, result);
      return result;
    }

    _notifyStarted(
      type: SubscriptionActionType.purchase,
      source: source,
      productId: product.id,
    );

    _log('开始购买订阅: ${product.id}');
    _isBuying = true;
    final Completer<SubscriptionActionResult> completer =
        Completer<SubscriptionActionResult>();
    _pendingPurchaseAction = _PendingPurchaseAction(
      productId: product.id,
      source: source,
      completer: completer,
    );

    try {
      await _iap.requestPurchaseWithBuilder(
        build: (builder) {
          builder
            ..type = ProductQueryType.Subs
            ..android.skus = [product.id]
            ..ios.sku = product.id;
        },
      );
      _log('购买请求已发送');
      final SubscriptionActionResult result = await completer.future;
      _notifyFinished(source, result);
      return result;
    } on PurchaseError catch (e) {
      _log('发起购买返回错误: code=${e.code?.value ?? ''}, message=${e.message}');
      _isBuying = false;
      _pendingPurchaseAction = null;
      final SubscriptionActionResult result = SubscriptionActionResult.failure(
        type: SubscriptionActionType.purchase,
        productId: product.id,
        code: e.code?.value ?? 'request-failed',
        message: e.message,
        cancelled: e.code == ErrorCode.UserCancelled,
      );
      _notifyFinished(source, result);
      return result;
    } catch (e) {
      _log('发起购买异常: $e');
      _isBuying = false;
      _pendingPurchaseAction = null;
      final SubscriptionActionResult result = SubscriptionActionResult.failure(
        type: SubscriptionActionType.purchase,
        productId: product.id,
        code: 'request-failed',
        message: e.toString(),
      );
      _notifyFinished(source, result);
      return result;
    }
  }

  Future<SubscriptionActionResult> restore({
    String source = 'manual_restore',
    bool silent = false,
  }) async {
    if (_hasInFlightOperation) {
      _log('正在处理其他操作，请勿重复恢复');
      final SubscriptionActionResult result = SubscriptionActionResult.failure(
        type: SubscriptionActionType.restore,
        silent: silent,
        code: 'busy',
        message: 'Another purchase flow is already in progress.',
      );
      _notifyFinished(source, result, silent: silent);
      return result;
    }

    _notifyStarted(
      type: SubscriptionActionType.restore,
      source: source,
      silent: silent,
    );
    _log('开始恢复购买');

    try {
      _isRestoring = true;
      if (Platform.isIOS) {
        await _iap.restorePurchases();
      }
      final List<Purchase> items = await _iap.getAvailablePurchases();
      if (items.isEmpty) {
        final SubscriptionActionResult result =
            SubscriptionActionResult.success(
          type: SubscriptionActionType.restore,
          silent: silent,
          message: 'No restorable purchases were found.',
        );
        _notifyFinished(source, result, silent: silent);
        return result;
      }

      int restoredCount = 0;
      PurchaseIOS? latestSuccessPurchase;
      for (final item in items) {
        if (item is! PurchaseIOS) {
          continue;
        }
        final SubscriptionActionResult result = await _handlePurchasedItem(
          item,
          actionType: SubscriptionActionType.restore,
          source: source,
          silent: silent,
        );
        if (result.success) {
          restoredCount++;
          latestSuccessPurchase = result.purchase;
        }
      }
      await refreshTrialEligibility();

      final SubscriptionActionResult finalResult = restoredCount == 0
          ? SubscriptionActionResult.failure(
              type: SubscriptionActionType.restore,
              silent: silent,
              code: 'restore-inactive',
              message:
                  'Restorable purchases were found, but none are currently active.',
            )
          : SubscriptionActionResult.success(
              type: SubscriptionActionType.restore,
              silent: silent,
              productId: IosSubscriptionHelper.normalizedProductId(
                  latestSuccessPurchase),
              purchase: latestSuccessPurchase,
              restoredCount: restoredCount,
            );
      _notifyFinished(source, finalResult, silent: silent);
      return finalResult;
    } catch (e) {
      _log('恢复购买异常: $e');
      final SubscriptionActionResult result = SubscriptionActionResult.failure(
        type: SubscriptionActionType.restore,
        silent: silent,
        code: 'restore-exception',
        message: e.toString(),
      );
      _notifyFinished(source, result, silent: silent);
      return result;
    } finally {
      _isRestoring = false;
      _isBuying = false;
    }
  }

  Future<SubscriptionActionResult> restoreSilently({
    String source = 'silent_restore',
  }) {
    return restore(source: source, silent: true);
  }

  String findPrice(String productId, String fallbackPrice) {
    return catalog.findDisplayPrice(products.value, productId, fallbackPrice);
  }

  String findDefaultPrice(String productId) {
    return catalog.findDefaultPrice(productId);
  }

  ProductSubscriptionIOS? findProduct(String productId) {
    return catalog.findProduct(products.value, productId);
  }

  String yearlyPricePerWeek({
    required String fallbackPrice,
    required String weekLabel,
  }) {
    return catalog.yearlyPricePerWeek(
      products.value,
      fallbackPrice: fallbackPrice,
      weekLabel: weekLabel,
    );
  }

  Future<void> dispose() async {
    await _purchaseUpdatedSubscription?.cancel();
    await _purchaseErrorSubscription?.cancel();
    try {
      _iap.endConnection();
    } catch (_) {}
    isSubscribed.dispose();
    hasFreeTrial.dispose();
    products.dispose();
  }

  Future<SubscriptionVerificationResult> _verifyCurrentSubscriptionByItem({
    PurchaseIOS? item,
  }) async {
    final String productId = IosSubscriptionHelper.normalizedProductId(item);
    if (productId.isEmpty || !productIds.contains(productId)) {
      _log(
        'Skip verifying purchase with invalid productId: rawId=${item?.id}, productId=${item?.productId}',
      );
      await _updateSubscriptionExpiration(0);
      return const SubscriptionVerificationResult(isActive: false);
    }

    PurchaseIOS? verifiedItem = item;
    final IOSLocalValidationResult? validationResult =
        await IosSubscriptionHelper.validateReceiptLocally(
      channel: _channel,
      productId: productId,
      fallbackItem: item,
      logger: _log,
    );
    if (validationResult == null) {
      final bool fallbackActive = IosSubscriptionHelper.isPurchaseActive(item);
      final int fallbackExpirationMs = item?.expirationDateIOS?.toInt() ?? 0;
      _log(
        'Local validation unavailable for $productId, fallback to transaction fields: '
        'active=$fallbackActive, tx=${item?.transactionIdFor}, '
        'expirationMs=$fallbackExpirationMs, expiresAt=${_formatExpiration(fallbackExpirationMs)}',
      );
      await _reportTransaction(item);
      await _updateSubscriptionExpiration(
        fallbackActive ? fallbackExpirationMs : 0,
      );
      return SubscriptionVerificationResult(
        isActive: fallbackActive,
        resolvedItem: item,
      );
    }

    if (!validationResult.isValid) {
      await _updateSubscriptionExpiration(0);
      return const SubscriptionVerificationResult(isActive: false);
    }

    if (validationResult.latestTransaction != null) {
      verifiedItem = validationResult.latestTransaction;
    }

    final bool isActive = IosSubscriptionHelper.isPurchaseActive(verifiedItem);
    final int verifiedExpirationMs =
        verifiedItem?.expirationDateIOS?.toInt() ?? 0;
    _log(
      'Local validation resolved for $productId: '
      'active=$isActive, tx=${verifiedItem?.transactionIdFor}, '
      'expirationMs=$verifiedExpirationMs, expiresAt=${_formatExpiration(verifiedExpirationMs)}',
    );
    await _reportTransaction(verifiedItem);
    await _updateSubscriptionExpiration(
      isActive ? verifiedExpirationMs : 0,
    );

    return SubscriptionVerificationResult(
      isActive: isActive,
      resolvedItem: verifiedItem,
    );
  }

  Future<SubscriptionActionResult> _handlePurchasedItem(
    PurchaseIOS item, {
    required SubscriptionActionType actionType,
    required String source,
    bool silent = false,
  }) async {
    if (!IosSubscriptionHelper.shouldProcessPurchaseUpdate(item)) {
      _log('忽略不需要处理的购买项: state=${item.purchaseState}');
      return SubscriptionActionResult.failure(
        type: actionType,
        silent: silent,
        productId: IosSubscriptionHelper.normalizedProductId(item),
        code: 'ignored-state',
        message: 'Purchase state is not eligible for processing.',
        purchase: item,
      );
    }
    if (_isProcessingPurchase) {
      _log('正在处理购买更新，跳过重复处理');
      return SubscriptionActionResult.failure(
        type: actionType,
        silent: silent,
        productId: IosSubscriptionHelper.normalizedProductId(item),
        code: 'busy',
        message: 'Another purchase flow is in progress.',
        purchase: item,
      );
    }

    _isProcessingPurchase = true;
    try {
      final String productId = IosSubscriptionHelper.normalizedProductId(item);
      _log(
        '处理购买更新: 产品ID: $productId, rawId=${item.id}, tx=${item.transactionIdFor}',
      );
      if (productId.isEmpty || !productIds.contains(productId)) {
        _log('忽略未知 SKU 的购买更新: rawId=${item.id}, productId=${item.productId}');
        return SubscriptionActionResult.failure(
          type: actionType,
          silent: silent,
          productId: productId,
          code: 'unknown-sku',
          message: 'Purchase product ID is not managed by this service.',
          purchase: item,
        );
      }

      final SubscriptionVerificationResult verificationResult =
          await _verifyCurrentSubscriptionByItem(item: item);
      final bool verificationSuccess = verificationResult.isActive;
      final PurchaseIOS purchaseToFinish =
          verificationResult.resolvedItem ?? item;
      _isBuying = false;

      await IosSubscriptionHelper.finishTransactionSafe(
        channel: _channel,
        item: purchaseToFinish,
        fallbackFinish: (purchase) =>
            _iap.finishTransaction(purchase: purchase),
        logger: _log,
      );
      await refreshTrialEligibility();

      if (!verificationSuccess) {
        return SubscriptionActionResult.failure(
          type: actionType,
          silent: silent,
          productId: productId,
          code: 'validation-failed',
          message: 'Subscription is not active after local validation.',
          purchase: purchaseToFinish,
        );
      }

      return SubscriptionActionResult.success(
        type: actionType,
        silent: silent,
        productId: productId,
        purchase: purchaseToFinish,
        message: source,
      );
    } catch (e) {
      _log('处理购买项异常: $e');
      return SubscriptionActionResult.failure(
        type: actionType,
        silent: silent,
        productId: IosSubscriptionHelper.normalizedProductId(item),
        code: 'processing-exception',
        message: e.toString(),
        purchase: item,
      );
    } finally {
      _isProcessingPurchase = false;
    }
  }

  Future<void> _reportTransaction(PurchaseIOS? item) async {
    final SubscriptionTransactionReporter? reporter =
        config.transactionReporter;
    if (reporter == null) {
      return;
    }

    final String productId = IosSubscriptionHelper.normalizedProductId(item);
    final String originalTransactionId =
        item?.originalTransactionIdentifierIOS ?? '';
    final String currentTransactionId = item?.transactionIdFor ?? '';
    if (originalTransactionId.isEmpty && currentTransactionId.isEmpty) {
      _log('Skip sending transaction: missing transaction identifiers');
      return;
    }

    try {
      await reporter(
        SubscriptionTransactionPayload(
          productId: productId,
          originalTransactionId: originalTransactionId,
          currentTransactionId: currentTransactionId,
          purchase: item,
        ),
      );
    } catch (e) {
      _log('Send transaction to server error: $e');
    }
  }

  Future<void> _updateSubscriptionExpiration(int expirationMs) async {
    await sharedPreferences.setInt(config.expirationStorageKey, expirationMs);
    final bool active = config.debugOverride
        ? true
        : expirationMs > DateTime.now().millisecondsSinceEpoch;
    _log(
      'update subscription expiration: '
      'expirationMs=$expirationMs, expiresAt=${_formatExpiration(expirationMs)}, active=$active',
    );
    isSubscribed.value = active;
  }

  String _formatExpiration(int expirationMs) {
    if (expirationMs <= 0) {
      return 'n/a';
    }
    return DateTime.fromMillisecondsSinceEpoch(expirationMs).toIso8601String();
  }

  bool get _hasInFlightOperation => _isProcessingPurchase || _isBuying;

  void _completePendingPurchaseAction(SubscriptionActionResult result) {
    final _PendingPurchaseAction? pendingAction = _pendingPurchaseAction;
    if (pendingAction == null || pendingAction.completer.isCompleted) {
      return;
    }
    pendingAction.completer.complete(result);
    _pendingPurchaseAction = null;
  }

  void _notifyStarted({
    required SubscriptionActionType type,
    required String source,
    bool silent = false,
    String? productId,
  }) {
    config.actionObserver?.call(
      SubscriptionActionEvent(
        phase: SubscriptionActionPhase.started,
        type: type,
        source: source,
        silent: silent,
        productId: productId,
      ),
    );
  }

  void _notifyFinished(
    String source,
    SubscriptionActionResult result, {
    bool silent = false,
  }) {
    config.actionObserver?.call(
      SubscriptionActionEvent(
        phase: SubscriptionActionPhase.finished,
        type: result.type,
        source: source,
        silent: silent || result.silent,
        productId: result.productId,
        result: result,
      ),
    );
  }

  void _log(String message) {
    config.logger?.call(message);
  }
}

class _PendingPurchaseAction {
  const _PendingPurchaseAction({
    required this.productId,
    required this.source,
    required this.completer,
  });

  final String productId;
  final String source;
  final Completer<SubscriptionActionResult> completer;
}
