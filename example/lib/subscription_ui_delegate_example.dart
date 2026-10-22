import 'package:app_subscription_core/app_subscription_core.dart';
import 'package:flutter/material.dart';

import 'subscription_service_example.dart';

/// 宿主界面接入示例，不属于插件 API；组件、样式和交互均由宿主负责。
class ExampleSubscriptionPanel extends StatelessWidget {
  const ExampleSubscriptionPanel({
    super.key,
    required this.coordinator,
    required this.onResult,
  });

  final SubscriptionCoordinator coordinator;
  final ValueChanged<SubscriptionActionResult> onResult;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SubscriptionOperationState>(
      valueListenable: coordinator.activity,
      builder: (context, activity, _) {
        return Stack(
          children: [
            ValueListenableBuilder<List<SubscriptionPlanDetails>>(
              valueListenable: coordinator.plans,
              builder: (context, plans, _) {
                final yearly = coordinator.planDetails(
                  examplePlans[ExamplePlan.yearly]!,
                );
                // 52 是宿主明确指定的展示除数，不用于计算实际扣款或权益到期时间。
                final average = yearly.price?.averagePrice(
                  divisor: 52,
                  locale: Localizations.localeOf(context).toString(),
                  unitLabel: '周',
                );
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final details in plans)
                      FilledButton(
                        onPressed: activity.isBusy || !details.canPurchase
                            ? null
                            : () async => onResult(
                                await coordinator.purchasePlan(
                                  details.plan,
                                  source: 'example_paywall',
                                ),
                              ),
                        child: Text(details.displayPrice),
                      ),
                    if (average != null) Text(average),
                    TextButton(
                      onPressed: activity.isBusy
                          ? null
                          : () async {
                              onResult(await coordinator.restore());
                            },
                      child: const Text('恢复购买'),
                    ),
                  ],
                );
              },
            ),
            if (activity.showBlockingLoading)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0x66000000),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
        );
      },
    );
  }
}
