import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:flutter_test/flutter_test.dart';

ActiveSubscription _activeSubscription({
  bool isActive = true,
  String productId = 'subscribe_month_1',
  String transactionId = 'tx_1',
  double? expirationDateIOS,
  RenewalInfoIOS? renewalInfoIOS,
}) {
  return ActiveSubscription(
    isActive: isActive,
    productId: productId,
    transactionDate: 1,
    transactionId: transactionId,
    expirationDateIOS: expirationDateIOS,
    renewalInfoIOS: renewalInfoIOS,
  );
}

void main() {
  const int nowMs = 1700000000000;

  test('grants access for an active native entitlement', () {
    final SubscriptionAccessState state =
        IosSubscriptionHelper.resolveAccessStateFromActiveSubscription(
      subscription: _activeSubscription(
        expirationDateIOS: (nowMs + 10000).toDouble(),
      ),
      now: DateTime.fromMillisecondsSinceEpoch(nowMs),
    );

    expect(state.status, SubscriptionAccessStatus.active);
    expect(state.shouldGrantAccess, isTrue);
    expect(state.productId, 'subscribe_month_1');
    expect(state.transactionId, 'tx_1');
  });

  test('grants access for an active entitlement in grace period', () {
    final SubscriptionAccessState state =
        IosSubscriptionHelper.resolveAccessStateFromActiveSubscription(
      subscription: _activeSubscription(
        renewalInfoIOS: RenewalInfoIOS(
          gracePeriodExpirationDate: nowMs + 10000,
          expirationReason: 'BILLING_ERROR',
          willAutoRenew: true,
        ),
      ),
      now: DateTime.fromMillisecondsSinceEpoch(nowMs),
    );

    expect(state.status, SubscriptionAccessStatus.gracePeriod);
    expect(state.shouldGrantAccess, isTrue);
    expect(state.effectiveUntilMs, nowMs + 10000);
  });

  test('blocks inactive native subscriptions', () {
    final SubscriptionAccessState state =
        IosSubscriptionHelper.resolveAccessStateFromActiveSubscription(
      subscription: _activeSubscription(isActive: false),
      now: DateTime.fromMillisecondsSinceEpoch(nowMs),
    );

    expect(state.status, SubscriptionAccessStatus.expired);
    expect(state.shouldGrantAccess, isFalse);
  });

  test('blocks when no native entitlement is returned', () {
    final SubscriptionAccessState state =
        IosSubscriptionHelper.resolveAccessStateFromActiveSubscriptions(
      const <ActiveSubscription>[],
      fallbackProductId: 'subscribe_month_1',
      now: DateTime.fromMillisecondsSinceEpoch(nowMs),
    );

    expect(state.status, SubscriptionAccessStatus.expired);
    expect(state.shouldGrantAccess, isFalse);
    expect(state.productId, 'subscribe_month_1');
  });

  test('picks the most relevant state from multiple active entitlements', () {
    final SubscriptionAccessState state =
        IosSubscriptionHelper.resolveAccessStateFromActiveSubscriptions(
      [
        _activeSubscription(
          isActive: false,
          productId: 'subscribe_week_1',
          transactionId: 'tx_expired',
        ),
        _activeSubscription(
          productId: 'subscribe_month_1',
          transactionId: 'tx_active',
          expirationDateIOS: (nowMs + 10000).toDouble(),
        ),
      ],
      fallbackProductId: 'subscribe_month_1',
      now: DateTime.fromMillisecondsSinceEpoch(nowMs),
    );

    expect(state.status, SubscriptionAccessStatus.active);
    expect(state.shouldGrantAccess, isTrue);
    expect(state.transactionId, 'tx_active');
  });
}
