import 'dart:async';
import 'dart:convert';

import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform/platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('flutter_inapp');
const _plan = SubscriptionPlan(
  appStoreProductId: 'monthly',
  googlePlay: GooglePlayPlan(productId: 'subscription', basePlanId: 'monthly'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(FlutterInappPurchase.resetSharedStateForTesting);
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  for (final platform in [Platform.iOS, Platform.android, Platform.linux]) {
    test('$platform 空配置可直接创建和释放，不访问商店或授予缓存权益', () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call.method);
            return null;
          });
      SharedPreferences.setMockInitialValues({
        'subscription_access_state': jsonEncode(
          SubscriptionAccessState(
            status: SubscriptionAccessStatus.active,
            evaluatedAtMs: DateTime.now().millisecondsSinceEpoch,
          ).toJson(),
        ),
      });
      final events = <SubscriptionActionEvent>[];
      final coordinator = SubscriptionCoordinator(
        iap: FlutterInappPurchase(
          platform: FakePlatform(operatingSystem: platform),
        ),
        config: SubscriptionCoordinatorConfig(
          plans: const [],
          actionObserver: events.add,
        ),
      );
      final expected = platform == Platform.linux
          ? SubscriptionFailureCode.unsupportedPlatform
          : SubscriptionFailureCode.planNotConfigured;
      final access = coordinator.accessState;
      final activity = coordinator.activity;
      final plans = coordinator.plans;
      expect(coordinator.configurationFailure, expected);
      expect(coordinator.isConfigured, false);
      await coordinator.init();
      await coordinator.init();
      expect(await coordinator.loadProducts(), false);
      await coordinator.refreshTrialEligibility();
      expect((await coordinator.refreshAccessState()).shouldGrantAccess, false);
      expect(
        (await coordinator.purchasePlan(_plan, source: 'test')).failureCode,
        expected,
      );
      expect((await coordinator.restore()).failureCode, expected);
      expect(events.map((event) => event.result?.failureCode), [
        expected,
        expected,
      ]);
      expect(coordinator.accessState, same(access));
      expect(coordinator.activity, same(activity));
      expect(coordinator.plans, same(plans));
      expect(activity.value.isLoading, false);
      await coordinator.dispose();
      expect(calls, isEmpty);
    });
  }

  test('Android 缺少验证公钥时返回明确枚举，不构造原生适配器', () async {
    final coordinator = SubscriptionCoordinator(
      iap: FlutterInappPurchase(
        platform: FakePlatform(operatingSystem: Platform.android),
      ),
      config: const SubscriptionCoordinatorConfig(plans: [_plan]),
    );
    expect(
      coordinator.configurationFailure,
      SubscriptionFailureCode.missingLicenseKey,
    );
    expect(
      coordinator.planDetails(_plan).failureCode,
      SubscriptionFailureCode.missingLicenseKey,
    );
    expect(
      (await coordinator.purchasePlan(_plan, source: 'test')).failureCode,
      SubscriptionFailureCode.missingLicenseKey,
    );
    await coordinator.dispose();
  });

  test('默认延迟创建缓存；初始化期间发起恢复会等待同一次初始化', () async {
    SharedPreferences.setMockInitialValues({});
    final connecting = Completer<void>();
    final connected = Completer<bool>();
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'initConnection':
              connecting.complete();
              return connected.future;
            case 'fetchProducts':
            case 'getAvailableItems':
              return [];
            case 'restorePurchases':
            case 'endConnection':
              return true;
          }
          return null;
        });
    final coordinator = SubscriptionCoordinator(
      iap: FlutterInappPurchase(
        platform: FakePlatform(operatingSystem: Platform.iOS),
      ),
      config: SubscriptionCoordinatorConfig(
        plans: const [_plan],
        activeSubscriptionQuery: (_) async => [],
      ),
    );
    expect(calls, isEmpty);
    final initializing = coordinator.init();
    expect(coordinator.init(), same(initializing));
    await connecting.future;
    final restoring = coordinator.restore();
    expect(coordinator.activity.value.isRestoring, true);
    expect(calls, isNot(contains('restorePurchases')));
    connected.complete(true);
    await initializing;
    final result = await restoring;
    expect(result.success, true, reason: result.message ?? result.code);
    expect(calls.where((call) => call == 'initConnection'), hasLength(1));
    expect(calls.where((call) => call == 'restorePurchases'), hasLength(1));
    expect(
      (await SharedPreferences.getInstance()).getString(
        'subscription_access_state',
      ),
      isNotNull,
    );
    await coordinator.dispose();
  });

  test('释放后所有入口安全返回', () async {
    final coordinator = SubscriptionCoordinator(
      config: const SubscriptionCoordinatorConfig(plans: []),
    );
    await coordinator.dispose();
    await coordinator.init();
    expect(await coordinator.loadProducts(), false);
    expect(
      (await coordinator.restore()).failureCode,
      SubscriptionFailureCode.disposed,
    );
  });
}
