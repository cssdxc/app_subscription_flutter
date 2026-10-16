import 'dart:async';
import 'dart:convert';

import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:app_subscription_core/src/subscription_operation_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform/platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('flutter_inapp');
const _applePlan = SubscriptionPlan(appStoreProductId: 'monthly');

ProductSubscriptionIOS _appleProduct({
  String id = 'monthly',
  String group = 'group',
}) => ProductSubscriptionIOS(
  id: id,
  currency: 'USD',
  description: '',
  title: '',
  displayNameIOS: '',
  displayPrice: r'$12.00',
  price: 12,
  introductoryPricePaymentModeIOS: PaymentModeIOS.FreeTrial,
  subscriptionGroupIdIOS: group,
  isFamilyShareableIOS: false,
  jsonRepresentationIOS: '{}',
  typeIOS: ProductTypeIOS.AutoRenewableSubscription,
);

Future<void> _emit(String method, Map<String, dynamic> data) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        _channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, jsonEncode(data)),
        ),
        null,
      );
}

Future<SubscriptionCoordinator> _create({
  List<SubscriptionPlan> plans = const [_applePlan],
  bool android = false,
  SubscriptionActionObserver? observer,
  ActiveSubscriptionQuery? query,
}) async {
  SharedPreferences.setMockInitialValues({});
  final coordinator = SubscriptionCoordinator(
    sharedPreferences: await SharedPreferences.getInstance(),
    iap: FlutterInappPurchase(
      platform: FakePlatform(
        operatingSystem: android ? Platform.android : Platform.iOS,
      ),
    ),
    config: SubscriptionCoordinatorConfig(
      plans: plans,
      googlePlayLicenseKeyAndroid: 'unused-in-pending-tests',
      actionObserver: observer,
      logger: (_) => throw StateError('日志失败'),
      activeSubscriptionQuery: query ?? (_) async => [],
      subscriptionStatusQueryIOS: (_) async => [],
    ),
  );
  addTearDown(coordinator.dispose);
  return coordinator;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(FlutterInappPurchase.resetSharedStateForTesting);
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('初始化和商品加载合并并发请求，套餐快照在资格查询后更新', () async {
    final gate = Completer<void>();
    final fetching = Completer<void>();
    int fetchCalls = 0;
    int queryCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          switch (call.method) {
            case 'initConnection':
              return true;
            case 'fetchProducts':
              fetchCalls++;
              fetching.complete();
              await gate.future;
              return [_appleProduct().toJson()];
            case 'isEligibleForIntroOfferIOS':
              return true;
            case 'endConnection':
              return true;
          }
          return null;
        });
    final coordinator = await _create(
      query: (_) async {
        queryCalls++;
        return [];
      },
    );
    expect(coordinator.plans.value.single.canPurchase, isFalse);
    final first = coordinator.init();
    final second = coordinator.init();
    expect(identical(first, second), isTrue);
    await fetching.future;
    final loadingAgain = coordinator.loadProducts();
    expect(coordinator.activity.value.isLoadingProducts, isTrue);
    expect(coordinator.activity.value.showBlockingLoading, isFalse);
    gate.complete();
    await Future.wait([first, second, loadingAgain]);
    expect(fetchCalls, 1);
    expect(queryCalls, 1);
    expect(coordinator.plans.value.single.displayPrice, r'$12.00');
    expect(
      coordinator.plans.value.single.trialEligibility,
      SubscriptionTrialEligibility.eligible,
    );
    expect(coordinator.activity.value.isLoading, isFalse);
  });

  test('取消购买会关闭 loading，busy 拒绝不能关闭当前购买的 loading', () async {
    final requested = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          switch (call.method) {
            case 'initConnection':
              return true;
            case 'fetchProducts':
              return [_appleProduct().toJson()];
            case 'isEligibleForIntroOfferIOS':
              return false;
            case 'requestPurchase':
              requested.complete();
              return null;
            case 'endConnection':
              return true;
          }
          return null;
        });
    final coordinator = await _create(
      observer: (_) => throw StateError('观察器失败'),
    );
    final buying = coordinator.purchasePlan(_applePlan, source: 'test');
    await requested.future;
    expect(coordinator.activity.value.showBlockingLoading, isTrue);
    final busy = await coordinator.restore();
    expect(busy.failureCode, SubscriptionFailureCode.busy);
    expect(coordinator.activity.value.showBlockingLoading, isTrue);
    await _emit('purchase-error', {'code': 'user-cancelled', 'message': '取消'});
    final result = await buying;
    expect(result.outcome, SubscriptionActionOutcome.cancelled);
    expect(result.storeErrorCode, ErrorCode.UserCancelled);
    expect(result.failed, isFalse);
    expect(coordinator.activity.value.isLoading, isFalse);
  });

  test('请求异常和释放均完成购买 Future 并关闭 loading', () async {
    bool shouldThrow = true;
    final requested = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          switch (call.method) {
            case 'initConnection':
              return true;
            case 'fetchProducts':
              return [_appleProduct().toJson()];
            case 'isEligibleForIntroOfferIOS':
              return false;
            case 'requestPurchase':
              if (shouldThrow)
                throw PlatformException(code: 'E_SERVICE_ERROR', message: '失败');
              requested.complete();
              return null;
            case 'endConnection':
              return true;
          }
          return null;
        });
    final coordinator = await _create();
    final failed = await coordinator.purchasePlan(_applePlan, source: 'failed');
    expect(failed.outcome, SubscriptionActionOutcome.failure);
    expect(coordinator.activity.value.isLoading, isFalse);
    shouldThrow = false;
    final pending = coordinator.purchasePlan(_applePlan, source: 'dispose');
    await requested.future;
    await coordinator.dispose();
    expect((await pending).failureCode, SubscriptionFailureCode.disposed);
    expect(coordinator.activity.value.isLoading, isFalse);
    expect(
      (await coordinator.purchasePlan(_applePlan, source: 'late')).failureCode,
      SubscriptionFailureCode.disposed,
    );
  });

  test('释放时商品查询尚未返回，不再发布套餐或注册后续监听', () async {
    final gate = Completer<void>();
    final fetching = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          switch (call.method) {
            case 'initConnection':
              return true;
            case 'fetchProducts':
              fetching.complete();
              await gate.future;
              return [_appleProduct().toJson()];
            case 'endConnection':
              return true;
          }
          return null;
        });
    final coordinator = await _create();
    int updates = 0;
    coordinator.plans.addListener(() => updates++);
    final init = coordinator.init();
    await fetching.future;
    await coordinator.dispose();
    gate.complete();
    await init;
    expect(updates, 0);
  });

  test('静默恢复不展示阻断 loading，连接失败不能冒充商店恢复成功', () async {
    final connecting = Completer<void>();
    final gate = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          switch (call.method) {
            case 'initConnection':
              if (!connecting.isCompleted) connecting.complete();
              await gate.future;
              return false;
            case 'endConnection':
              return true;
          }
          return null;
        });
    final coordinator = await _create();
    final restoring = coordinator.restore(silent: true);
    await connecting.future;
    expect(coordinator.activity.value.isRestoring, isTrue);
    expect(coordinator.activity.value.showBlockingLoading, isFalse);
    gate.complete();
    final result = await restoring;
    expect(result.failureCode, SubscriptionFailureCode.storeUnavailable);
    expect(result.silent, isTrue);
    expect(coordinator.activity.value.isLoading, isFalse);
  });

  test('Android 按套餐发送正确的优惠 token，pending 退出 loading 并保留购买对象', () async {
    const plan = SubscriptionPlan(
      googlePlay: GooglePlayPlan(
        productId: 'subscription',
        basePlanId: 'yearly',
        offerId: 'trial',
      ),
    );
    SubscriptionOffer offer(String base, String id) => SubscriptionOffer(
      basePlanIdAndroid: base,
      id: id,
      offerTokenAndroid: 'token-$base-$id',
      displayPrice: '免费',
      price: 0,
      type: DiscountOfferType.Introductory,
    );
    final product = ProductSubscriptionAndroid(
      id: 'subscription',
      currency: 'USD',
      description: '',
      title: '',
      nameAndroid: '',
      displayPrice: '免费',
      subscriptionOffers: [
        offer('monthly', 'trial'),
        offer('yearly', 'trial'),
        offer('yearly', 'yearly'),
      ],
    );
    final requested = Completer<void>();
    Object? payload;
    List<dynamic>? skus;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          switch (call.method) {
            case 'initConnection':
              return true;
            case 'fetchProducts':
              skus = (call.arguments as Map)['skus'] as List;
              return [product.toJson()];
            case 'requestPurchase':
              payload = call.arguments;
              requested.complete();
              return null;
            case 'endConnection':
              return true;
          }
          return null;
        });
    const monthly = SubscriptionPlan(
      googlePlay: GooglePlayPlan(
        productId: 'subscription',
        basePlanId: 'monthly',
      ),
    );
    final coordinator = await _create(android: true, plans: [monthly, plan]);
    final buying = coordinator.purchasePlan(
      plan,
      source: 'yearly',
      options: const SubscriptionPurchaseOptions(
        obfuscatedAccountIdAndroid: 'hashed-account',
      ),
    );
    await requested.future;
    expect(skus, ['subscription']);
    final google = payload as Map;
    expect(
      (google['subscriptionOffers'] as List).single['offerToken'],
      'token-yearly-trial',
    );
    expect(google['obfuscatedAccountId'], 'hashed-account');
    final purchase = PurchaseAndroid(
      id: 'pending',
      productId: 'subscription',
      isAutoRenewing: true,
      purchaseState: PurchaseState.Pending,
      quantity: 1,
      store: IapStore.Google,
      storeId: StoreIds.play,
      transactionDate: 1,
    );
    await _emit('purchase-updated', purchase.toJson());
    final result = await buying;
    expect(result.outcome, SubscriptionActionOutcome.pending);
    expect(result.purchase?.productId, 'subscription');
    expect(coordinator.accessState.value.shouldGrantAccess, isFalse);
    expect(coordinator.activity.value.isLoading, isFalse);
  });

  test('并发操作计数在异常后仍保留其他工作的 loading', () async {
    final tracker = SubscriptionOperationTracker();
    addTearDown(tracker.dispose);
    final firstGate = Completer<void>();
    final secondGate = Completer<void>();
    final first = tracker.track(
      SubscriptionOperation.loadingProducts,
      () => firstGate.future,
    );
    final second = tracker.track(
      SubscriptionOperation.loadingProducts,
      () => secondGate.future,
    );
    firstGate.complete();
    await first;
    expect(tracker.value.isLoadingProducts, isTrue);
    final expectation = expectLater(second, throwsStateError);
    secondGate.completeError(StateError('失败'));
    await expectation;
    expect(tracker.value.isLoading, isFalse);
  });

  test('官方延期付款错误保留枚举且返回 pending', () {
    for (final code in [ErrorCode.DeferredPayment, ErrorCode.Pending]) {
      final result = SubscriptionActionResult.failure(
        type: SubscriptionActionType.purchase,
        storeErrorCode: code,
      );
      expect(result.outcome, SubscriptionActionOutcome.pending);
      expect(result.storeErrorCode, code);
    }
  });

  test('原生购买请求尚未返回时，释放也会完成调用者的 Future', () async {
    final requestGate = Completer<void>();
    final requested = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          switch (call.method) {
            case 'initConnection':
              return true;
            case 'fetchProducts':
              return [_appleProduct().toJson()];
            case 'isEligibleForIntroOfferIOS':
              return false;
            case 'requestPurchase':
              requested.complete();
              await requestGate.future;
              return null;
            case 'endConnection':
              return true;
          }
          return null;
        });
    final coordinator = await _create();
    final buying = coordinator.purchasePlan(
      _applePlan,
      source: 'dispose_early',
    );
    await requested.future;
    await coordinator.dispose();
    final result = await buying.timeout(const Duration(seconds: 1));
    expect(result.failureCode, SubscriptionFailureCode.disposed);
    requestGate.completeError(PlatformException(code: 'E_SERVICE_ERROR'));
    await Future<void>.delayed(Duration.zero);
  });

  test('购买前刷新商品失败时不使用旧商品发起购买', () async {
    bool failFetch = false;
    int purchaseRequests = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          switch (call.method) {
            case 'initConnection':
              return true;
            case 'fetchProducts':
              if (failFetch) throw PlatformException(code: 'E_NETWORK_ERROR');
              return [_appleProduct().toJson()];
            case 'isEligibleForIntroOfferIOS':
              return false;
            case 'requestPurchase':
              purchaseRequests++;
              return null;
            case 'endConnection':
              return true;
          }
          return null;
        });
    final coordinator = await _create();
    expect(await coordinator.loadProducts(), isTrue);
    failFetch = true;
    final result = await coordinator.purchasePlan(
      _applePlan,
      source: 'refresh_failed',
    );
    expect(result.failureCode, SubscriptionFailureCode.storeUnavailable);
    expect(purchaseRequests, 0);
    expect(coordinator.activity.value.isLoading, isFalse);
  });

  test('Apple 逐订阅组查询试用资格，同组去重，失败和缺失组均保留未知', () async {
    final queriedGroups = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          expect(call.method, 'isEligibleForIntroOfferIOS');
          final group = (call.arguments as Map)['productId'] as String;
          queriedGroups.add(group);
          if (group == 'error')
            throw PlatformException(code: 'E_SERVICE_ERROR');
          return group == 'eligible';
        });
    final result = await IosSubscriptionHelper.queryTrialEligibility(
      iap: FlutterInappPurchase(
        platform: FakePlatform(operatingSystem: Platform.iOS),
      ),
      products: [
        _appleProduct(id: 'a', group: 'eligible'),
        _appleProduct(id: 'b', group: 'eligible'),
        _appleProduct(id: 'c', group: 'ineligible'),
        _appleProduct(id: 'd', group: 'error'),
        _appleProduct(id: 'e', group: 'error'),
        _appleProduct(id: 'f', group: ''),
      ],
    );
    expect(queriedGroups, ['eligible', 'ineligible', 'error']);
    expect(result['a'], SubscriptionTrialEligibility.eligible);
    expect(result['b'], SubscriptionTrialEligibility.eligible);
    expect(result['c'], SubscriptionTrialEligibility.ineligible);
    for (final id in ['d', 'e', 'f']) {
      expect(result[id], SubscriptionTrialEligibility.unknown);
    }
  });
}
