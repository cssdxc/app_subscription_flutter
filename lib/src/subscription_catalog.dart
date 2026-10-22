import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

import 'subscription_failure.dart';
import 'subscription_plan.dart';
import 'subscription_price.dart';

/// 管理订阅商品查找和价格展示规则。
class SubscriptionCatalog {
  const SubscriptionCatalog();

  /// 精确解析一个跨平台套餐，展示与购买共用这份结果。
  SubscriptionPlanDetails resolvePlan(
    SubscriptionPlan plan, {
    required IapStore store,
    required List<ProductSubscription> products,
    SubscriptionTrialEligibility appStoreTrialEligibility =
        SubscriptionTrialEligibility.unknown,
  }) {
    final productId = plan.productIdFor(store);
    final product = productId == null ? null : findProduct(products, productId);
    if (product == null) {
      return SubscriptionPlanDetails(
        plan: plan,
        store: store,
        failureCode: productId == null
            ? SubscriptionFailureCode.invalidProductPlatform
            : SubscriptionFailureCode.productNotFound,
      );
    }
    if (store == IapStore.Apple && product is ProductSubscriptionIOS) {
      final trialOffers = (product.subscriptionOffers ?? <SubscriptionOffer>[])
          .where(
            (offer) =>
                offer.type == DiscountOfferType.Introductory &&
                offer.paymentMode == PaymentMode.FreeTrial,
          )
          .toList();
      final hasTrial =
          trialOffers.isNotEmpty ||
          product.introductoryPricePaymentModeIOS == PaymentModeIOS.FreeTrial;
      final amount = product.price;
      return SubscriptionPlanDetails(
        plan: plan,
        store: store,
        product: product,
        storeDisplayPrice: product.displayPrice.isEmpty
            ? null
            : product.displayPrice,
        price:
            amount == null ||
                !amount.isFinite ||
                amount < 0 ||
                product.currency.isEmpty ||
                product.displayPrice.isEmpty
            ? null
            : SubscriptionPrice(
                amount: amount,
                currencyCode: product.currency,
                displayPrice: product.displayPrice,
                period: _appStorePeriod(product),
              ),
        trialEligibility: hasTrial
            ? appStoreTrialEligibility
            : SubscriptionTrialEligibility.ineligible,
        trialPeriod: hasTrial
            ? _appStoreTrialPeriod(product, trialOffers)
            : null,
      );
    }
    if (store == IapStore.Google && product is ProductSubscriptionAndroid) {
      final mapping = plan.googlePlay!;
      final candidates = product.subscriptionOffers
          .where(
            (offer) =>
                (offer.offerTokenAndroid ?? '').isNotEmpty &&
                offer.basePlanIdAndroid == mapping.basePlanId,
          )
          .toList();
      // OpenIAP 原生转换器将普通方案的 id 设为 basePlanId，优惠的 id 设为 offerId。
      // 必须同时匹配 basePlanId，不能用首个可用优惠猜测套餐。
      List<SubscriptionOffer> matches = candidates
          .where((offer) => offer.id == (mapping.offerId ?? mapping.basePlanId))
          .toList();
      if (matches.isEmpty &&
          mapping.offerId != null &&
          mapping.fallbackToBasePlan) {
        matches = candidates
            .where((offer) => offer.id == mapping.basePlanId)
            .toList();
      }
      if (matches.length != 1) {
        return SubscriptionPlanDetails(
          plan: plan,
          store: store,
          product: product,
          failureCode: matches.isEmpty
              ? SubscriptionFailureCode.offerUnavailable
              : SubscriptionFailureCode.offerRequired,
        );
      }
      final offer = matches.single;
      final phases =
          offer.pricingPhasesAndroid?.pricingPhaseList ??
          <PricingPhaseAndroid>[];
      final regularPhases = phases
          .where(
            (phase) =>
                SubscriptionRecurrenceMode.fromNative(phase.recurrenceMode) ==
                SubscriptionRecurrenceMode.infiniteRecurring,
          )
          .toList();
      // 预付方案只有一个不重复阶段，其价格属于预付计费阶段。
      final phase = regularPhases.length == 1
          ? regularPhases.single
          : phases.length == 1 &&
                SubscriptionRecurrenceMode.fromNative(
                      phases.single.recurrenceMode,
                    ) ==
                    SubscriptionRecurrenceMode.nonRecurring
          ? phases.single
          : null;
      final micros = phase == null
          ? null
          : int.tryParse(phase.priceAmountMicros);
      final trials = phases
          .where(
            (phase) =>
                int.tryParse(phase.priceAmountMicros) == 0 &&
                SubscriptionRecurrenceMode.fromNative(phase.recurrenceMode) ==
                    SubscriptionRecurrenceMode.finiteRecurring,
          )
          .toList();
      SubscriptionPeriod? trialPeriod;
      if (trials.length == 1) {
        final trial = trials.single;
        final period = SubscriptionPrice.parseBillingPeriod(
          trial.billingPeriod,
        );
        if (period != null && trial.billingCycleCount > 0) {
          trialPeriod = SubscriptionPeriod(
            unit: period.unit,
            value: period.value * trial.billingCycleCount,
          );
        }
      }
      return SubscriptionPlanDetails(
        plan: plan,
        store: store,
        product: product,
        offer: offer,
        storeDisplayPrice: phase == null || phase.formattedPrice.isEmpty
            ? null
            : phase.formattedPrice,
        price:
            phase == null ||
                micros == null ||
                micros < 0 ||
                phase.priceCurrencyCode.isEmpty ||
                phase.formattedPrice.isEmpty
            ? null
            : SubscriptionPrice(
                amount: micros / 1000000,
                currencyCode: phase.priceCurrencyCode,
                displayPrice: phase.formattedPrice,
                period: SubscriptionPrice.parseBillingPeriod(
                  phase.billingPeriod,
                ),
                recurrenceMode: SubscriptionRecurrenceMode.fromNative(
                  phase.recurrenceMode,
                ),
              ),
        trialEligibility: trials.isNotEmpty
            ? SubscriptionTrialEligibility.eligible
            : phases.isEmpty
            ? SubscriptionTrialEligibility.unknown
            : SubscriptionTrialEligibility.ineligible,
        trialPeriod: trialPeriod,
      );
    }
    return SubscriptionPlanDetails(
      plan: plan,
      store: store,
      failureCode: SubscriptionFailureCode.invalidProductPlatform,
    );
  }

  SubscriptionPeriod? _appStoreTrialPeriod(
    ProductSubscriptionIOS product,
    List<SubscriptionOffer> offers,
  ) {
    if (offers.length == 1) {
      final offer = offers.single;
      final period = offer.period;
      final count = offer.periodCount ?? offer.numberOfPeriodsIOS;
      if (period != null &&
          period.value > 0 &&
          period.unit != SubscriptionPeriodUnit.Unknown &&
          count != null &&
          count > 0) {
        return SubscriptionPeriod(
          unit: period.unit,
          value: period.value * count,
        );
      }
    }
    // OpenIAP Apple 4.0.3 已将此字段转换为归一化单位下的总周期数。
    final count = int.tryParse(
      product.introductoryPriceNumberOfPeriodsIOS ?? '',
    );
    final unit = _appStoreUnit(product.introductoryPriceSubscriptionPeriodIOS);
    return count == null || count <= 0 || unit == SubscriptionPeriodUnit.Unknown
        ? null
        : SubscriptionPeriod(unit: unit, value: count);
  }

  SubscriptionPeriodUnit _appStoreUnit(SubscriptionPeriodIOS? unit) =>
      switch (unit) {
        SubscriptionPeriodIOS.Day => SubscriptionPeriodUnit.Day,
        SubscriptionPeriodIOS.Week => SubscriptionPeriodUnit.Week,
        SubscriptionPeriodIOS.Month => SubscriptionPeriodUnit.Month,
        SubscriptionPeriodIOS.Year => SubscriptionPeriodUnit.Year,
        _ => SubscriptionPeriodUnit.Unknown,
      };

  SubscriptionPeriod? _appStorePeriod(ProductSubscriptionIOS product) {
    final count = int.tryParse(product.subscriptionPeriodNumberIOS ?? '');
    if (count == null || count <= 0) return null;
    final unit = _appStoreUnit(product.subscriptionPeriodUnitIOS);
    return unit == SubscriptionPeriodUnit.Unknown
        ? null
        : SubscriptionPeriod(unit: unit, value: count);
  }

  /// 从已加载商品中查找指定商品。
  ProductSubscription? findProduct(
    List<ProductSubscription> products,
    String productId,
  ) {
    for (final product in products) {
      if (product.id == productId) {
        return product;
      }
    }
    return null;
  }
}
