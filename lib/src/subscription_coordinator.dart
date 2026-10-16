import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'subscription_access_state.dart';
import 'subscription_action_result.dart';
import 'subscription_catalog.dart';
import 'ios_subscription_helper.dart';
import 'subscription_store_adapter.dart';
import 'subscription_transaction.dart';
import 'subscription_failure.dart';
import 'subscription_operation_state.dart';
import 'subscription_plan.dart';
import 'subscription_configuration.dart';
import 'subscription_entitlement_cache.dart';

/// 编排商品加载、购买、恢复、验证、权益缓存和前台刷新。
class SubscriptionCoordinator with WidgetsBindingObserver {
  /// 创建订阅协调器，并根据当前平台选择默认商店适配器。
  SubscriptionCoordinator({
    required this.sharedPreferences,
    required this.config,
    FlutterInappPurchase? iap,
    SubscriptionStoreAdapter? storeAdapter,
  }) : _iap = iap ?? FlutterInappPurchase.instance,
       _storeAdapter =
           storeAdapter ??
           SubscriptionStoreAdapter.forIap(
             iap ?? FlutterInappPurchase.instance,
             googlePlayLicenseKeyAndroid: config.googlePlayLicenseKeyAndroid,
             subscriptionStatusQueryIOS: config.subscriptionStatusQueryIOS,
           ),
       _configuredPlans = List.unmodifiable(config.plans),
       _cache = SubscriptionEntitlementCache(
         preferences: sharedPreferences,
         storageKey:
             config.accessStateStorageKey ?? 'subscription_access_state',
       ) {
    _publishPlans();
  }

  /// 权益快照使用的持久化存储。
  final SharedPreferences sharedPreferences;

  /// 当前协调器配置。
  final SubscriptionCoordinatorConfig config;
  final FlutterInappPurchase _iap;
  final SubscriptionStoreAdapter _storeAdapter;

  /// 商品查找和价格展示规则。
  final SubscriptionCatalog catalog = const SubscriptionCatalog();
  final List<SubscriptionPlan> _configuredPlans;
  final SubscriptionEntitlementCache _cache;

  final SubscriptionOperationTracker _activity = SubscriptionOperationTracker();
  ValueListenable<SubscriptionOperationState> get activity => _activity;

  Map<String, SubscriptionTrialEligibility> _trialEligibility = const {};

  IapStore get store => _iap.isAndroid ? IapStore.Google : IapStore.Apple;

  SubscriptionPlanDetails planDetails(SubscriptionPlan plan) =>
      catalog.resolvePlan(
        plan,
        store: store,
        products: _products.value,
        appStoreTrialEligibility:
            _trialEligibility[plan.appStoreProductId] ??
            SubscriptionTrialEligibility.unknown,
      );

  /// 当前统一订阅权益状态。
  final ValueNotifier<SubscriptionAccessState> _accessState =
      ValueNotifier<SubscriptionAccessState>(
        const SubscriptionAccessState(
          status: SubscriptionAccessStatus.unavailable,
          evaluatedAtMs: 0,
          note: 'not evaluated',
        ),
      );

  /// 从商店加载的订阅商品。
  final ValueNotifier<List<ProductSubscription>> _products =
      ValueNotifier<List<ProductSubscription>>(<ProductSubscription>[]);

  /// 唯一的权益来源；宿主通过 shouldGrantAccess 决定是否开放功能。
  ValueListenable<SubscriptionAccessState> get accessState => _accessState;

  /// 原始商店商品，仅供需要平台特有能力的集成使用。
  ValueListenable<List<ProductSubscription>> get products => _products;

  final ValueNotifier<List<SubscriptionPlanDetails>> _plans = ValueNotifier(
    const [],
  );

  /// 套餐的价格、可购买状态和试用资格变化时发布新快照。
  ValueListenable<List<SubscriptionPlanDetails>> get plans => _plans;

  void _publishPlans() {
    if (_isDisposed) return;
    _plans.value = List.unmodifiable(_configuredPlans.map(planDetails));
  }

  final Completer<void> _readyCompleter = Completer<void>();

  StreamSubscription<Purchase>? _purchaseUpdatedSubscription;
  StreamSubscription<PurchaseError>? _purchaseErrorSubscription;

  _PendingPurchaseAction? _pendingPurchaseAction;
  bool _isIapConnected = false;
  bool _isLifecycleObserverRegistered = false;
  bool _isForegroundRefreshRunning = false;
  bool _isDisposed = false;
  Future<bool>? _iapConnectionFuture;
  Future<void>? _initFuture;
  Future<bool>? _productsFuture;
  Future<void>? _trialFuture;
  Future<SubscriptionAccessState>? _accessFuture;
  Future<void> _purchaseEventQueue = Future<void>.value();

  /// 在初始化流程结束时完成，无论商店当前是否可用。
  Future<void> get ready => _readyCompleter.future;

  /// 初始化流程是否已经结束。
  bool get isReady => _readyCompleter.isCompleted;

  /// 配置中的全部订阅商品标识。
  List<String> get productIds => List.unmodifiable(
    _configuredPlans
        .map((plan) => plan.productIdFor(store))
        .whereType<String>()
        .toSet(),
  );

  /// 初始化缓存、生命周期监听、商店连接、商品列表和本机权益查询。
  Future<void> init() {
    if (_isDisposed)
      return Future.error(StateError('SubscriptionCoordinator is disposed.'));
    return _initFuture ??= _activity.track(
      SubscriptionOperation.initializing,
      _initialize,
    );
  }

  Future<void> _initialize() async {
    try {
      await loadStoredStatus();
      if (_isDisposed) return;
      _registerLifecycleObserver();

      _listenToPurchaseEvents();
      final bool connected = await _ensureIapConnection(source: 'init');
      if (!connected) {
        _log('应用内购买暂不可用，等待网络权限或前台恢复后重试');
        return;
      }

      _listenToPurchaseEvents();
      await loadProducts();
      // 启动只查询设备上已有的 StoreKit 权益，不执行 App Store sync。
      // sync 可能弹出 Apple ID 登录界面，仅由用户主动恢复时触发。
      await refreshAccessState(source: 'bootstrap');
    } finally {
      if (!_readyCompleter.isCompleted) {
        _readyCompleter.complete();
      }
    }
  }

  /// 查询成功返回 true（商品列表可能为空）；force 为真时重新查询商店。
  Future<bool> loadProducts({bool force = false}) {
    if (_isDisposed)
      return Future.error(StateError('SubscriptionCoordinator is disposed.'));
    return _productsFuture ??= _activity
        .track(
          SubscriptionOperation.loadingProducts,
          () => _loadProducts(force: force),
        )
        .whenComplete(() => _productsFuture = null);
  }

  Future<bool> _loadProducts({bool force = false}) async {
    if (!force && _products.value.isNotEmpty) {
      return true;
    }
    if (productIds.isEmpty) {
      _log('跳过商品加载：未配置订阅商品');
      _products.value = <ProductSubscription>[];

      return false;
    }
    final bool connected = await _ensureIapConnection(source: 'load_products');
    if (!connected) {
      _log('跳过商品加载：应用内购买连接暂不可用');
      return false;
    }
    try {
      final List<ProductSubscription> rawList = await _iap
          .fetchProducts<ProductSubscription>(
            skus: productIds,
            type: ProductQueryType.Subs,
          );
      if (_isDisposed) return false;
      _products.value = List.unmodifiable(rawList);
      _trialEligibility = const {};
      _publishPlans();
      await refreshTrialEligibility();
      return !_isDisposed;
    } on PurchaseError catch (e) {
      _isIapConnected = false;
      await _invalidateIapConnection(reason: 'load_products_error');
      _log('加载订阅商品失败: code=${e.code?.value ?? ''}, message=${e.message}');
    } catch (e) {
      _isIapConnected = false;
      await _invalidateIapConnection(reason: 'load_products_exception');
      _log('加载订阅商品异常: $e');
    }
    return false;
  }

  /// 从本地快照恢复最近一次可用的权益状态。
  Future<void> loadStoredStatus() async {
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

  /// 查询商店并刷新统一权益状态。
  Future<SubscriptionAccessState> refreshAccessState({
    String source = 'manual_refresh',
  }) {
    if (_isDisposed) return Future.value(_accessState.value);
    return _accessFuture ??= _activity
        .track(
          SubscriptionOperation.refreshingAccess,
          () => _refreshAccessState(source: source),
        )
        .whenComplete(() => _accessFuture = null);
  }

  Future<SubscriptionAccessState> _refreshAccessState({
    String source = 'manual_refresh',
  }) async {
    final List<ActiveSubscription>? subscriptions =
        await _queryActiveSubscriptions();
    if (subscriptions != null) {
      try {
        final SubscriptionAccessState resolvedState = await _storeAdapter
            .resolveVerifiedAccessState(
              iap: _iap,
              subscriptions: subscriptions,
              products: _products.value,
              productIds: productIds,
              fallbackProductId: productIds.join(','),
              now: DateTime.now(),
            );
        await _updateSubscriptionAccessState(resolvedState);
        _log(
          'refresh subscription access from locally verified entitlements: '
          'source=$source status=${resolvedState.status.name}, '
          'active=${resolvedState.shouldGrantAccess}',
        );
        return resolvedState;
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

  /// 根据商店商品与账户状态刷新免费试用资格。
  Future<void> refreshTrialEligibility() {
    if (_isDisposed) return Future.value();
    return _trialFuture ??= _activity
        .track(
          SubscriptionOperation.checkingTrialEligibility,
          _refreshTrialEligibility,
        )
        .whenComplete(() => _trialFuture = null);
  }

  Future<void> _refreshTrialEligibility() async {
    try {
      final eligibility = await _storeAdapter.queryTrialEligibility(
        iap: _iap,
        products: _products.value,
      );
      if (_isDisposed) return;
      _trialEligibility = Map.unmodifiable(eligibility);
      _publishPlans();
    } catch (e) {
      _log('检查订阅历史失败: $e');
      if (_isDisposed) return;
      _trialEligibility = const {};
      _publishPlans();
    }
  }

  /// 推荐入口：按配置套餐加载商品、精确选择 offer，再等待商店事件。
  Future<SubscriptionActionResult> purchasePlan(
    SubscriptionPlan plan, {
    required String source,
    SubscriptionPurchaseOptions options = const SubscriptionPurchaseOptions(),
  }) => _runAction(
    type: SubscriptionActionType.purchase,
    source: source,
    productId: plan.productIdFor(store),
    work: () async {
      if (!_configuredPlans.contains(plan)) {
        return SubscriptionActionResult.failure(
          type: SubscriptionActionType.purchase,
          failureCode: SubscriptionFailureCode.planNotConfigured,
        );
      }
      if (plan.productIdFor(store) == null) {
        return SubscriptionActionResult.failure(
          type: SubscriptionActionType.purchase,
          failureCode: SubscriptionFailureCode.invalidProductPlatform,
        );
      }
      // Google 不建议长期缓存商品详情；购买前重新获取当前价格和优惠令牌。
      if (!await loadProducts(force: true)) {
        return SubscriptionActionResult.failure(
          type: SubscriptionActionType.purchase,
          productId: plan.productIdFor(store),
          failureCode: _isDisposed
              ? SubscriptionFailureCode.disposed
              : SubscriptionFailureCode.storeUnavailable,
        );
      }
      final details = planDetails(plan);
      if (!details.canPurchase) {
        return SubscriptionActionResult.failure(
          type: SubscriptionActionType.purchase,
          productId: details.productId,
          failureCode: details.failureCode,
        );
      }
      if (options.offer != null) {
        return SubscriptionActionResult.failure(
          type: SubscriptionActionType.purchase,
          productId: details.productId,
          failureCode: SubscriptionFailureCode.invalidOffer,
          message:
              'purchasePlan selects its offer from the plan configuration.',
        );
      }
      return _dispatchPurchase(
        details.product!,
        source: source,
        options: options.withOffer(details.offer),
      );
    },
  );

  /// 低层入口：调用方自己负责商品与 offer 的一致性，通常优先使用 purchasePlan。
  Future<SubscriptionActionResult> purchaseProduct(
    ProductSubscription product, {
    required String source,
    SubscriptionPurchaseOptions options = const SubscriptionPurchaseOptions(),
  }) => _runAction(
    type: SubscriptionActionType.purchase,
    source: source,
    productId: product.id,
    work: () async {
      return _dispatchPurchase(product, source: source, options: options);
    },
  );

  Future<SubscriptionActionResult> _runAction({
    required SubscriptionActionType type,
    required String source,
    String? productId,
    bool silent = false,
    required Future<SubscriptionActionResult> Function() work,
  }) async {
    if (_isDisposed || _hasInFlightOperation) {
      return SubscriptionActionResult.failure(
        type: type,
        productId: productId,
        silent: silent,
        failureCode: _isDisposed
            ? SubscriptionFailureCode.disposed
            : SubscriptionFailureCode.busy,
      );
    }
    final fallbackCode = type == SubscriptionActionType.restore
        ? SubscriptionFailureCode.restoreException
        : SubscriptionFailureCode.requestFailed;
    return _activity.track(
      type == SubscriptionActionType.restore
          ? SubscriptionOperation.restoring
          : SubscriptionOperation.purchasing,
      () async {
        _notifyStarted(
          type: type,
          source: source,
          productId: productId,
          silent: silent,
        );
        late SubscriptionActionResult result;
        try {
          result = await work();
        } on SubscriptionStoreException catch (error) {
          result = SubscriptionActionResult.failure(
            type: type,
            productId: productId,
            silent: silent,
            failureCode: error.failureCode,
            message: error.message,
          );
        } on PurchaseError catch (error) {
          if (_isConnectionError(error)) {
            await _invalidateIapConnection(
              reason: error.code?.value ?? 'store_error',
            );
          }
          result = SubscriptionActionResult.failure(
            type: type,
            productId: productId,
            silent: silent,
            storeErrorCode: error.code,
            failureCode: error.code == null ? fallbackCode : null,
            message: error.message,
          );
        } catch (error) {
          result = SubscriptionActionResult.failure(
            type: type,
            productId: productId,
            silent: silent,
            failureCode: _isDisposed
                ? SubscriptionFailureCode.disposed
                : fallbackCode,
            message: error.toString(),
          );
        } finally {
          if (type == SubscriptionActionType.purchase)
            _pendingPurchaseAction = null;
        }
        _notifyFinished(source, result);
        return result;
      },
      productId: productId,
      silent: silent,
    );
  }

  Future<SubscriptionActionResult> _dispatchPurchase(
    ProductSubscription product, {
    required String source,
    required SubscriptionPurchaseOptions options,
  }) async {
    if (_isDisposed) {
      return SubscriptionActionResult.failure(
        type: SubscriptionActionType.purchase,
        failureCode: SubscriptionFailureCode.disposed,
      );
    }
    if (!_storeAdapter.supportsProduct(product)) {
      return SubscriptionActionResult.failure(
        type: SubscriptionActionType.purchase,
        productId: product.id,
        failureCode: SubscriptionFailureCode.invalidProductPlatform,
      );
    }
    if (!productIds.contains(product.id)) {
      return SubscriptionActionResult.failure(
        type: SubscriptionActionType.purchase,
        productId: product.id,
        failureCode: SubscriptionFailureCode.unknownSku,
      );
    }
    // 连接前注册监听：StoreKit 可能在连接时重放交易。
    _listenToPurchaseEvents();
    final connected = await _ensureIapConnection(source: source);
    if (_isDisposed) {
      return SubscriptionActionResult.failure(
        type: SubscriptionActionType.purchase,
        productId: product.id,
        failureCode: SubscriptionFailureCode.disposed,
      );
    }
    if (!connected) {
      return SubscriptionActionResult.failure(
        type: SubscriptionActionType.purchase,
        productId: product.id,
        failureCode: SubscriptionFailureCode.storeUnavailable,
      );
    }
    final completer = Completer<SubscriptionActionResult>();
    _pendingPurchaseAction = _PendingPurchaseAction(
      productId: product.id,
      source: source,
      completer: completer,
    );
    // 原生请求尚未返回时，交易事件或 dispose 也能完成调用者等待的 Future。
    return Future.any([
      completer.future,
      _storeAdapter
          .requestPurchase(iap: _iap, product: product, options: options)
          .then((_) => completer.future),
    ]);
  }

  /// 恢复购买并重新计算当前订阅权益；silent 只影响宿主 loading 和事件。
  Future<SubscriptionActionResult> restore({
    String source = 'manual_restore',
    bool silent = false,
  }) => _runAction(
    type: SubscriptionActionType.restore,
    source: source,
    silent: silent,
    work: () => _restore(source: source, silent: silent),
  );

  Future<SubscriptionActionResult> _restore({
    required String source,
    required bool silent,
  }) async {
    final connected = await _ensureIapConnection(source: source);
    if (_isDisposed) {
      return SubscriptionActionResult.failure(
        type: SubscriptionActionType.restore,
        silent: silent,
        failureCode: SubscriptionFailureCode.disposed,
      );
    }
    if (!connected) {
      await refreshAccessState(source: source);
      return SubscriptionActionResult.failure(
        type: SubscriptionActionType.restore,
        silent: silent,
        failureCode: SubscriptionFailureCode.storeUnavailable,
      );
    }
    _listenToPurchaseEvents();
    final items = (await _storeAdapter.restorePurchases(_iap))
        .where(
          (item) =>
              _storeAdapter.supportsPurchase(item) &&
              productIds.contains(_storeAdapter.normalizedProductId(item)),
        )
        .toList();
    if (items.isEmpty) {
      await refreshAccessState(source: source);
      await refreshTrialEligibility();
      // 恢复流程完成不等于获得权益，宿主始终通过 accessState 做门禁。
      return SubscriptionActionResult.success(
        type: SubscriptionActionType.restore,
        silent: silent,
        message: 'No restorable purchases were found.',
      );
    }
    int restoredCount = 0;
    Purchase? latestSuccessPurchase;
    SubscriptionActionResult? processingFailure;
    for (final item in items) {
      if (_isDisposed) {
        return SubscriptionActionResult.failure(
          type: SubscriptionActionType.restore,
          silent: silent,
          failureCode: SubscriptionFailureCode.disposed,
        );
      }
      final result = await _handlePurchasedItem(
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
    if (restoredCount > 0) await refreshAccessState(source: '${source}_final');
    await refreshTrialEligibility();
    if (restoredCount > 0 && _accessState.value.shouldGrantAccess) {
      return SubscriptionActionResult.success(
        type: SubscriptionActionType.restore,
        silent: silent,
        productId: _storeAdapter.normalizedProductId(latestSuccessPurchase!),
        purchase: latestSuccessPurchase,
        restoredCount: restoredCount,
      );
    }
    return processingFailure ??
        SubscriptionActionResult.failure(
          type: SubscriptionActionType.restore,
          silent: silent,
          failureCode: SubscriptionFailureCode.restoreInactive,
          message:
              'Restorable purchases were found, but none are currently active.',
        );
  }

  /// 取消监听、断开商店连接并释放所有通知器。
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    final pending = _pendingPurchaseAction;
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.complete(
        SubscriptionActionResult.failure(
          type: SubscriptionActionType.purchase,
          productId: pending.productId,
          failureCode: SubscriptionFailureCode.disposed,
        ),
      );
    }
    _unregisterLifecycleObserver();
    await _purchaseUpdatedSubscription?.cancel();
    await _purchaseErrorSubscription?.cancel();
    try {
      await _iap.endConnection();
    } catch (_) {}
    _accessState.dispose();
    _products.dispose();
    _plans.dispose();
    _activity.dispose();
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
    final SubscriptionTransactionPayload payload = _storeAdapter
        .transactionPayload(item);
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
      return _SubscriptionVerificationResult(item: item, verified: false);
    }

    try {
      await _storeAdapter.verifyPurchaseLocally(iap: _iap, purchase: item);
    } on SubscriptionStoreException catch (error) {
      final SubscriptionAccessState rejectedState = SubscriptionAccessState(
        status: error.failureCode == SubscriptionFailureCode.missingLicenseKey
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

    SubscriptionAccessState? verifiedState;
    final bool retryAndroidEntitlementQuery = item is PurchaseAndroid;
    for (int attempt = 0; attempt < 3; attempt++) {
      verifiedState = await _resolveAccessStateFromNativeStatus(
        productId: productId,
        fallbackTransactionId: payload.currentTransactionId,
        verifiedPurchase: item,
      );
      final bool shouldRetry =
          retryAndroidEntitlementQuery &&
          (verifiedState == null ||
              (verifiedState.status == SubscriptionAccessStatus.expired &&
                  verifiedState.reason ==
                      SubscriptionAccessReason.noCurrentSubscription));
      if (!shouldRetry || attempt == 2) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }

    if (verifiedState == null) {
      await refreshAccessState(source: 'native_status_unavailable');
      return _SubscriptionVerificationResult(item: item, verified: false);
    }

    _log(
      'Native status resolved for $productId: '
      'status=${verifiedState.status.name}, active=${verifiedState.shouldGrantAccess}',
    );
    if (verifiedState.shouldGrantAccess && _hasTransactionIdentity(payload)) {
      await _reportTransaction(payload);
    }
    await _updateSubscriptionAccessState(verifiedState);

    return _SubscriptionVerificationResult(
      item: item,
      verified: verifiedState.shouldGrantAccess,
    );
  }

  Future<SubscriptionActionResult> _handlePurchasedItem(
    Purchase item, {
    required SubscriptionActionType actionType,
    required String source,
    bool silent = false,
  }) async {
    final String productId = _storeAdapter.normalizedProductId(item);
    if (productId.isEmpty || !productIds.contains(productId)) {
      return SubscriptionActionResult.failure(
        type: actionType,
        silent: silent,
        productId: productId,
        failureCode: SubscriptionFailureCode.unknownSku,
        message: 'Purchase product ID is not managed by this service.',
        purchase: item,
      );
    }
    if (_storeAdapter.isPending(item)) {
      _log('购买仍在等待付款确认: productId=$productId');
      return SubscriptionActionResult.failure(
        type: actionType,
        silent: silent,
        productId: productId,
        failureCode: SubscriptionFailureCode.purchasePending,
        message: 'The purchase is pending payment confirmation.',
        purchase: item,
      );
    }
    final SubscriptionAccessState? blockingState = _storeAdapter
        .blockingAccessState(item);
    if (blockingState != null) {
      await _updateSubscriptionAccessState(blockingState);
      return SubscriptionActionResult.failure(
        type: actionType,
        silent: silent,
        productId: productId,
        failureCode: SubscriptionFailureCode.billingRetry,
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
        failureCode: SubscriptionFailureCode.ignoredState,
        message: 'Purchase state is not eligible for processing.',
        purchase: item,
      );
    }
    try {
      _log('处理购买更新: productId=$productId, rawId=${item.id}');
      final _SubscriptionVerificationResult verificationResult =
          await _verifyCurrentSubscriptionByItem(item: item);
      final bool verificationSuccess = verificationResult.verified;
      final Purchase purchaseToFinish = verificationResult.item;

      if (!verificationSuccess) {
        return SubscriptionActionResult.failure(
          type: actionType,
          silent: silent,
          productId: productId,
          failureCode: SubscriptionFailureCode.validationFailed,
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
        failureCode: e.failureCode,
        message: e.message,
        purchase: item,
      );
    } on PurchaseError catch (error) {
      return SubscriptionActionResult.failure(
        type: actionType,
        silent: silent,
        productId: productId,
        storeErrorCode: error.code,
        message: error.message,
        failureCode: error.code == null
            ? SubscriptionFailureCode.processingException
            : null,
        purchase: item,
      );
    } catch (e) {
      _log('处理购买项异常: $e');
      return SubscriptionActionResult.failure(
        type: actionType,
        silent: silent,
        productId: productId,
        failureCode: SubscriptionFailureCode.processingException,
        message: e.toString(),
        purchase: item,
      );
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
    if (_isDisposed) return;
    _applyAccessState(state);
    try {
      await _cache.write(state);
    } catch (error) {
      _log('持久化权益快照失败: $error');
    }
    _log(
      'update subscription access: '
      'status=${state.status.name}, effectiveUntilMs=${state.effectiveUntilMs}, '
      'effectiveUntil=${_formatExpiration(state.effectiveUntilMs ?? 0)}, '
      'active=${state.shouldGrantAccess}',
    );
  }

  void _applyAccessState(SubscriptionAccessState state) {
    if (_isDisposed) return;
    _accessState.value = state;
  }

  SubscriptionAccessState? _readStoredAccessState() => _cache.read();

  String _formatExpiration(int expirationMs) {
    if (expirationMs <= 0) {
      return 'n/a';
    }
    return DateTime.fromMillisecondsSinceEpoch(expirationMs).toIso8601String();
  }

  bool get _hasInFlightOperation => _activity.value.isBusy;
  bool get _isRestoring => _activity.value.isRestoring;

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
    if (_isDisposed) return Future.value(false);
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
      if (_isDisposed) {
        await _iap.endConnection();
        return false;
      }
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

  Future<void> _invalidateIapConnection({required String reason}) async {
    _isIapConnected = false;
    _log('使应用内购买连接失效: reason=$reason');
    try {
      await _iap.endConnection();
    } catch (error) {
      _log('关闭失效的应用内购买连接失败: $error');
    }
  }

  bool _isConnectionError(PurchaseError error) {
    final ErrorCode? code = error.code;
    return code == ErrorCode.Unknown ||
        code == ErrorCode.NotPrepared ||
        code == ErrorCode.ServiceDisconnected ||
        code == ErrorCode.ServiceTimeout ||
        code == ErrorCode.ConnectionClosed ||
        code == ErrorCode.BillingUnavailable ||
        code == ErrorCode.IapNotAvailable ||
        code == ErrorCode.ActivityUnavailable;
  }

  void _listenToPurchaseEvents() {
    if (_isDisposed) return;
    _purchaseUpdatedSubscription ??= _iap.purchaseUpdatedListener.listen((
      purchase,
    ) {
      if (_isDisposed || _isRestoring) return;
      _purchaseEventQueue = _purchaseEventQueue
          .then((_) async {
            if (_isDisposed) return;
            await _activity.track(
              SubscriptionOperation.processingPurchase,
              () => _processPurchaseUpdate(purchase),
            );
          })
          .catchError((Object error) {
            _log('Purchase event processing failed: $error');
          });
    });

    _purchaseErrorSubscription ??= _iap.purchaseErrorListener.listen((
      PurchaseError event,
    ) {
      if (_isDisposed) return;
      final String errorCode = event.code?.value ?? '';
      _log('购买错误: code=$errorCode, message=${event.message}');
      final _PendingPurchaseAction? pendingAction = _pendingPurchaseAction;
      final String errorProductId = event.productId ?? '';
      final List<String> errorProductIds = event.productIds ?? const <String>[];
      final bool identifiesAnotherProduct =
          pendingAction != null &&
          (errorProductId.isNotEmpty || errorProductIds.isNotEmpty) &&
          errorProductId != pendingAction.productId &&
          !errorProductIds.contains(pendingAction.productId);
      if (identifiesAnotherProduct) {
        _log('忽略与当前购买商品不匹配的购买错误');
        return;
      }

      if (_isConnectionError(event)) {
        unawaited(
          _invalidateIapConnection(
            reason: errorCode.isEmpty ? 'purchase_error' : errorCode,
          ),
        );
      }

      if (pendingAction != null && !pendingAction.completer.isCompleted) {
        final SubscriptionActionResult result =
            SubscriptionActionResult.failure(
              type: SubscriptionActionType.purchase,
              productId: pendingAction.productId,
              storeErrorCode: event.code,
              failureCode: event.code == null
                  ? SubscriptionFailureCode.requestFailed
                  : null,
              message: event.message,
            );
        pendingAction.completer.complete(result);
      }
      _pendingPurchaseAction = null;
    });
  }

  Future<void> _processPurchaseUpdate(Purchase purchase) async {
    if (!_storeAdapter.supportsPurchase(purchase)) {
      return;
    }

    _log('收到购买更新: state=${purchase.purchaseState}, id=${purchase.id}');
    if (_isRestoring) {
      _log('恢复购买进行中，忽略 purchaseUpdated 里的重复恢复事件');
      return;
    }

    final _PendingPurchaseAction? pendingAction = _pendingPurchaseAction;
    final bool matchesPendingPurchase =
        pendingAction != null &&
        pendingAction.productId == _storeAdapter.normalizedProductId(purchase);
    if (pendingAction != null && !matchesPendingPurchase) {
      _log('忽略与当前购买商品不匹配的购买更新');
      return;
    }
    final SubscriptionActionType actionType = matchesPendingPurchase
        ? SubscriptionActionType.purchase
        : SubscriptionActionType.sync;
    if (!matchesPendingPurchase) {
      _notifyStarted(
        type: SubscriptionActionType.sync,
        source: 'purchase_update',
        productId: _storeAdapter.normalizedProductId(purchase),
        silent: true,
      );
    }
    final SubscriptionActionResult result = await _handlePurchasedItem(
      purchase,
      actionType: actionType,
      source: matchesPendingPurchase ? pendingAction.source : 'purchase_update',
      silent: !matchesPendingPurchase,
    );
    if (!matchesPendingPurchase) {
      _notifyFinished('purchase_update', result, silent: true);
    }
    if (matchesPendingPurchase) {
      _completePendingPurchaseAction(result);
    }
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
      if (connected) await loadProducts(force: true);
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
      final bool connected = await _ensureIapConnection(
        source: 'query_active_subscriptions',
      );
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
    Purchase? verifiedPurchase,
  }) async {
    final List<ActiveSubscription>? subscriptions =
        await _queryActiveSubscriptions();
    if (subscriptions == null) {
      return null;
    }

    final List<ActiveSubscription> matchingSubscriptions = subscriptions
        .where((subscription) => subscription.productId == productId)
        .toList(growable: false);
    final List<ActiveSubscription> entitlements = List<ActiveSubscription>.of(
      matchingSubscriptions,
    );
    if (entitlements.isEmpty && verifiedPurchase is PurchaseIOS) {
      entitlements.add(
        IosSubscriptionHelper.activeSubscriptionFromPurchase(verifiedPurchase),
      );
    }
    final SubscriptionAccessState state = await _storeAdapter
        .resolveVerifiedAccessState(
          iap: _iap,
          subscriptions: entitlements,
          products: _products.value,
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
    _observe(
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
    _observe(
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

  void _observe(SubscriptionActionEvent event) {
    try {
      config.actionObserver?.call(event);
    } catch (error) {
      _log('Subscription observer failed: $error');
    }
  }

  void _log(String message) {
    try {
      config.logger?.call(message);
    } catch (_) {
      // 日志回调异常不能影响购买或权益结果。
    }
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
