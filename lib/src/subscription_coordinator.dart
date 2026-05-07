import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ios_subscription_helper.dart';
import 'subscription_access_state.dart';
import 'subscription_action_result.dart';
import 'subscription_catalog.dart';

typedef SubscriptionLogger = void Function(String message);
typedef SubscriptionTransactionReporter = Future<void> Function(
  SubscriptionTransactionPayload payload,
);
typedef SubscriptionActionObserver = void Function(
    SubscriptionActionEvent event);
typedef ActiveSubscriptionQuery = Future<List<ActiveSubscription>> Function(
  List<String>? productIds,
);

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
    this.accessStateStorageKey,
    this.debugOverride = false,
    this.logger,
    this.transactionReporter,
    this.actionObserver,
    this.activeSubscriptionQuery,
  });

  final List<SubscriptionProductConfig> products;
  final String? yearlyProductId;
  final String? accessStateStorageKey;
  final bool debugOverride;
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
  final ValueNotifier<SubscriptionAccessState> accessState =
      ValueNotifier<SubscriptionAccessState>(
    const SubscriptionAccessState(
      status: SubscriptionAccessStatus.unavailable,
      evaluatedAtMs: 0,
      note: 'not evaluated',
    ),
  );
  final ValueNotifier<List<ProductSubscriptionIOS>> products =
      ValueNotifier<List<ProductSubscriptionIOS>>(<ProductSubscriptionIOS>[]);

  final Completer<void> _readyCompleter = Completer<void>();

  StreamSubscription<Purchase?>? _purchaseUpdatedSubscription;
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
    final bool connected = await _ensureIapConnection(source: 'load_products');
    if (!connected) {
      _log('跳过商品加载：应用内购买连接暂不可用');
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
      final SubscriptionAccessState resolvedState =
          IosSubscriptionHelper.resolveAccessStateFromActiveSubscriptions(
        subscriptions,
        fallbackProductId: productIds.join(','),
        now: DateTime.now(),
      );
      final SubscriptionAccessState writableState =
          _resolveWritableAccessState(resolvedState);
      await _updateSubscriptionAccessState(writableState);
      _log(
        'refresh subscription access from native entitlements: '
        'source=$source status=${writableState.status.name}, '
        'active=${writableState.shouldGrantAccess}',
      );
      return writableState;
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
      final bool connected = await _ensureIapConnection(source: source);
      if (!connected) {
        _isBuying = false;
        _pendingPurchaseAction = null;
        final SubscriptionActionResult result =
            SubscriptionActionResult.failure(
          type: SubscriptionActionType.purchase,
          productId: product.id,
          code: 'storekit-unavailable',
          message: 'StoreKit is unavailable. Check network permission.',
        );
        _notifyFinished(source, result);
        return result;
      }
      _listenToPurchaseEvents();
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
                code: 'storekit-unavailable',
                message: 'StoreKit is unavailable. Check network permission.',
              );
        _notifyFinished(source, result, silent: silent);
        return result;
      }
      _listenToPurchaseEvents();
      if (Platform.isIOS) {
        await _iap.restorePurchases();
      }
      final List<Purchase> items = await _iap.getAvailablePurchases();
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
          ? (accessState.value.shouldGrantAccess
              ? SubscriptionActionResult.success(
                  type: SubscriptionActionType.restore,
                  silent: silent,
                  productId: accessState.value.productId,
                  message: 'Subscription status is active.',
                )
              : SubscriptionActionResult.failure(
                  type: SubscriptionActionType.restore,
                  silent: silent,
                  code: 'restore-inactive',
                  message:
                      'Restorable purchases were found, but none are currently active.',
                ))
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
    _isDisposed = true;
    _unregisterLifecycleObserver();
    await _purchaseUpdatedSubscription?.cancel();
    await _purchaseErrorSubscription?.cancel();
    try {
      _iap.endConnection();
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

  Future<SubscriptionVerificationResult> _verifyCurrentSubscriptionByItem({
    PurchaseIOS? item,
  }) async {
    final String productId = IosSubscriptionHelper.normalizedProductId(item);
    if (productId.isEmpty || !productIds.contains(productId)) {
      _log(
        'Skip verifying purchase with invalid productId: rawId=${item?.id}, productId=${item?.productId}',
      );
      final SubscriptionAccessState invalidState = SubscriptionAccessState(
        status: SubscriptionAccessStatus.unavailable,
        evaluatedAtMs: DateTime.now().millisecondsSinceEpoch,
        productId: productId,
        transactionId: item?.transactionIdFor ?? '',
        note: 'invalid productId',
      );
      await _updateSubscriptionAccessState(invalidState);
      return SubscriptionVerificationResult(accessState: invalidState);
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
      _log(
          'Local receipt validation unavailable for $productId, using native status');
    } else if (!validationResult.isValid) {
      _log(
          'Local receipt validation failed for $productId, using native status');
    }

    if (validationResult != null &&
        validationResult.latestTransaction != null) {
      verifiedItem = validationResult.latestTransaction;
    }

    final SubscriptionAccessState? verifiedState =
        await _resolveAccessStateFromNativeStatus(
      productId: productId,
      fallbackTransactionId: verifiedItem?.transactionIdFor ?? '',
    );

    if (verifiedState == null) {
      final SubscriptionAccessState fallbackState =
          await refreshAccessState(source: 'native_status_unavailable');
      if (validationResult?.isValid == true && verifiedItem != null) {
        await _reportTransaction(verifiedItem);
      }
      return SubscriptionVerificationResult(
        accessState: fallbackState,
        resolvedItem: verifiedItem,
      );
    }

    _log(
      'Native status resolved for $productId: '
      'status=${verifiedState.status.name}, active=${verifiedState.shouldGrantAccess}, '
      'tx=${verifiedItem?.transactionIdFor}',
    );
    if (validationResult?.isValid == true && verifiedItem != null) {
      await _reportTransaction(verifiedItem);
    }
    final SubscriptionAccessState writableState =
        _resolveWritableAccessState(verifiedState);
    await _updateSubscriptionAccessState(writableState);

    return SubscriptionVerificationResult(
      accessState: writableState,
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

  bool get _hasInFlightOperation => _isProcessingPurchase || _isBuying;

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

    _purchaseErrorSubscription ??=
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
        IosSubscriptionHelper.resolveAccessStateFromActiveSubscriptions(
      matchingSubscriptions,
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
