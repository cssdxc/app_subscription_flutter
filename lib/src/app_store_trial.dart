import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

/// 统一识别 Apple 首次订阅免费试用，不将普通折扣或促销优惠视为首次试用。
extension AppStoreTrialProduct on ProductSubscriptionIOS {
  Iterable<SubscriptionOffer> get introductoryFreeTrialOffers =>
      (subscriptionOffers ?? const <SubscriptionOffer>[]).where(
        (offer) =>
            offer.type == DiscountOfferType.Introductory &&
            offer.paymentMode == PaymentMode.FreeTrial,
      );

  bool get hasIntroductoryFreeTrial =>
      introductoryPricePaymentModeIOS == PaymentModeIOS.FreeTrial ||
      introductoryFreeTrialOffers.isNotEmpty;
}
