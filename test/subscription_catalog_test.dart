import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:flutter_test/flutter_test.dart';

ProductSubscriptionIOS _product({
  required String displayPrice,
  double? price,
}) {
  return ProductSubscriptionIOS(
    currency: 'USD',
    description: 'Yearly subscription',
    displayNameIOS: 'Yearly',
    displayPrice: displayPrice,
    id: 'yearly',
    introductoryPricePaymentModeIOS: PaymentModeIOS.PayAsYouGo,
    isFamilyShareableIOS: false,
    jsonRepresentationIOS: '{}',
    price: price,
    title: 'Yearly',
    typeIOS: ProductTypeIOS.AutoRenewableSubscription,
  );
}

void main() {
  const SubscriptionCatalog catalog = SubscriptionCatalog(
    defaultPrices: <String, String>{'yearly': r'$49.99'},
    yearlyProductId: 'yearly',
  );

  test('keeps leading currency symbols when formatting weekly price', () {
    expect(
      catalog.yearlyPricePerWeek(
        <ProductSubscriptionIOS>[
          _product(displayPrice: r'$49.99', price: 49.99),
        ],
        fallbackPrice: r'$49.99',
        weekLabel: 'week',
      ),
      r'$0.96 / week',
    );
  });

  test('keeps multi-character leading currency symbols', () {
    expect(
      catalog.yearlyPricePerWeek(
        <ProductSubscriptionIOS>[
          _product(displayPrice: r'US$49.99', price: 49.99),
        ],
        fallbackPrice: r'$49.99',
        weekLabel: 'week',
      ),
      r'US$0.96 / week',
    );
  });

  test('keeps leading currency codes and spacing', () {
    expect(
      catalog.yearlyPricePerWeek(
        <ProductSubscriptionIOS>[
          _product(displayPrice: 'USD 49.99', price: 49.99),
        ],
        fallbackPrice: r'$49.99',
        weekLabel: 'week',
      ),
      'USD 0.96 / week',
    );
  });

  test('keeps trailing currency symbols and comma decimals', () {
    expect(
      catalog.yearlyPricePerWeek(
        <ProductSubscriptionIOS>[
          _product(displayPrice: '49,99 €', price: 49.99),
        ],
        fallbackPrice: r'$49.99',
        weekLabel: 'week',
      ),
      '0,96 € / week',
    );
  });

  test('keeps trailing currency codes', () {
    expect(
      catalog.yearlyPricePerWeek(
        <ProductSubscriptionIOS>[
          _product(displayPrice: '49.99 USD', price: 49.99),
        ],
        fallbackPrice: r'$49.99',
        weekLabel: 'week',
      ),
      '0.96 USD / week',
    );
  });

  test('keeps comma decimals when the original price has grouping', () {
    expect(
      catalog.yearlyPricePerWeek(
        <ProductSubscriptionIOS>[
          _product(displayPrice: '1.299,99 €', price: 1299.99),
        ],
        fallbackPrice: r'$1299.99',
        weekLabel: 'week',
      ),
      '25,00 € / week',
    );
  });

  test('uses fallback when raw product price is unavailable', () {
    expect(
      catalog.yearlyPricePerWeek(
        <ProductSubscriptionIOS>[
          _product(displayPrice: r'$49.99'),
        ],
        fallbackPrice: r'$49.99',
        weekLabel: 'week',
      ),
      r'$49.99 / week',
    );
  });

  test('uses fallback format when product display price is empty', () {
    expect(
      catalog.yearlyPricePerWeek(
        <ProductSubscriptionIOS>[
          _product(displayPrice: '', price: 49.99),
        ],
        fallbackPrice: '49,99 €',
        weekLabel: 'week',
      ),
      '0,96 € / week',
    );
  });
}
