import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:flutter_test/flutter_test.dart';

PricingPhaseAndroid _phase({
  int micros = 52000000,
  int recurrence = 1,
  String period = 'P1Y',
  int cycles = 0,
  String formatted = r'$52.00',
}) => PricingPhaseAndroid(
  billingCycleCount: cycles,
  billingPeriod: period,
  formattedPrice: formatted,
  priceAmountMicros: '$micros',
  priceCurrencyCode: 'USD',
  recurrenceMode: recurrence,
);

SubscriptionOffer _offer({
  required String base,
  String? id,
  List<PricingPhaseAndroid>? phases,
}) => SubscriptionOffer(
  id: id ?? base,
  basePlanIdAndroid: base,
  offerTokenAndroid: 'token-$base-${id ?? base}',
  displayPrice: r'$0.00',
  price: 0,
  type: DiscountOfferType.Introductory,
  pricingPhasesAndroid: PricingPhasesAndroid(
    pricingPhaseList: phases ?? [_phase()],
  ),
);

ProductSubscriptionAndroid _android(List<SubscriptionOffer> offers) =>
    ProductSubscriptionAndroid(
      id: 'subscription',
      currency: 'USD',
      description: '',
      title: '',
      nameAndroid: '',
      displayPrice: r'$0.00',
      subscriptionOffers: offers,
    );

ProductSubscriptionIOS _apple({
  double? amount = 52,
  List<SubscriptionOffer>? offers,
}) => ProductSubscriptionIOS(
  id: 'yearly',
  currency: 'USD',
  description: '',
  title: '',
  displayNameIOS: '',
  displayPrice: r'$52.00',
  price: amount,
  introductoryPricePaymentModeIOS: PaymentModeIOS.PayAsYouGo,
  isFamilyShareableIOS: false,
  jsonRepresentationIOS: '{}',
  subscriptionPeriodNumberIOS: '1',
  subscriptionPeriodUnitIOS: SubscriptionPeriodIOS.Year,
  subscriptionOffers: offers,
  typeIOS: ProductTypeIOS.AutoRenewableSubscription,
);

void main() {
  const catalog = SubscriptionCatalog();
  const yearly = SubscriptionPlan(
    appStoreProductId: 'yearly',
    googlePlay: GooglePlayPlan(
      productId: 'subscription',
      basePlanId: 'yearly',
      offerId: 'trial',
    ),
    fallbackPrice: '待加载',
  );

  test('同一 Android 商品的不同套餐分别选价，试用首期零元不当作续费价', () {
    final trial = _offer(
      base: 'yearly',
      id: 'trial',
      phases: [
        _phase(
          micros: 0,
          recurrence: 2,
          period: 'P1W',
          cycles: 2,
          formatted: r'$0.00',
        ),
        _phase(),
      ],
    );
    final product = _android([
      _offer(
        base: 'monthly',
        phases: [_phase(micros: 9000000, period: 'P1M', formatted: r'$9.00')],
      ),
      trial,
      _offer(base: 'yearly'),
    ]);
    final details = catalog.resolvePlan(
      yearly,
      store: IapStore.Google,
      products: [product],
    );
    expect(details.offer, same(trial));
    expect(details.price?.amount, 52);
    expect(details.displayPrice, r'$52.00');
    expect(details.price?.period?.unit, SubscriptionPeriodUnit.Year);
    expect(details.hasFreeTrial, isTrue);
    expect(details.trialPeriod?.unit, SubscriptionPeriodUnit.Week);
    expect(details.trialPeriod?.value, 2);
    const monthly = SubscriptionPlan(
      googlePlay: GooglePlayPlan(
        productId: 'subscription',
        basePlanId: 'monthly',
      ),
    );
    final monthlyDetails = catalog.resolvePlan(
      monthly,
      store: IapStore.Google,
      products: [product],
    );
    expect(monthlyDetails.price?.amount, 9);
    expect(monthlyDetails.hasFreeTrial, isFalse);
  });

  test('优惠不可用时只有明确允许才回退普通 base plan', () {
    final product = _android([_offer(base: 'yearly')]);
    final unavailable = catalog.resolvePlan(
      yearly,
      store: IapStore.Google,
      products: [product],
    );
    expect(unavailable.canPurchase, isFalse);
    expect(unavailable.failureCode, SubscriptionFailureCode.offerUnavailable);
    const fallback = SubscriptionPlan(
      googlePlay: GooglePlayPlan(
        productId: 'subscription',
        basePlanId: 'yearly',
        offerId: 'trial',
        fallbackToBasePlan: true,
      ),
    );
    final details = catalog.resolvePlan(
      fallback,
      store: IapStore.Google,
      products: [product],
    );
    expect(details.canPurchase, isTrue);
    expect(details.offer?.id, 'yearly');
    expect(details.trialEligibility, SubscriptionTrialEligibility.ineligible);
  });

  test('不指定 offerId 只选择普通 base plan，多重匹配拒绝猜测', () {
    const base = SubscriptionPlan(
      googlePlay: GooglePlayPlan(
        productId: 'subscription',
        basePlanId: 'yearly',
      ),
    );
    final details = catalog.resolvePlan(
      base,
      store: IapStore.Google,
      products: [
        _android([_offer(base: 'yearly', id: 'trial'), _offer(base: 'yearly')]),
      ],
    );
    expect(details.offer?.id, 'yearly');
    final ambiguous = catalog.resolvePlan(
      base,
      store: IapStore.Google,
      products: [
        _android([_offer(base: 'yearly'), _offer(base: 'yearly')]),
      ],
    );
    expect(ambiguous.canPurchase, isFalse);
    expect(ambiguous.failureCode, SubscriptionFailureCode.offerRequired);
  });

  test('单阶段预付方案保留不重复计费语义', () {
    const plan = SubscriptionPlan(
      googlePlay: GooglePlayPlan(
        productId: 'subscription',
        basePlanId: 'prepaid',
      ),
    );
    final details = catalog.resolvePlan(
      plan,
      store: IapStore.Google,
      products: [
        _android([
          _offer(
            base: 'prepaid',
            phases: [_phase(recurrence: 3, period: 'P3M')],
          ),
        ]),
      ],
    );
    expect(
      details.price?.recurrenceMode,
      SubscriptionRecurrenceMode.nonRecurring,
    );
    expect(details.price?.period?.value, 3);
    expect(details.price?.period?.unit, SubscriptionPeriodUnit.Month);
  });

  test('不认识的计费方式不推测正常价格或试用', () {
    final details = catalog.resolvePlan(
      yearly,
      store: IapStore.Google,
      products: [
        _android([
          _offer(base: 'yearly', id: 'trial', phases: [_phase(recurrence: 99)]),
        ]),
      ],
    );
    expect(details.price, isNull);
    expect(details.hasFreeTrial, isFalse);
    expect(
      SubscriptionRecurrenceMode.fromNative(99),
      SubscriptionRecurrenceMode.unknown,
    );
  });

  test('Apple 保留正常商品价，试用资格未知时不能宣称可试用', () {
    final product = _apple(
      offers: [
        const SubscriptionOffer(
          id: 'intro',
          displayPrice: r'$0.00',
          price: 0,
          type: DiscountOfferType.Introductory,
          paymentMode: PaymentMode.FreeTrial,
          period: SubscriptionPeriod(
            unit: SubscriptionPeriodUnit.Month,
            value: 1,
          ),
          periodCount: 2,
        ),
      ],
    );
    final unknown = catalog.resolvePlan(
      yearly,
      store: IapStore.Apple,
      products: [product],
    );
    expect(unknown.trialEligibility, SubscriptionTrialEligibility.unknown);
    expect(unknown.hasFreeTrial, isFalse);
    expect(unknown.price?.amount, 52);
    expect(unknown.trialPeriod?.unit, SubscriptionPeriodUnit.Month);
    expect(unknown.trialPeriod?.value, 2);
    final eligible = catalog.resolvePlan(
      yearly,
      store: IapStore.Apple,
      products: [product],
      appStoreTrialEligibility: SubscriptionTrialEligibility.eligible,
    );
    expect(eligible.hasFreeTrial, isTrue);
    expect(eligible.offer, isNull);
  });

  test('展示兜底不可用于购买或平均价，缺少数值时不解析价格字符串', () {
    final missing = catalog.resolvePlan(
      yearly,
      store: IapStore.Apple,
      products: [],
    );
    expect(missing.displayPrice, '待加载');
    expect(missing.canPurchase, isFalse);
    expect(missing.price, isNull);
    final withoutAmount = catalog.resolvePlan(
      yearly,
      store: IapStore.Apple,
      products: [_apple(amount: null)],
    );
    expect(withoutAmount.price, isNull);
    expect(withoutAmount.displayPrice, r'$52.00');
    const androidOnly = SubscriptionPlan(
      googlePlay: GooglePlayPlan(productId: 's', basePlanId: 'b'),
    );
    expect(
      catalog
          .resolvePlan(androidOnly, store: IapStore.Apple, products: [])
          .failureCode,
      SubscriptionFailureCode.invalidProductPlatform,
    );
  });

  test('平均价明确除数和货币符号，支持逗号小数、零位和三位小数货币', () {
    const usd = SubscriptionPrice(
      amount: 52,
      currencyCode: 'USD',
      displayPrice: r'$52.00',
    );
    expect(
      usd.averagePrice(
        divisor: 52,
        locale: 'en_US',
        unitLabel: 'week',
        currencySymbol: r'$',
      ),
      r'$1.00 / week',
    );
    expect(
      usd.averagePrice(divisor: 52, locale: 'en_US', unitLabel: 'week'),
      'USD1.00 / week',
    );
    const eur = SubscriptionPrice(
      amount: 1299.99,
      currencyCode: 'EUR',
      displayPrice: '1.299,99 €',
    );
    expect(
      eur.averagePrice(
        divisor: 52,
        locale: 'de_DE',
        unitLabel: 'Woche',
        currencySymbol: '€',
      ),
      '25,00\u00a0€ / Woche',
    );
    const jpy = SubscriptionPrice(
      amount: 5200,
      currencyCode: 'JPY',
      displayPrice: '￥5,200',
    );
    expect(
      jpy.averagePrice(divisor: 52, locale: 'en_US', unitLabel: 'week'),
      'JPY100 / week',
    );
    const kwd = SubscriptionPrice(
      amount: 52.052,
      currencyCode: 'KWD',
      displayPrice: 'KWD52.052',
    );
    expect(
      kwd.averagePrice(divisor: 52, locale: 'en_US', unitLabel: 'week'),
      'KWD1.001 / week',
    );
    expect(
      () => usd.averagePrice(divisor: 0, locale: 'en_US', unitLabel: 'week'),
      throwsArgumentError,
    );
  });

  test('周期保留月年单位，不把组合或无效周期换算成固定天数', () {
    expect(
      SubscriptionPrice.parseBillingPeriod('P1M')?.unit,
      SubscriptionPeriodUnit.Month,
    );
    expect(
      SubscriptionPrice.parseBillingPeriod('P1Y')?.unit,
      SubscriptionPeriodUnit.Year,
    );
    expect(SubscriptionPrice.parseBillingPeriod('P1M2D'), isNull);
    expect(SubscriptionPrice.parseBillingPeriod('P0D'), isNull);
    expect(SubscriptionPrice.parseBillingPeriod('PT1H'), isNull);
  });
}
