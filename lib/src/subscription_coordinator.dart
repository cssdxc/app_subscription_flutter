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

/// 接收订阅模块诊断日志。
typedef SubscriptionLogger = void Function(String message);

/// 接收通过验证且已获得权益的交易载荷。
typedef SubscriptionTransactionReporter = Future<void> Function(
  SubscriptionTransactionPayload payload,
);

/// 观察购买、恢复和同步操作的开始与结束事件。
typedef SubscriptionActionObserver = void Function(
    SubscriptionActionEvent event);

/// 查询指定商品对应的当前订阅；主要用于测试或替换默认商店查询。
typedef ActiveSubscriptionQuery = Future<List<ActiveSubscription>> Function(
  List<String>? productIds,
);

/// 订阅操作事件所处的阶段。
enum SubscriptionActionPhase {
  /// 操作已经开始。
  started,

  /// 操作已经结束。
  finished,
}

/// 提供给宿主应用埋点或加载态管理的订阅操作事件。
class SubscriptionActionEvent {
  /// 创建一个订阅操作生命周期事件。
  const SubscriptionActionEvent({
    required this.phase,
    required this.type,
    required this.source,
    this.silent = false,
    this.productId,
    this.result,
  });

  /// 当前事件阶段。
  final SubscriptionActionPhase phase;

  /// 当前操作类型。
  final SubscriptionActionType type;

  /// 调用方传入的操作来源标识。
  final String source;

  /// 是否为静默操作。
  final bool silent;

  /// 操作关联的商品标识。
  final String? productId;

  /// 结束事件对应的操作结果；开始事件为空。
  final SubscriptionActionResult? result;
}

/// 单个订阅商品的静态配置。
class SubscriptionProductConfig {
  /// 创建单个订阅商品配置。
  const SubscriptionProductConfig({
    required this.id,
    required this.defaultPrice,
  });

  /// App Store Connect 或 Play Console 中配置的商品标识。
  final String id;

  /// 商店价格暂不可用时使用的展示价格。
  final String defaultPrice;
}

/// 订阅协调器的商品、验证和回调配置。
class SubscriptionCoordinatorConfig {
  /// 创建订阅协调器配置。
  const SubscriptionCoordinatorConfig({
    required this.products,
    this.accessStateStorageKey,
    this.debugOverride = false,
    this.googlePlayLicenseKeyAndroid = '',
    this.logger,
    this.transactionReporter,
    this.actionObserver,
    this.activeSubscriptionQuery,
    this.subscriptionStatusQueryIOS,
  });

  /// 应用支持的订阅商品集合。
  final List<SubscriptionProductConfig> products;

  /// 权益快照在 SharedPreferences 中的自定义存储键。
  final String? accessStateStorageKey;

  /// 是否在调试环境中强制授予订阅权益。
  final bool debugOverride;

  /// Play Console 提供的 Base64 编码 RSA 公钥。
  final String googlePlayLicenseKeyAndroid;

  /// 可选的诊断日志回调。
  final SubscriptionLogger? logger;

  /// 可选的已验证交易回传回调。
  final SubscriptionTransactionReporter? transactionReporter;

  /// 可选的订阅操作生命周期观察器。
  final SubscriptionActionObserver? actionObserver;

  /// 可选的当前订阅查询替身；未提供时直接查询商店。
  final ActiveSubscriptionQuery? activeSubscriptionQuery;

  /// 可选的 StoreKit 2 订阅状态查询替身；未提供时直接调用插件。
  final SubscriptionStatusQueryIOS? subscriptionStatusQueryIOS;
}

/// 编排商品加载、购买、恢复、验证、权益缓存和前台刷新。
class SubscriptionCoordinator with WidgetsBindingObserver {
  /// 创建订阅协调器，并根据当前平台选择默认商店适配器。
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
              subscriptionStatusQueryIOS: config.subscriptionStatusQueryIOS,
            ),
        catalog = SubscriptionCatalog(
          defaultPrices: {
            for (final product in config.products)
              product.id: product.defaultPrice,
          },
        );

  /// 权益快照使用的持久化存储。
  final SharedPreferences sharedPreferences;

  /// 当前协调器配置。
  final SubscriptionCoordinatorConfig config;
  final FlutterInappPurchase _iap;
  final SubscriptionStoreAdapter _storeAdapter;

  /// 商品查找和价格展示规则。
  final SubscriptionCatalog catalog;

  /// 兼容旧调用方的订阅权益布尔值。
  final ValueNotifier<bool> isSubscribed = ValueNotifier<bool>(false);

  /// 当前商品集合是否包含可用的免费试用。
  final ValueNotifier<bool> hasFreeTrial = ValueNotifier<bool>(true);

  /// 当前统一订阅权益状态。
  final ValueNotifier<SubscriptionAccessState> accessState =
      ValueNotifier<SubscriptionAccessState>(
    const SubscriptionAccessState(
      status: SubscriptionAccessStatus.unavailable,
      evaluatedAtMs: 0,
      note: 'not evaluated',
    ),
  );

  /// 从商店加载的订阅商品。
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

  /// 在初始化流程结束时完成，无论商店当前是否可用。
  Future<void> get ready => _readyCompleter.future;

  /// 初始化流程是否已经结束。
  bool get isReady => _readyCompleter.isCompleted;

  /// 配置中的全部订阅商品标识。
  List<String> get productIds =>
      config.products.map((product) => product.id).toList(growable: false);

  /// 初始化缓存、生命周期监听、商店连接、商品列表和本机权益查询。
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

  /// 从商店加载订阅商品；[force] 为真时忽略内存缓存。
  Future<void> loadProducts({bool force = false}) async {
    if (!force && products.value.isNotEmpty) {
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
      await _invalidateIapConnection(reason: 'load_products_error');
      _log('加载订阅商品失败: code=${e.code?.value ?? ''}, message=${e.message}');
      hasFreeTrial.value = false;
    } catch (e) {
      _isIapConnected = false;
      await _invalidateIapConnection(reason: 'load_products_exception');
      _log('加载订阅商品异常: $e');
      hasFreeTrial.value = false;
    }
  }

  /// 从本地快照恢复最近一次可用的权益状态。
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

  /// 查询商店并刷新统一权益状态。
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
          products: products.value,
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

  /// 购买指定订阅商品，并等待购买事件给出最终结果。
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
      if (_isConnectionErrorCode(e.code)) {
        await _invalidateIapConnection(reason: e.code);
      }
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
      if (_isConnectionError(e)) {
        await _invalidateIapConnection(
          reason: e.code?.value ?? 'purchase_error',
        );
      }
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
      await _invalidateIapConnection(reason: 'purchase_exception');
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

  /// 恢复购买并重新计算当前订阅权益。
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

  /// 静默执行恢复流程；iOS 仍可能因 App Store sync 弹出系统登录界面。
  Future<SubscriptionActionResult> restoreSilently({
    String source = 'silent_restore',
  }) {
    return restore(source: source, silent: true);
  }

  /// 返回商品的商店展示价格，缺失时使用调用方兜底价格。
  String findPrice(String productId, String fallbackPrice) {
    return catalog.findDisplayPrice(products.value, productId, fallbackPrice);
  }

  /// 返回商品配置中的默认展示价格。
  String findDefaultPrice(String productId) {
    return catalog.findDefaultPrice(productId);
  }

  /// 从已加载商品中查找指定订阅。
  ProductSubscription? findProduct(String productId) {
    return catalog.findProduct(products.value, productId);
  }

  /// 返回指定商品在当前商店可购买的全部 offer。
  List<SubscriptionOffer> findOffers(String productId) {
    final ProductSubscription? product = findProduct(productId);
    if (product == null) {
      return const <SubscriptionOffer>[];
    }
    return _storeAdapter.offersFor(product);
  }

  /// 按 offer 或 base plan 标识查找唯一匹配项。
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

  /// 将年订阅价格换算为每周展示价格。
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

  /// 取消监听、断开商店连接并释放所有通知器。
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

    SubscriptionAccessState? verifiedState;
    final bool retryAndroidEntitlementQuery = item is PurchaseAndroid;
    for (int attempt = 0; attempt < 3; attempt++) {
      verifiedState = await _resolveAccessStateFromNativeStatus(
        productId: productId,
        fallbackTransactionId: payload.currentTransactionId,
      );
      final bool shouldRetry = retryAndroidEntitlementQuery &&
          (verifiedState == null ||
              (verifiedState.status == SubscriptionAccessStatus.expired &&
                  verifiedState.note == 'no active Google Play subscription'));
      if (!shouldRetry || attempt == 2) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }

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

  bool _isConnectionErrorCode(String code) {
    return code == ErrorCode.NotPrepared.value ||
        code == ErrorCode.ServiceDisconnected.value ||
        code == ErrorCode.ServiceTimeout.value ||
        code == ErrorCode.ConnectionClosed.value ||
        code == ErrorCode.BillingUnavailable.value ||
        code == ErrorCode.IapNotAvailable.value ||
        code == ErrorCode.ActivityUnavailable.value ||
        code == 'store-unavailable';
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

      if (_isConnectionError(event)) {
        unawaited(
          _invalidateIapConnection(
            reason: errorCode.isEmpty ? 'purchase_error' : errorCode,
          ),
        );
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
      products: products.value,
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
