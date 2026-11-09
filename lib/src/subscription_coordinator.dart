import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_store_subscription_adapter.dart';
import 'google_play_subscription_adapter.dart';
import 'subscription_access_state.dart';
import 'subscription_snapshot.dart';
import 'subscription_action_result.dart';
import 'subscription_catalog.dart';
import 'subscription_configuration.dart';
import 'subscription_entitlement_cache.dart';
import 'subscription_failure.dart';
import 'subscription_operation_state.dart';
import 'subscription_plan.dart';
import 'subscription_store_adapter.dart';
import 'subscription_transaction_processor.dart';

/// 编排商品加载、购买、恢复、验证、权益缓存和前台刷新。
class SubscriptionCoordinator with WidgetsBindingObserver {
  /// 创建订阅协调器，并根据当前平台选择默认商店适配器。
  SubscriptionCoordinator({
    SharedPreferences? sharedPreferences,
    required this.config,
    FlutterInappPurchase? iap,
    SubscriptionStoreAdapter? storeAdapter,
  }) : _iap = iap ?? FlutterInappPurchase.instance,
       _providedStoreAdapter = storeAdapter,
       _configuredPlans = List.unmodifiable(config.plans),
       _subscriptionProductIds = config.subscriptionProductIds == null
           ? null
           : List.unmodifiable(config.subscriptionProductIds!.toSet()),
       _cache = SubscriptionEntitlementCache(
         preferences: sharedPreferences,
         storageKey:
             config.accessStateStorageKey ?? 'subscription_access_state',
       ) {
    _publishPlans();
  }

  /// 当前协调器配置。
  final SubscriptionCoordinatorConfig config;
  final FlutterInappPurchase _iap;
  final SubscriptionStoreAdapter? _providedStoreAdapter;
  late final SubscriptionStoreAdapter _storeAdapter =
      _providedStoreAdapter ??
      switch (store) {
        IapStore.Google => GooglePlaySubscriptionAdapter(
          licenseKey: config.googlePlayLicenseKeyAndroid,
        ),
        IapStore.Apple => AppStoreSubscriptionAdapter(
          subscriptionStatusQuery: config.subscriptionStatusQueryIOS,
        ),
        _ => throw UnsupportedError(
          'Subscriptions are supported only on iOS and Android.',
        ),
      };

  late final _transactionProcessor = SubscriptionTransactionProcessor(
    iap: _iap,
    adapter: _storeAdapter,
    productIds: _subscriptionProductIds,
    verifyEntitlement: _verifyPurchaseBeforeCompletion,
    isDisposed: () => _isDisposed,
    log: _log,
    reporter: config.transactionReporter,
    onStoreError: _handleStoreError,
  );

  /// 商品查找和价格展示规则。
  final SubscriptionCatalog catalog = const SubscriptionCatalog();
  final List<SubscriptionPlan> _configuredPlans;
  final SubscriptionEntitlementCache _cache;

  final SubscriptionOperationTracker _activity = SubscriptionOperationTracker();
  ValueListenable<SubscriptionOperationState> get activity => _activity;

  Map<String, SubscriptionTrialEligibility> _trialEligibility = const {};

  IapStore get store => !isSupported
      ? IapStore.Unknown
      : _iap.isAndroid
      ? IapStore.Google
      : IapStore.Apple;

  bool get isSupported => !kIsWeb && (_iap.isIOS || _iap.isAndroid);

  /// 配置可用于当前平台；不代表商店已连接或用户具有订阅权益。
  bool get isConfigured => configurationFailure == null;

  /// 平台、可用工作范围和必需验证配置的统一检查结果。
  SubscriptionFailureCode? get configurationFailure {
    if (!isSupported) return SubscriptionFailureCode.unsupportedPlatform;
    if (productIds.isEmpty && _subscriptionProductIds?.isEmpty == true) {
      return SubscriptionFailureCode.planNotConfigured;
    }
    if (_iap.isAndroid &&
        _providedStoreAdapter == null &&
        config.googlePlayLicenseKeyAndroid.trim().isEmpty) {
      return SubscriptionFailureCode.missingLicenseKey;
    }
    return null;
  }

  SubscriptionPlanDetails planDetails(SubscriptionPlan plan) {
    final failure =
        configurationFailure ??
        (!_configuredPlans.contains(plan)
            ? SubscriptionFailureCode.planNotConfigured
            : null);
    if (failure != null) {
      return SubscriptionPlanDetails(
        plan: plan,
        store: store,
        failureCode: failure,
      );
    }
    return catalog.resolvePlan(
      plan,
      store: store,
      products: _products.value,
      appStoreTrialEligibility:
          _trialEligibility[plan.appStoreProductId] ??
          SubscriptionTrialEligibility.unknown,
    );
  }

  final ValueNotifier<SubscriptionSnapshot> _accessState = ValueNotifier(
    SubscriptionSnapshot(evaluatedAtMs: 0),
  );

  /// 从商店加载的订阅商品。
  final ValueNotifier<List<ProductSubscription>> _products =
      ValueNotifier<List<ProductSubscription>>(<ProductSubscription>[]);

  /// 商店状态快照；宿主按 activeSubscriptions 中的商品身份映射功能。
  ValueListenable<SubscriptionSnapshot> get accessState => _accessState;

  /// 原始商店商品，仅供需要平台特有能力的集成使用。
  ValueListenable<List<ProductSubscription>> get products => _products;

  final ValueNotifier<List<SubscriptionPlanDetails>> _plans = ValueNotifier(
    const [],
  );

  /// 商品与试用资格查询完成后一起发布；刷新期间保留上一份完整快照。
  ValueListenable<List<SubscriptionPlanDetails>> get plans => _plans;

  void _publishPlans() {
    if (_isDisposed) return;
    _plans.value = List.unmodifiable(_configuredPlans.map(planDetails));
  }

  StreamSubscription<Purchase>? _purchaseUpdatedSubscription;
  StreamSubscription<PurchaseError>? _purchaseErrorSubscription;

  _PendingPurchaseAction? _pendingPurchaseAction;
  Timer? _accessRefreshTimer;
  bool _isIapConnected = false;
  bool _isForegroundRefreshRunning = false;
  bool _isDisposed = false;
  WidgetsBinding? _lifecycleBinding;
  Future<bool>? _iapConnectionFuture;
  Future<void>? _iapDisconnectionFuture;
  Future<void>? _initFuture;
  Future<void>? _productsFuture;
  Future<void>? _trialFuture;
  Future<SubscriptionSnapshot>? _accessFuture;
  Future<void> _transactionQueue = Future<void>.value();
  Set<(String, String, String)>? _restoringTransactions;

  /// 当前平台在售套餐的商品标识，仅用于商品加载和购买。
  late final List<String> productIds = List.unmodifiable(
    _configuredPlans
        .map((plan) => plan.productIdFor(store))
        .whereType<String>()
        .where((id) => id.trim().isNotEmpty)
        .toSet(),
  );

  final List<String>? _subscriptionProductIds;

  bool _includesSubscription(String id) =>
      id.isNotEmpty && (_subscriptionProductIds?.contains(id) ?? true);

  /// 初始化缓存、生命周期监听、商店连接、商品列表和本机权益查询。
  Future<void> init() {
    if (_isDisposed) return Future.value();
    return _initFuture ??= _activity.track(
      SubscriptionOperation.initializing,
      _initialize,
    );
  }

  Future<void> _initialize() async {
    if (!isConfigured) return;
    await _loadCachedAccess();
    if (_isDisposed) return;
    _lifecycleBinding = WidgetsBinding.instance..addObserver(this);
    // 连接前注册监听：StoreKit 可能在连接时重放交易。
    _listenToPurchaseEvents();
    final connected = await _ensureIapConnection(source: 'init');
    if (!connected) return;
    await loadProducts();
    // App Store sync 可能弹出账号登录，仅由用户主动恢复时触发。
    await refreshAccessState(source: 'bootstrap');
  }

  /// 查询成功返回 true（商品列表可能为空）；force 为真时重新查询商店。
  Future<bool> loadProducts({bool force = false}) async {
    if (_isDisposed || !isConfigured) return false;
    try {
      await _loadProducts(force: force);
      return !_isDisposed;
    } catch (error) {
      await _handleStoreError(error is PurchaseError ? error.code : null);
      _log('加载订阅商品失败: $error');
      return false;
    }
  }

  Future<void> _loadProducts({bool force = false}) =>
      _productsFuture ??= _activity
          .track(SubscriptionOperation.loadingProducts, () async {
            if (productIds.isEmpty) return;
            if (!force && _products.value.isNotEmpty) return;
            if (!await _ensureIapConnection(source: 'load_products')) {
              throw const SubscriptionStoreException(
                failureCode: SubscriptionFailureCode.storeUnavailable,
                message: 'The store connection is unavailable.',
              );
            }
            final products = await _iap.fetchProducts<ProductSubscription>(
              skus: productIds,
              type: ProductQueryType.Subs,
            );
            if (_isDisposed) return;
            // 等待旧商品的资格查询结束，新商品和资格准备完成后再一起发布。
            await _trialFuture;
            if (_isDisposed) return;
            final eligibility = await _queryTrialEligibility(products);
            if (_isDisposed) return;
            _trialEligibility = eligibility;
            _products.value = List.unmodifiable(products);
            _publishPlans();
          })
          .whenComplete(() => _productsFuture = null);

  /// 从本地快照恢复最近一次可用的权益状态。
  Future<void> _loadCachedAccess() async {
    if (_isDisposed || !isConfigured) return;
    final storedState = await _readConfiguredCache();
    if (_isDisposed) return;
    _applyAccessState(
      storedState ??
          SubscriptionSnapshot(
            evaluatedAtMs: 0,
            subscriptions: [
              for (final id in productIds)
                SubscriptionAccessState(
                  store: store,
                  productId: id,
                  status: SubscriptionAccessStatus.unavailable,
                  evaluatedAtMs: 0,
                ),
            ],
          ),
    );
  }

  Future<SubscriptionSnapshot?> _readConfiguredCache() async {
    final cached = await _cache.read();
    if (cached == null) return null;
    return SubscriptionSnapshot(
      evaluatedAtMs: cached.evaluatedAtMs,
      subscriptions: cached.subscriptions.where(
        (s) => _includesSubscription(s.productId),
      ),
      queryFailedProductIds: cached.queryFailedProductIds.where(
        _includesSubscription,
      ),
    );
  }

  /// 查询识别范围内的订阅，保留每项状态；失败只回退相应商品的证据。
  Future<SubscriptionSnapshot> refreshAccessState({
    String source = 'manual_refresh',
  }) {
    if (_isDisposed || !isConfigured) return Future.value(_accessState.value);
    return _accessFuture ??= _activity
        .track(
          SubscriptionOperation.refreshingAccess,
          () => _refreshAccessState(source: source),
        )
        .whenComplete(() => _accessFuture = null);
  }

  Future<SubscriptionSnapshot> _refreshAccessAfterTransaction({
    required String source,
  }) async {
    await _accessFuture;
    return refreshAccessState(source: source);
  }

  Future<SubscriptionSnapshot> _refreshAccessState({
    required String source,
  }) async {
    SubscriptionSnapshot fresh;
    SubscriptionSnapshot? cached;
    var completeQueryFailure = false;
    try {
      fresh = await _queryVerifiedSnapshot();
    } catch (error) {
      await _handleStoreError(error is PurchaseError ? error.code : null);
      _log('商店权益查询失败: $error');
      final canUseCache =
          error is! SubscriptionStoreException ||
          error.failureCode == SubscriptionFailureCode.storeUnavailable ||
          error.failureCode == SubscriptionFailureCode.storeQueryFailed;
      completeQueryFailure = canUseCache;
      cached = canUseCache ? await _readConfiguredCache() : null;
      final knownIds = <String>{
        ...?_subscriptionProductIds,
        ...productIds.where(_includesSubscription),
        ..._accessState.value.subscriptions.map((s) => s.productId),
        ...?cached?.subscriptions.map((s) => s.productId),
      }.where(_includesSubscription);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      fresh = SubscriptionSnapshot(
        evaluatedAtMs: nowMs,
        queryFailedProductIds: canUseCache ? knownIds : const [],
        subscriptions: [
          for (final id in knownIds)
            SubscriptionAccessState(
              store: store,
              productId: id,
              status: SubscriptionAccessStatus.unavailable,
              evaluatedAtMs: nowMs,
              reason: canUseCache
                  ? SubscriptionAccessReason.storeQueryFailed
                  : SubscriptionAccessReason.localVerificationFailed,
            ),
        ],
      );
    }
    if (_isDisposed) return _accessState.value;
    cached ??= fresh.queryFailedProductIds.isEmpty
        ? null
        : await _readConfiguredCache();
    final fallback =
        cached?.subscriptions
            .where((s) => fresh.queryFailedProductIds.contains(s.productId))
            .toList() ??
        const <SubscriptionAccessState>[];
    final snapshot = SubscriptionSnapshot(
      evaluatedAtMs: fresh.evaluatedAtMs,
      queryFailedProductIds: fresh.queryFailedProductIds,
      subscriptions: [
        ...fresh.subscriptions.where(
          (s) => !fresh.queryFailedProductIds.contains(s.productId),
        ),
        ...fallback,
        for (final id in fresh.queryFailedProductIds)
          if (!fallback.any((s) => s.productId == id))
            SubscriptionAccessState(
              store: store,
              productId: id,
              status: SubscriptionAccessStatus.unavailable,
              evaluatedAtMs: fresh.evaluatedAtMs,
              reason: SubscriptionAccessReason.storeQueryFailed,
            ),
      ],
    );
    final allRecordsFailed =
        fresh.queryFailedProductIds.isNotEmpty &&
        fresh.subscriptions.every(
          (s) => fresh.queryFailedProductIds.contains(s.productId),
        );
    if (completeQueryFailure || allRecordsFailed) {
      _applyAccessState(snapshot);
    } else {
      await _updateSubscriptionAccessState(snapshot);
    }
    return snapshot;
  }

  Future<SubscriptionSnapshot> _queryVerifiedSnapshot({
    Purchase? purchase,
  }) async {
    if (_subscriptionProductIds?.isEmpty == true) {
      return SubscriptionSnapshot(
        evaluatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
    }
    final query = config.verifiedSubscriptionQuery;
    if (query != null) {
      final snapshot = await query(
        SubscriptionVerificationRequest(
          store: store,
          productIds: _subscriptionProductIds,
          purchase: purchase,
        ),
      );
      return SubscriptionSnapshot(
        evaluatedAtMs: snapshot.evaluatedAtMs,
        subscriptions: snapshot.subscriptions.where(
          (s) => s.store == store && _includesSubscription(s.productId),
        ),
        queryFailedProductIds: snapshot.queryFailedProductIds.where(
          _includesSubscription,
        ),
      );
    }
    final subscriptions = await _queryActiveSubscriptions(
      _subscriptionProductIds,
    );
    return _storeAdapter.resolveVerifiedAccessState(
      iap: _iap,
      subscriptions: subscriptions,
      products: _products.value,
      productIds: _subscriptionProductIds,
    );
  }

  Future<void> _verifyPurchaseBeforeCompletion(Purchase purchase) async {
    // 未注册的 Apple 交易必须带有原生订阅组，避免完成普通内购交易。
    if (purchase is PurchaseIOS &&
        !productIds.contains(purchase.productId) &&
        (purchase.subscriptionGroupIdIOS?.isEmpty ?? true)) {
      throw const SubscriptionStoreException(
        failureCode: SubscriptionFailureCode.unknownSku,
        message: 'The transaction is not an auto-renewable subscription.',
      );
    }
    // Apple 对已验证交易 finish；Google 必须先证实对应权益，再 acknowledge。
    if (purchase is! PurchaseAndroid &&
        config.verifiedSubscriptionQuery == null)
      return;
    final snapshot = await _queryVerifiedSnapshot(purchase: purchase);
    if (purchase is! PurchaseAndroid) return;
    final ownsEntitlement = snapshot.subscriptions.any(
      (s) =>
          !s.fromCache &&
          !snapshot.queryFailedProductIds.contains(s.productId) &&
          s.shouldGrantAccess &&
          s.purchaseTokenAndroid == purchase.purchaseToken &&
          (s.productId == purchase.productId ||
              s.renewal?.nextProductId == purchase.productId),
    );
    if (!ownsEntitlement) {
      throw SubscriptionStoreException(
        failureCode: snapshot.queryFailedProductIds.contains(purchase.productId)
            ? SubscriptionFailureCode.storeQueryFailed
            : productIds.contains(purchase.productId)
            ? SubscriptionFailureCode.subscriptionInactive
            : SubscriptionFailureCode.unknownSku,
        message:
            'No verified entitlement is associated with this purchase token.',
      );
    }
  }

  /// 根据商店商品与账户状态刷新免费试用资格。
  Future<void> refreshTrialEligibility() {
    if (_isDisposed || !isConfigured) return Future.value();
    // 商品刷新已包含针对新商品的资格查询，避免再查询旧商品。
    if (_productsFuture case final loading?) {
      return loading.catchError((Object error) {
        _log('等待商品刷新失败: $error');
      });
    }
    return _trialFuture ??= _refreshTrialEligibility().whenComplete(
      () => _trialFuture = null,
    );
  }

  Future<void> _refreshTrialEligibility() async {
    final eligibility = await _queryTrialEligibility(_products.value);
    if (_isDisposed) return;
    _trialEligibility = eligibility;
    _publishPlans();
  }

  Future<Map<String, SubscriptionTrialEligibility>> _queryTrialEligibility(
    List<ProductSubscription> products,
  ) =>
      _activity.track(SubscriptionOperation.checkingTrialEligibility, () async {
        try {
          return Map.unmodifiable(
            await _storeAdapter.queryTrialEligibility(
              iap: _iap,
              products: products,
            ),
          );
        } catch (e) {
          _log('检查订阅历史失败: $e');
          return const {};
        }
      });

  /// 按配置套餐选择已加载的商品和优惠，缺少商品时先查询，再等待商店事件。
  Future<SubscriptionActionResult> purchasePlan(
    SubscriptionPlan plan, {
    required String source,
    SubscriptionPurchaseOptions options = const SubscriptionPurchaseOptions(),
  }) => _runAction(
    type: SubscriptionActionType.purchase,
    source: source,
    productId: plan.productIdFor(store),
    work: () async {
      final initial = planDetails(plan);
      if (initial.failureCode == SubscriptionFailureCode.planNotConfigured ||
          initial.failureCode ==
              SubscriptionFailureCode.invalidProductPlatform) {
        return SubscriptionActionResult.failure(
          type: SubscriptionActionType.purchase,
          productId: initial.productId,
          failureCode: initial.failureCode,
        );
      }
      // OpenIAP Google 4.0.3 在购买时刷新原生商品详情并校验优惠令牌；
      // Apple 按商品 ID 查找原生商品，本层不重复查询或重置展示资格。
      if (_productsFuture case final loading?) {
        await loading;
      } else if (initial.product == null) {
        await _loadProducts(force: true);
      }
      if (_isDisposed)
        return SubscriptionActionResult.failure(
          type: SubscriptionActionType.purchase,
          productId: initial.productId,
          failureCode: SubscriptionFailureCode.disposed,
        );
      final details = planDetails(plan);
      if (!details.canPurchase) {
        return SubscriptionActionResult.failure(
          type: SubscriptionActionType.purchase,
          productId: details.productId,
          failureCode: details.failureCode,
        );
      }
      return _dispatchPurchase(
        details,
        source: source,
        offer: details.offer,
        options: options,
      );
    },
  );

  Future<SubscriptionActionResult> _runAction({
    required SubscriptionActionType type,
    required String source,
    String? productId,
    bool silent = false,
    required Future<SubscriptionActionResult> Function() work,
  }) async {
    final failure = _isDisposed
        ? SubscriptionFailureCode.disposed
        : configurationFailure ??
              (_activity.value.isBusy ? SubscriptionFailureCode.busy : null);
    if (failure != null) {
      final result = SubscriptionActionResult.failure(
        type: type,
        productId: productId,
        silent: silent,
        failureCode: failure,
      );
      _notifyFinished(source, result);
      return result;
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
          await init();
          result = _isDisposed
              ? SubscriptionActionResult.failure(
                  type: type,
                  productId: productId,
                  silent: silent,
                  failureCode: SubscriptionFailureCode.disposed,
                )
              : await work();
        } on SubscriptionStoreException catch (error) {
          result = SubscriptionActionResult.failure(
            type: type,
            productId: productId,
            silent: silent,
            failureCode: error.failureCode,
            message: error.message,
          );
        } on PurchaseError catch (error) {
          await _handleStoreError(error.code);
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
    SubscriptionPlanDetails details, {
    required String source,
    required SubscriptionOffer? offer,
    required SubscriptionPurchaseOptions options,
  }) async {
    final product = details.product!;
    if (_isDisposed) {
      return SubscriptionActionResult.failure(
        type: SubscriptionActionType.purchase,
        failureCode: SubscriptionFailureCode.disposed,
      );
    }
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
      plan: details.plan,
      completer: completer,
    );
    final action = _pendingPurchaseAction!;
    Future<SubscriptionActionResult> request() async {
      await _validateReplacement(options.replacementAndroid);
      // 等待旧购买验证时可能已超时或释放，不能随后再启动付款。
      if (!identical(_pendingPurchaseAction, action) || _isDisposed) {
        return SubscriptionActionResult(
          type: SubscriptionActionType.purchase,
          outcome: SubscriptionActionOutcome.unconfirmed,
          productId: product.id,
        );
      }
      await _storeAdapter.requestPurchase(
        iap: _iap,
        product: product,
        offer: offer,
        options: options,
      );
      // Apple 预约变更与 Google 延后替换不一定产生目标商品的新交易。
      await _transactionQueue;
      if (completer.isCompleted) return completer.future;
      if (!identical(_pendingPurchaseAction, action))
        return SubscriptionActionResult(
          type: SubscriptionActionType.purchase,
          outcome: SubscriptionActionOutcome.unconfirmed,
          productId: product.id,
        );
      final snapshot = await _refreshAccessAfterTransaction(
        source: 'purchase_request_returned',
      );
      if (completer.isCompleted) return completer.future;
      if (_purchaseEffect(snapshot, action.plan) ==
          SubscriptionPurchaseEffect.scheduled) {
        return SubscriptionActionResult.success(
          type: SubscriptionActionType.purchase,
          productId: product.id,
          effect: SubscriptionPurchaseEffect.scheduled,
        );
      }
      // 事件可能稍后送达；有效商品本身不能证明本次请求已完成或已确认交易。
      return completer.future;
    }

    try {
      return await Future.any([completer.future, request()]).timeout(
        config.purchaseTimeout,
        onTimeout: () => SubscriptionActionResult(
          type: SubscriptionActionType.purchase,
          outcome: SubscriptionActionOutcome.unconfirmed,
          productId: product.id,
        ),
      );
    } finally {
      if (identical(_pendingPurchaseAction, action))
        _pendingPurchaseAction = null;
    }
  }

  SubscriptionPurchaseEffect? _purchaseEffect(
    SubscriptionSnapshot snapshot,
    SubscriptionPlan plan,
  ) {
    final productId = plan.productIdFor(store);
    final records = snapshot.subscriptions.where(
      (s) =>
          !s.fromCache && !snapshot.queryFailedProductIds.contains(s.productId),
    );
    if (records.any(
      (s) =>
          s.shouldGrantAccess &&
          s.productId == productId &&
          (store != IapStore.Google ||
              s.basePlanIdAndroid == plan.googlePlay?.basePlanId),
    )) {
      return SubscriptionPurchaseEffect.applied;
    }
    if (records.any(
      (s) =>
          s.shouldGrantAccess &&
          s.renewal?.autoRenewEnabled == true &&
          s.renewal?.nextProductId == productId &&
          (store != IapStore.Google ||
              s.renewal?.nextBasePlanIdAndroid ==
                  plan.googlePlay?.basePlanId) &&
          (s.productId != productId ||
              store == IapStore.Google &&
                  s.basePlanIdAndroid != plan.googlePlay?.basePlanId),
    )) {
      return SubscriptionPurchaseEffect.scheduled;
    }
    return null;
  }

  Future<void> _validateReplacement(GooglePlayReplacement? replacement) async {
    if (replacement == null) return;
    if (store != IapStore.Google) {
      throw const SubscriptionStoreException(
        failureCode: SubscriptionFailureCode.invalidReplacement,
        message: 'Google Play replacement options cannot be used on Apple.',
      );
    }
    if (config.verifiedSubscriptionQuery == null) {
      throw const SubscriptionStoreException(
        failureCode: SubscriptionFailureCode.verificationRequired,
        message:
            'Google Play replacement requires server-verified subscription line items.',
      );
    }
    final purchases = await _storeAdapter.restorePurchases(_iap);
    final matches = purchases
        .where(
          (p) =>
              p is PurchaseAndroid &&
              p.productId == replacement.oldProductId &&
              p.purchaseToken == replacement.purchaseToken &&
              p.purchaseState == PurchaseState.Purchased,
        )
        .toList();
    if (matches.length != 1) {
      throw const SubscriptionStoreException(
        failureCode: SubscriptionFailureCode.invalidReplacement,
        message: 'The purchase to replace is not currently owned.',
      );
    }
    await _storeAdapter.verifyPurchaseLocally(
      iap: _iap,
      purchase: matches.single,
    );
  }

  /// 恢复购买并重新计算当前订阅权益；silent 只影响工作状态和操作事件。
  Future<SubscriptionActionResult> restore({
    String source = 'manual_restore',
    bool silent = false,
  }) => _runAction(
    type: SubscriptionActionType.restore,
    source: source,
    silent: silent,
    work: () =>
        _enqueueTransaction(() => _restore(source: source, silent: silent)),
  );

  Future<SubscriptionActionResult> _restore({
    required String source,
    required bool silent,
  }) async {
    final restoredTransactions = <(String, String, String)>{};
    _restoringTransactions = restoredTransactions;
    try {
      final connected = await _ensureIapConnection(source: source);
      if (_isDisposed) {
        return SubscriptionActionResult.failure(
          type: SubscriptionActionType.restore,
          silent: silent,
          failureCode: SubscriptionFailureCode.disposed,
        );
      }
      if (!connected) {
        return SubscriptionActionResult.failure(
          type: SubscriptionActionType.restore,
          silent: silent,
          failureCode: SubscriptionFailureCode.storeUnavailable,
        );
      }
      final items = (await _storeAdapter.restorePurchases(_iap))
          .where(
            (item) =>
                _storeAdapter.supportsPurchase(item) &&
                _includesSubscription(item.productId),
          )
          .toList();
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
        final result = await _transactionProcessor.process(
          item,
          type: SubscriptionActionType.restore,
          source: source,
          silent: silent,
        );
        if (result.success) {
          if (item.id.isNotEmpty)
            restoredTransactions.add((item.storeId, item.productId, item.id));
          restoredCount++;
          latestSuccessPurchase = result.purchase;
        } else {
          processingFailure ??= result;
        }
      }
      await _refreshAccessAfterTransaction(source: '${source}_final');
      await refreshTrialEligibility();
      if (_isDisposed) {
        return SubscriptionActionResult.failure(
          type: SubscriptionActionType.restore,
          silent: silent,
          failureCode: SubscriptionFailureCode.disposed,
        );
      }
      if (items.isEmpty) {
        // 恢复流程完成不等于获得权益，宿主始终通过 accessState 做门禁。
        return SubscriptionActionResult.success(
          type: SubscriptionActionType.restore,
          silent: silent,
          message: 'No restorable purchases were found.',
        );
      }
      if (restoredCount > 0 &&
          _accessState.value.activeSubscriptions.any((s) => !s.fromCache)) {
        return SubscriptionActionResult.success(
          type: SubscriptionActionType.restore,
          silent: silent,
          productId: latestSuccessPurchase!.productId,
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
    } finally {
      _restoringTransactions = null;
    }
  }

  /// 取消监听、断开商店连接并释放所有通知器。
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    _accessRefreshTimer?.cancel();
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
    _lifecycleBinding?.removeObserver(this);
    await _purchaseUpdatedSubscription?.cancel();
    await _purchaseErrorSubscription?.cancel();
    if (_isIapConnected || _iapDisconnectionFuture != null) {
      await _invalidateIapConnection(reason: 'dispose');
    }
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

  Future<void> _updateSubscriptionAccessState(
    SubscriptionSnapshot state,
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
      'subscriptions=${state.subscriptions.length}, '
      'active=${state.shouldGrantAccess}',
    );
  }

  void _applyAccessState(SubscriptionSnapshot state) {
    if (_isDisposed) return;
    _accessState.value = state;
    _accessRefreshTimer?.cancel();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final boundaries = <int>[
      for (final record in state.activeSubscriptions) ...[
        if (record.effectiveUntilMs != null) record.effectiveUntilMs!,
        if (record.renewal?.expectedRenewalAtMs != null)
          record.renewal!.expectedRenewalAtMs!,
        if (record.fromCache)
          record.evaluatedAtMs +
              SubscriptionEntitlementCache.ttl.inMilliseconds,
      ],
    ].where((time) => time > nowMs).toList()..sort();
    if (boundaries.isNotEmpty) {
      _accessRefreshTimer = Timer(
        Duration(milliseconds: boundaries.first - nowMs),
        () {
          unawaited(refreshAccessState(source: 'subscription_boundary'));
        },
      );
    }
  }

  Future<bool> _ensureIapConnection({required String source}) {
    if (_isDisposed || !isConfigured) return Future.value(false);
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
      await _iapDisconnectionFuture;
      if (_isDisposed) return false;
      // 插件维护共享连接状态，并处理原生 connection-updated 通知。
      final bool connected = await _iap.initConnection();
      if (_isDisposed) {
        await _invalidateIapConnection(reason: 'disposed_during_connection');
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

  Future<void> _invalidateIapConnection({required String reason}) =>
      _iapDisconnectionFuture ??= _disconnectIap(
        reason,
      ).whenComplete(() => _iapDisconnectionFuture = null);

  Future<void> _disconnectIap(String reason) async {
    _isIapConnected = false;
    _log('使应用内购买连接失效: reason=$reason');
    try {
      await _iap.endConnection();
    } catch (error) {
      _log('关闭失效的应用内购买连接失败: $error');
    }
  }

  Future<void> _handleStoreError(ErrorCode? code) async {
    if (_isDisposed) return;
    if (switch (code) {
      ErrorCode.NotPrepared ||
      ErrorCode.ServiceDisconnected ||
      ErrorCode.ConnectionClosed ||
      ErrorCode.InitConnection => true,
      _ => false,
    })
      await _invalidateIapConnection(reason: code!.value);
  }

  Future<T> _enqueueTransaction<T>(Future<T> Function() work) {
    final result = _transactionQueue.then((_) => work());
    // 各调用方自行处理结果；失败不能阻塞后续商店事件。
    _transactionQueue = result.then<void>(
      (_) {},
      onError: (Object error) {
        _log('交易队列任务失败: $error');
      },
    );
    return result;
  }

  void _listenToPurchaseEvents() {
    if (_isDisposed || !isConfigured) return;
    _purchaseUpdatedSubscription ??= _iap.purchaseUpdatedListener.listen((
      purchase,
    ) {
      if (_isDisposed) return;
      final pendingAction = _pendingPurchaseAction;
      final restoredTransactions = _restoringTransactions;
      unawaited(
        _enqueueTransaction(() async {
          if (_isDisposed) return;
          if (purchase.id.isNotEmpty &&
              restoredTransactions?.contains((
                    purchase.storeId,
                    purchase.productId,
                    purchase.id,
                  )) ==
                  true)
            return;
          await _activity.track(
            SubscriptionOperation.processingPurchase,
            () =>
                _processPurchaseUpdate(purchase, pendingAction: pendingAction),
          );
        }),
      );
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

      unawaited(_handleStoreError(event.code));

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

  Future<void> _processPurchaseUpdate(
    Purchase purchase, {
    required _PendingPurchaseAction? pendingAction,
  }) async {
    if (!_storeAdapter.supportsPurchase(purchase)) {
      return;
    }

    _log('收到购买更新: state=${purchase.purchaseState}, id=${purchase.id}');
    // 按事件到达时的操作关联，不能把排队中的旧交易匹配到后来发起的购买。
    final matchesPendingPurchase =
        pendingAction != null &&
        identical(pendingAction, _pendingPurchaseAction) &&
        pendingAction.productId == purchase.productId;
    final SubscriptionActionType actionType = matchesPendingPurchase
        ? SubscriptionActionType.purchase
        : SubscriptionActionType.sync;
    if (!matchesPendingPurchase) {
      _notifyStarted(
        type: SubscriptionActionType.sync,
        source: 'purchase_update',
        productId: purchase.productId,
        silent: true,
      );
    }
    var result = await _transactionProcessor.process(
      purchase,
      type: actionType,
      source: matchesPendingPurchase ? pendingAction.source : 'purchase_update',
      silent: !matchesPendingPurchase,
    );
    if ((result.failureCode != SubscriptionFailureCode.unknownSku ||
            _includesSubscription(purchase.productId)) &&
        result.failureCode != SubscriptionFailureCode.purchasePending &&
        result.failureCode != SubscriptionFailureCode.ignoredState) {
      final snapshot = await _refreshAccessAfterTransaction(
        source: 'purchase_update',
      );
      if (matchesPendingPurchase && result.success) {
        final effect = _purchaseEffect(snapshot, pendingAction.plan);
        result = effect != null
            ? SubscriptionActionResult.success(
                type: SubscriptionActionType.purchase,
                productId: purchase.productId,
                purchase: purchase,
                effect: effect,
              )
            : SubscriptionActionResult(
                type: SubscriptionActionType.purchase,
                outcome: SubscriptionActionOutcome.unconfirmed,
                productId: purchase.productId,
                purchase: purchase,
              );
      }
      // 延后替换可能只更新旧商品交易；仅新鲜的续订目标可以结束目标等待。
      if (!matchesPendingPurchase &&
          pendingAction != null &&
          identical(pendingAction, _pendingPurchaseAction) &&
          _purchaseEffect(snapshot, pendingAction.plan) ==
              SubscriptionPurchaseEffect.scheduled) {
        _completePendingPurchaseAction(
          SubscriptionActionResult.success(
            type: SubscriptionActionType.purchase,
            productId: pendingAction.productId,
            effect: SubscriptionPurchaseEffect.scheduled,
          ),
        );
      }
      if (result.success) await refreshTrialEligibility();
    }
    if (!matchesPendingPurchase) {
      _notifyFinished('purchase_update', result, silent: true);
    }
    if (matchesPendingPurchase) {
      _completePendingPurchaseAction(result);
    }
  }

  Future<void> _refreshAccessStateAfterForeground() async {
    if (_isDisposed || !isConfigured || _isForegroundRefreshRunning) {
      return;
    }

    _isForegroundRefreshRunning = true;
    try {
      await refreshAccessState(source: 'app_resumed');
      if (_isIapConnected && !_activity.value.isBusy)
        await loadProducts(force: true);
    } finally {
      _isForegroundRefreshRunning = false;
    }
  }

  Future<List<ActiveSubscription>> _queryActiveSubscriptions(
    List<String>? requestedProductIds,
  ) async {
    final query = config.activeSubscriptionQuery;
    if (query != null) return query(requestedProductIds);
    if (!await _ensureIapConnection(source: 'query_active_subscriptions')) {
      throw const SubscriptionStoreException(
        failureCode: SubscriptionFailureCode.storeUnavailable,
        message: 'The store connection is unavailable.',
      );
    }
    return _iap.getActiveSubscriptions(requestedProductIds);
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
    if (_isDisposed) return;
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

class _PendingPurchaseAction {
  const _PendingPurchaseAction({
    required this.productId,
    required this.source,
    required this.completer,
    required this.plan,
  });

  final String productId;
  final String source;
  final Completer<SubscriptionActionResult> completer;
  final SubscriptionPlan plan;
}
