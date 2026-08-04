import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'subscription_access_state.dart';
import 'subscription_action_result.dart';
import 'subscription_catalog.dart';
import 'subscription_store_adapter.dart';
import 'subscription_transaction.dart';

typedef SubscriptionLogger = void Function(String message);
typedef SubscriptionTransactionReporter = Future<void> Function(
  SubscriptionTransactionPayload payload,
);
typedef SubscriptionActionObserver = void Function(
    SubscriptionActionEvent event);
typedef ActiveSubscriptionQuery = Future<List<ActiveSubscription>> Function(
  List<String>? productIds,
);

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
    this.accessStateStorageKey,
    this.debugOverride = false,
    this.googlePlayLicenseKeyAndroid = '',
    this.logger,
    this.transactionReporter,
    this.actionObserver,
    this.activeSubscriptionQuery,
  });

  final List<SubscriptionProductConfig> products;
  final String? accessStateStorageKey;
  final bool debugOverride;
  final String googlePlayLicenseKeyAndroid;
  final SubscriptionLogger? logger;
  final SubscriptionTransactionReporter? transactionReporter;
  final SubscriptionActionObserver? actionObserver;
  final ActiveSubscriptionQuery? activeSubscriptionQuery;
}

class SubscriptionCoordinator with WidgetsBindingObserver {
  SubscriptionCoordinator({
    required this.sharedPreferences,
    required this.config,
    FlutterInappPurchase? iap,
    SubscriptionStoreAdapter? storeAdapter,
  })  : _iap = iap ?? FlutterInappPurchase.instance,
        _storeAdapter = storeAdapter ??
            SubscriptionStoreAdapter.forIap(
              iap ?? FlutterInappPurchase.instance,
              googlePlayLicenseKeyAndroid: config.googlePlayLicenseKeyAndroid,
            ),
        catalog = SubscriptionCatalog(
          defaultPrices: {
            for (final product in config.products)
              product.id: product.defaultPrice,
          },
        );

  final SharedPreferences sharedPreferences;
  final SubscriptionCoordinatorConfig config;
  final FlutterInappPurchase _iap;
  final SubscriptionStoreAdapter _storeAdapter;
  final SubscriptionCatalog catalog;

  final ValueNotifier<bool> isSubscribed = ValueNotifier<bool>(false);
  final ValueNotifier<bool> hasFreeTrial = ValueNotifier<bool>(true);
  final ValueNotifier<SubscriptionAccessState> accessState =
      ValueNotifier<SubscriptionAccessState>(
    const SubscriptionAccessState(
      status: SubscriptionAccessStatus.unavailable,
      evaluatedAtMs: 0,
      note: 'not evaluated',
    ),
  );
  final ValueNotifier<List<ProductSubscription>> products =
      ValueNotifier<List<ProductSubscription>>(<ProductSubscription>[]);

  final Completer<void> _readyCompleter = Completer<void>();

  StreamSubscription<Purchase>? _purchaseUpdatedSubscription;
  StreamSubscription<PurchaseError>? _purchaseErrorSubscription;

  _PendingPurchaseAction? _pendingPurchaseAction;
  bool _isProcessingPurchase = false;
  bool _isRestoring = false;
  bool _isBuying = false;
  bool _isIapConnected = false;
  bool _isLifecycleObserverRegistered = false;
  bool _isForegroundRefreshRunning = false;
  bool _isDisposed = false;
  Future<bool>? _iapConnectionFuture;

  Future<void> get ready => _readyCompleter.future;
  bool get isReady => _readyCompleter.isCompleted;
  List<String> get productIds =>
      config.products.map((product) => product.id).toList(growable: false);

  Future<void> init() async {
    try {
      await loadStoredStatus();
      _registerLifecycleObserver();

      final bool connected = await _ensureIapConnection(source: 'init');
      if (!connected) {
        _log('应用内购买暂不可用，等待网络权限或前台恢复后重试');
        return;
      }

      _listenToPurchaseEvents();
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
    if (productIds.isEmpty) {
      _log('跳过商品加载：未配置订阅商品');
      products.value = <ProductSubscription>[];
      hasFreeTrial.value = false;
      return;
    }
    final bool connected = await _ensureIapConnection(source: 'load_products');
    if (!connected) {
      _log('跳过商品加载：应用内购买连接暂不可用');
      return;
    }
    try {
      final List<ProductSubscription> rawList =
          await _iap.fetchProducts<ProductSubscription>(
        skus: productIds,
        type: ProductQueryType.Subs,
      );
      products.value = rawList;
      await refreshTrialEligibility();
    } on PurchaseError catch (e) {
      _isIapConnected = false;
      _log('加载订阅商品失败: code=${e.code?.value ?? ''}, message=${e.message}');
      hasFreeTrial.value = false;
    } catch (e) {
      _isIapConnected = false;
      _log('加载订阅商品异常: $e');
      hasFreeTrial.value = false;
    }
  }

  Future<void> loadStoredStatus() async {
    if (config.debugOverride) {
      _applyAccessState(
        const SubscriptionAccessState(
          status: SubscriptionAccessStatus.active,
          evaluatedAtMs: 0,
          note: 'debug override',
        ),
      );
      return;
    }

    final SubscriptionAccessState? storedState = _readStoredAccessState();
    if (storedState != null) {
      _applyAccessState(storedState);
      return;
    }

    _applyAccessState(
      const SubscriptionAccessState(
        status: SubscriptionAccessStatus.unavailable,
        evaluatedAtMs: 0,
        note: 'no cached entitlement',
      ),
    );
  }

  Future<SubscriptionAccessState> refreshAccessState({
    String source = 'manual_refresh',
  }) async {
    if (config.debugOverride) {
      const SubscriptionAccessState overrideState = SubscriptionAccessState(
        status: SubscriptionAccessStatus.active,
        evaluatedAtMs: 0,
        note: 'debug override',
      );
      _applyAccessState(overrideState);
      return overrideState;
    }

    final List<ActiveSubscription>? subscriptions =
        await _queryActiveSubscriptions();
    if (subscriptions != null) {
      try {
        final SubscriptionAccessState resolvedState =
            await _storeAdapter.resolveVerifiedAccessState(
          iap: _iap,
          subscriptions: subscriptions,
          productIds: productIds,
          fallbackProductId: productIds.join(','),
          now: DateTime.now(),
        );
        final SubscriptionAccessState writableState =
            _resolveWritableAccessState(resolvedState);
        await _updateSubscriptionAccessState(writableState);
        _log(
          'refresh subscription access from locally verified entitlements: '
          'source=$source status=${writableState.status.name}, '
          'active=${writableState.shouldGrantAccess}',
        );
        return writableState;
      } on SubscriptionStoreException catch (error) {
        final SubscriptionAccessState unavailableState =
            SubscriptionAccessState(
          status: SubscriptionAccessStatus.unavailable,
          evaluatedAtMs: DateTime.now().millisecondsSinceEpoch,
          productId: productIds.join(','),
          note: error.code,
        );
        await _updateSubscriptionAccessState(unavailableState);
        _log('Local subscription verification failed: ${error.code}');
        return unavailableState;
      } catch (error) {
        _log('Local subscription verification unavailable: $error');
      }
    }

    final SubscriptionAccessState? cachedState = _readStoredAccessState();
    if (cachedState != null) {
      _applyAccessState(cachedState);
      _log(
        'native entitlements unavailable, fallback to cached snapshot: '
        'source=$source status=${cachedState.status.name}, '
        'active=${cachedState.shouldGrantAccess}',
      );
      return cachedState;
    }

    final SubscriptionAccessState unavailableState = SubscriptionAccessState(
      status: SubscriptionAccessStatus.unavailable,
      evaluatedAtMs: DateTime.now().millisecondsSinceEpoch,
      note: 'native entitlements unavailable',
    );
    await _updateSubscriptionAccessState(unavailableState);
    _log(
      'refresh subscription access from native entitlements: '
      'source=$source status=${unavailableState.status.name}, '
      'active=${unavailableState.shouldGrantAccess}',
    );
    return unavailableState;
  }

  Future<void> refreshTrialEligibility() async {
    try {
      hasFreeTrial.value = await _storeAdapter.computeTrialEligibility(
        iap: _iap,
        products: products.value,
        productIds: productIds,
        logger: _log,
      );
    } catch (e) {
      _log('检查订阅历史失败: $e');
      hasFreeTrial.value = false;
    }
  }

  Future<SubscriptionActionResult> purchase(
    ProductSubscription? product, {
    required String source,
    SubscriptionPurchaseOptions options = const SubscriptionPurchaseOptions(),
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

    if (!_storeAdapter.supportsProduct(product)) {
      final SubscriptionActionResult result = SubscriptionActionResult.failure(
        type: SubscriptionActionType.purchase,
        productId: product.id,
        code: 'invalid-product-platform',
        message: 'The subscription product belongs to another store.',
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
      final bool connected = await _ensureIapConnection(source: source);
      if (!connected) {
        _isBuying = false;
        _pendingPurchaseAction = null;
        final SubscriptionActionResult result =
            SubscriptionActionResult.failure(
          type: SubscriptionActionType.purchase,
          productId: product.id,
          code: 'store-unavailable',
          message: 'The app store connection is unavailable.',
        );
        _notifyFinished(source, result);
        return result;
      }
      _listenToPurchaseEvents();
      await _storeAdapter.requestPurchase(
        iap: _iap,
        product: product,
        options: options,
      );
      _log('购买请求已发送');
      final SubscriptionActionResult result = await completer.future;
      _notifyFinished(source, result);
      return result;
    } on SubscriptionStoreException catch (e) {
      _isBuying = false;
      _pendingPurchaseAction = null;
      final SubscriptionActionResult result = SubscriptionActionResult.failure(
        type: SubscriptionActionType.purchase,
        productId: product.id,
        code: e.code,
        message: e.message,
      );
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
      final bool connected = await _ensureIapConnection(source: source);
      if (!connected) {
        final SubscriptionAccessState refreshedState =
            await refreshAccessState(source: source);
        final SubscriptionActionResult result = refreshedState.shouldGrantAccess
            ? SubscriptionActionResult.success(
                type: SubscriptionActionType.restore,
                silent: silent,
                productId: refreshedState.productId,
                message: 'Subscription status is active from cached snapshot.',
              )
            : SubscriptionActionResult.failure(
                type: SubscriptionActionType.restore,
                silent: silent,
                code: 'store-unavailable',
                message: 'The app store connection is unavailable.',
              );
        _notifyFinished(source, result, silent: silent);
        return result;
      }
      _listenToPurchaseEvents();
      final List<Purchase> items = await _storeAdapter.restorePurchases(_iap);
      if (items.isEmpty) {
        final SubscriptionAccessState refreshedState =
            await refreshAccessState(source: source);
        if (refreshedState.shouldGrantAccess) {
          final SubscriptionActionResult result =
              SubscriptionActionResult.success(
            type: SubscriptionActionType.restore,
            silent: silent,
            productId: refreshedState.productId,
            message: 'Subscription status is active.',
          );
          _notifyFinished(source, result, silent: silent);
          return result;
        }
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
      Purchase? latestSuccessPurchase;
      SubscriptionActionResult? processingFailure;
      for (final item in items) {
        if (!_storeAdapter.supportsPurchase(item)) {
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
        } else {
          processingFailure ??= result;
        }
      }
      if (restoredCount > 0) {
        await refreshAccessState(source: '${source}_final');
      }
      await refreshTrialEligibility();

      late final SubscriptionActionResult finalResult;
      if (restoredCount > 0 && accessState.value.shouldGrantAccess) {
        finalResult = SubscriptionActionResult.success(
          type: SubscriptionActionType.restore,
          silent: silent,
          productId: latestSuccessPurchase == null
              ? null
              : _storeAdapter.normalizedProductId(latestSuccessPurchase),
          purchase: latestSuccessPurchase,
          restoredCount: restoredCount,
        );
      } else if (processingFailure != null) {
        finalResult = processingFailure;
      } else if (accessState.value.shouldGrantAccess) {
        finalResult = SubscriptionActionResult.success(
          type: SubscriptionActionType.restore,
          silent: silent,
          productId: accessState.value.productId,
          message: 'Subscription status is active.',
        );
      } else {
        finalResult = SubscriptionActionResult.failure(
          type: SubscriptionActionType.restore,
          silent: silent,
          code: 'restore-inactive',
          message:
              'Restorable purchases were found, but none are currently active.',
        );
      }
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

  ProductSubscription? findProduct(String productId) {
    return catalog.findProduct(products.value, productId);
  }

  List<SubscriptionOffer> findOffers(String productId) {
    final ProductSubscription? product = findProduct(productId);
    if (product == null) {
      return const <SubscriptionOffer>[];
    }
    return _storeAdapter.offersFor(product);
  }

  SubscriptionOffer? findOffer(
    String productId, {
    String? offerId,
    String? basePlanIdAndroid,
  }) {
    final List<SubscriptionOffer> matches =
        findOffers(productId).where((offer) {
      final bool matchesOffer = offerId == null || offer.id == offerId;
      final bool matchesBasePlan = basePlanIdAndroid == null ||
          offer.basePlanIdAndroid == basePlanIdAndroid;
      return matchesOffer && matchesBasePlan;
    }).toList(growable: false);
    return matches.length == 1 ? matches.single : null;
  }

  String yearlyPricePerWeek({
    required String productId,
    required String fallbackPrice,
    required String weekLabel,
  }) {
    return catalog.yearlyPricePerWeek(
      products.value,
      productId: productId,
      fallbackPrice: fallbackPrice,
      weekLabel: weekLabel,
    );
  }

  Future<void> dispose() async {
    _isDisposed = true;
    _unregisterLifecycleObserver();
    await _purchaseUpdatedSubscription?.cancel();
    await _purchaseErrorSubscription?.cancel();
    try {
      await _iap.endConnection();
    } catch (_) {}
    isSubscribed.dispose();
    hasFreeTrial.dispose();
    accessState.dispose();
    products.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      return;
    }
    unawaited(_refreshAccessStateAfterForeground());
  }

  Future<_SubscriptionVerificationResult> _verifyCurrentSubscriptionByItem({
    required Purchase item,
  }) async {
    final String productId = _storeAdapter.normalizedProductId(item);
    final SubscriptionTransactionPayload payload =
        _storeAdapter.transactionPayload(item);
    if (productId.isEmpty || !productIds.contains(productId)) {
      _log(
        'Skip verifying purchase with invalid productId: rawId=${item.id}, productId=${item.productId}',
      );
      final SubscriptionAccessState invalidState = SubscriptionAccessState(
        status: SubscriptionAccessStatus.unavailable,
        evaluatedAtMs: DateTime.now().millisecondsSinceEpoch,
        productId: productId,
        transactionId: payload.currentTransactionId,
        note: 'invalid productId',
      );
      await _updateSubscriptionAccessState(invalidState);
      return _SubscriptionVerificationResult(
        item: item,
        verified: false,
      );
    }

    try {
      await _storeAdapter.verifyPurchaseLocally(iap: _iap, purchase: item);
    } on SubscriptionStoreException catch (error) {
      final SubscriptionAccessState rejectedState = SubscriptionAccessState(
        status: error.code == 'missing-license-key'
            ? SubscriptionAccessStatus.unavailable
            : SubscriptionAccessStatus.revoked,
        evaluatedAtMs: DateTime.now().millisecondsSinceEpoch,
        productId: productId,
        transactionId: payload.currentTransactionId,
        note: error.code,
      );
      await _updateSubscriptionAccessState(rejectedState);
      rethrow;
    }

    final SubscriptionAccessState? verifiedState =
        await _resolveAccessStateFromNativeStatus(
      productId: productId,
      fallbackTransactionId: payload.currentTransactionId,
    );

    if (verifiedState == null) {
      await refreshAccessState(source: 'native_status_unavailable');
      return _SubscriptionVerificationResult(
        item: item,
        verified: false,
      );
    }

    _log(
      'Native status resolved for $productId: '
      'status=${verifiedState.status.name}, active=${verifiedState.shouldGrantAccess}',
    );
    if (verifiedState.shouldGrantAccess && _hasTransactionIdentity(payload)) {
      await _reportTransaction(payload);
    }
    final SubscriptionAccessState writableState =
        _resolveWritableAccessState(verifiedState);
    await _updateSubscriptionAccessState(writableState);

    return _SubscriptionVerificationResult(
      item: item,
      verified: writableState.shouldGrantAccess,
    );
  }

  Future<SubscriptionActionResult> _handlePurchasedItem(
    Purchase item, {
    required SubscriptionActionType actionType,
    required String source,
    bool silent = false,
  }) async {
    final String productId = _storeAdapter.normalizedProductId(item);
    if (_storeAdapter.isPending(item)) {
      _log('购买仍在等待付款确认: productId=$productId');
      return SubscriptionActionResult.failure(
        type: actionType,
        silent: silent,
        productId: productId,
        code: 'purchase-pending',
        message: 'The purchase is pending payment confirmation.',
        pending: true,
        purchase: item,
      );
    }
    final SubscriptionAccessState? blockingState =
        _storeAdapter.blockingAccessState(item);
    if (blockingState != null) {
      await _updateSubscriptionAccessState(blockingState);
      return SubscriptionActionResult.failure(
        type: actionType,
        silent: silent,
        productId: productId,
        code: 'billing-retry',
        message: 'The subscription payment requires attention.',
        purchase: item,
      );
    }
    if (!_storeAdapter.shouldProcessPurchaseUpdate(item)) {
      _log('忽略不需要处理的购买项: state=${item.purchaseState}');
      return SubscriptionActionResult.failure(
        type: actionType,
        silent: silent,
        productId: productId,
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
        productId: productId,
        code: 'busy',
        message: 'Another purchase flow is in progress.',
        purchase: item,
      );
    }

    _isProcessingPurchase = true;
    try {
      _log(
        '处理购买更新: productId=$productId, rawId=${item.id}',
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

      final _SubscriptionVerificationResult verificationResult =
          await _verifyCurrentSubscriptionByItem(item: item);
      final bool verificationSuccess = verificationResult.verified;
      final Purchase purchaseToFinish = verificationResult.item;
      _isBuying = false;

      if (!verificationSuccess) {
        return SubscriptionActionResult.failure(
          type: actionType,
          silent: silent,
          productId: productId,
          code: 'validation-failed',
          message: 'Subscription verification did not confirm active access.',
          purchase: purchaseToFinish,
        );
      }

      await _storeAdapter.finishTransaction(
        iap: _iap,
        purchase: purchaseToFinish,
      );
      await refreshTrialEligibility();

      return SubscriptionActionResult.success(
        type: actionType,
        silent: silent,
        productId: productId,
        purchase: purchaseToFinish,
        message: source,
      );
    } on SubscriptionStoreException catch (e) {
      _log('处理购买项失败: code=${e.code}, message=${e.message}');
      return SubscriptionActionResult.failure(
        type: actionType,
        silent: silent,
        productId: productId,
        code: e.code,
        message: e.message,
        purchase: item,
      );
    } catch (e) {
      _log('处理购买项异常: $e');
      return SubscriptionActionResult.failure(
        type: actionType,
        silent: silent,
        productId: productId,
        code: 'processing-exception',
        message: e.toString(),
        purchase: item,
      );
    } finally {
      _isProcessingPurchase = false;
    }
  }

  Future<void> _reportTransaction(
    SubscriptionTransactionPayload payload,
  ) async {
    final SubscriptionTransactionReporter? reporter =
        config.transactionReporter;
    if (reporter == null) {
      return;
    }

    try {
      await reporter(payload);
    } catch (e) {
      _log('Send transaction to server error: $e');
    }
  }

  bool _hasTransactionIdentity(SubscriptionTransactionPayload payload) {
    return payload.currentTransactionId.isNotEmpty ||
        payload.originalTransactionId.isNotEmpty ||
        (payload.purchaseToken ?? '').isNotEmpty;
  }

  Future<void> _updateSubscriptionAccessState(
    SubscriptionAccessState state,
  ) async {
    await sharedPreferences.setString(
      _cachedAccessStorageKey,
      jsonEncode(state.toJson()),
    );
    _applyAccessState(state);
    _log(
      'update subscription access: '
      'status=${state.status.name}, effectiveUntilMs=${state.effectiveUntilMs}, '
      'effectiveUntil=${_formatExpiration(state.effectiveUntilMs ?? 0)}, '
      'active=${state.shouldGrantAccess}',
    );
  }

  SubscriptionAccessState _resolveWritableAccessState(
    SubscriptionAccessState incomingState,
  ) {
    final SubscriptionAccessState? retainedGraceState =
        _activeGraceStateOrNull(accessState.value) ??
            _activeGraceStateOrNull(_readStoredAccessState());
    if (retainedGraceState == null) {
      return incomingState;
    }

    if (incomingState.status == SubscriptionAccessStatus.expired &&
        incomingState.note == 'no active native entitlement') {
      _log(
        'Retain grace period access while native entitlements are empty: '
        'productId=${retainedGraceState.productId}, '
        'effectiveUntilMs=${retainedGraceState.effectiveUntilMs}',
      );
      return retainedGraceState.copyWith(
        evaluatedAtMs: DateTime.now().millisecondsSinceEpoch,
        note:
            'retained active grace period while native entitlements are empty',
      );
    }

    return incomingState;
  }

  SubscriptionAccessState? _activeGraceStateOrNull(
    SubscriptionAccessState? state,
  ) {
    if (state == null || state.status != SubscriptionAccessStatus.gracePeriod) {
      return null;
    }

    final int effectiveUntilMs = state.effectiveUntilMs ?? 0;
    if (effectiveUntilMs <= DateTime.now().millisecondsSinceEpoch) {
      return null;
    }

    return state;
  }

  void _applyAccessState(SubscriptionAccessState state) {
    final bool active = config.debugOverride ? true : state.shouldGrantAccess;
    accessState.value = state;
    isSubscribed.value = active;
  }

  SubscriptionAccessState? _readStoredAccessState() {
    final String? cached = sharedPreferences.getString(_cachedAccessStorageKey);
    if (cached != null && cached.isNotEmpty) {
      try {
        final dynamic decoded = jsonDecode(cached);
        if (decoded is Map) {
          final SubscriptionAccessState state =
              SubscriptionAccessState.fromJson(decoded);
          final int evaluatedAtMs = state.evaluatedAtMs;
          if (evaluatedAtMs > 0 &&
              DateTime.now().millisecondsSinceEpoch - evaluatedAtMs <=
                  _cachedAccessStateTtl.inMilliseconds) {
            return state;
          }
          _log(
            'Cached access state expired: status=${state.status.name}, '
            'evaluatedAtMs=$evaluatedAtMs',
          );
        }
      } catch (e) {
        _log('Failed to decode cached access state: $e');
      }
    }

    return null;
  }

  String _formatExpiration(int expirationMs) {
    if (expirationMs <= 0) {
      return 'n/a';
    }
    return DateTime.fromMillisecondsSinceEpoch(expirationMs).toIso8601String();
  }

  String get _cachedAccessStorageKey {
    final String? configured = config.accessStateStorageKey;
    return (configured != null && configured.isNotEmpty)
        ? configured
        : 'subscription_access_state';
  }

  static const Duration _cachedAccessStateTtl = Duration(hours: 6);

  bool get _hasInFlightOperation =>
      _isProcessingPurchase || _isBuying || _isRestoring;

  void _registerLifecycleObserver() {
    if (_isLifecycleObserverRegistered) {
      return;
    }
    WidgetsBinding.instance.addObserver(this);
    _isLifecycleObserverRegistered = true;
  }

  void _unregisterLifecycleObserver() {
    if (!_isLifecycleObserverRegistered) {
      return;
    }
    WidgetsBinding.instance.removeObserver(this);
    _isLifecycleObserverRegistered = false;
  }

  Future<bool> _ensureIapConnection({required String source}) {
    if (_isIapConnected) {
      return Future<bool>.value(true);
    }

    final Future<bool>? existingConnection = _iapConnectionFuture;
    if (existingConnection != null) {
      return existingConnection;
    }

    final Future<bool> connectionFuture = _connectIap(source: source);
    _iapConnectionFuture = connectionFuture;
    return connectionFuture;
  }

  Future<bool> _connectIap({required String source}) async {
    try {
      final bool connected = await _iap.initConnection();
      _isIapConnected = connected;
      if (!connected) {
        _log('应用内购买连接不可用: source=$source');
      }
      return connected;
    } catch (e) {
      _isIapConnected = false;
      _log('应用内购买连接失败: source=$source, error=$e');
      return false;
    } finally {
      _iapConnectionFuture = null;
    }
  }

  void _listenToPurchaseEvents() {
    _purchaseUpdatedSubscription ??=
        _iap.purchaseUpdatedListener.listen((Purchase purchase) async {
      if (!_storeAdapter.supportsPurchase(purchase)) {
        return;
      }

      _log(
        '收到购买更新: state=${purchase.purchaseState}, id=${purchase.id}',
      );
      if (_isRestoring) {
        _log('恢复购买进行中，忽略 purchaseUpdated 里的重复恢复事件');
        return;
      }
      if (_isProcessingPurchase) {
        _log('购买处理进行中，忽略重复购买更新');
        return;
      }

      final _PendingPurchaseAction? pendingAction = _pendingPurchaseAction;
      final bool matchesPendingPurchase = pendingAction != null &&
          pendingAction.productId ==
              _storeAdapter.normalizedProductId(purchase);
      if (pendingAction != null && !matchesPendingPurchase) {
        _log('忽略与当前购买商品不匹配的购买更新');
        return;
      }
      final SubscriptionActionType actionType = matchesPendingPurchase
          ? SubscriptionActionType.purchase
          : SubscriptionActionType.sync;
      final SubscriptionActionResult result = await _handlePurchasedItem(
        purchase,
        actionType: actionType,
        source:
            matchesPendingPurchase ? pendingAction.source : 'purchase_update',
      );
      if (matchesPendingPurchase) {
        _isBuying = false;
        _completePendingPurchaseAction(result);
      }
    });

    _purchaseErrorSubscription ??=
        _iap.purchaseErrorListener.listen((PurchaseError event) {
      final String errorCode = event.code?.value ?? '';
      _log('购买错误: code=$errorCode, message=${event.message}');
      final _PendingPurchaseAction? pendingAction = _pendingPurchaseAction;
      final String errorProductId = event.productId ?? '';
      final List<String> errorProductIds = event.productIds ?? const <String>[];
      final bool identifiesAnotherProduct = pendingAction != null &&
          (errorProductId.isNotEmpty || errorProductIds.isNotEmpty) &&
          errorProductId != pendingAction.productId &&
          !errorProductIds.contains(pendingAction.productId);
      if (identifiesAnotherProduct) {
        _log('忽略与当前购买商品不匹配的购买错误');
        return;
      }

      _isBuying = false;
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
      }
      _pendingPurchaseAction = null;
    });
  }

  Future<void> _refreshAccessStateAfterForeground() async {
    if (_isDisposed ||
        _isForegroundRefreshRunning ||
        _hasInFlightOperation ||
        _isRestoring) {
      return;
    }

    _isForegroundRefreshRunning = true;
    try {
      final bool connected = await _ensureIapConnection(source: 'app_resumed');
      if (connected) {
        _listenToPurchaseEvents();
      }
      await refreshAccessState(source: 'app_resumed');
      if (connected && products.value.isEmpty) {
        await loadProducts();
      }
    } finally {
      _isForegroundRefreshRunning = false;
    }
  }

  Future<List<ActiveSubscription>?> _queryActiveSubscriptions() async {
    try {
      final ActiveSubscriptionQuery? query = config.activeSubscriptionQuery;
      if (query != null) {
        return await query(productIds);
      }
      final bool connected =
          await _ensureIapConnection(source: 'query_active_subscriptions');
      if (!connected) {
        return null;
      }
      return await _iap.getActiveSubscriptions(productIds);
    } catch (e) {
      _isIapConnected = false;
      _log('查询活跃订阅权益失败: productIds=$productIds, error=$e');
      return null;
    }
  }

  Future<SubscriptionAccessState?> _resolveAccessStateFromNativeStatus({
    required String productId,
    required String fallbackTransactionId,
  }) async {
    final List<ActiveSubscription>? subscriptions =
        await _queryActiveSubscriptions();
    if (subscriptions == null) {
      return null;
    }

    final List<ActiveSubscription> matchingSubscriptions = subscriptions
        .where((subscription) => subscription.productId == productId)
        .toList(growable: false);
    final SubscriptionAccessState state =
        await _storeAdapter.resolveVerifiedAccessState(
      iap: _iap,
      subscriptions: matchingSubscriptions,
      productIds: <String>[productId],
      fallbackProductId: productId,
      now: DateTime.now(),
    );
    if (state.transactionId.isNotEmpty || fallbackTransactionId.isEmpty) {
      return state;
    }
    return state.copyWith(transactionId: fallbackTransactionId);
  }

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

class _SubscriptionVerificationResult {
  const _SubscriptionVerificationResult({
    required this.item,
    required this.verified,
  });

  final Purchase item;
  final bool verified;
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
