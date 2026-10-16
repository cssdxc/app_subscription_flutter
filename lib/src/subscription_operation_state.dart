import 'package:flutter/foundation.dart';

/// 进行中的工作；购买、恢复和后台验证与商品加载可以同时存在。
enum SubscriptionOperation {
  initializing,
  loadingProducts,
  checkingTrialEligibility,
  refreshingAccess,
  purchasing,
  restoring,
  processingPurchase,
}

/// 只读的工作快照。loading 的视觉样式和文案由宿主决定。
class SubscriptionOperationState {
  const SubscriptionOperationState({
    this.running = const <SubscriptionOperation>{},
    this.productId,
    this.silent = false,
  });

  final Set<SubscriptionOperation> running;
  final String? productId;
  final bool silent;

  bool get isLoading => running.isNotEmpty;
  bool get isPurchasing => running.contains(SubscriptionOperation.purchasing);
  bool get isRestoring => running.contains(SubscriptionOperation.restoring);
  bool get isLoadingProducts =>
      running.contains(SubscriptionOperation.loadingProducts);
  bool get isBusy =>
      isPurchasing ||
      isRestoring ||
      running.contains(SubscriptionOperation.processingPurchase);

  /// 用户操作才展示阻断式 loading，静默恢复和后台工作不自动遮挡界面。
  bool get showBlockingLoading => !silent && (isPurchasing || isRestoring);
}

/// 内部计数器，保证并行工作与异常退出不会提前关闭其他工作的 loading。
class SubscriptionOperationTracker
    extends ValueNotifier<SubscriptionOperationState> {
  SubscriptionOperationTracker() : super(const SubscriptionOperationState());

  final Map<SubscriptionOperation, int> _counts = {};
  bool _disposed = false;
  String? _productId;
  bool _silent = false;

  Future<T> track<T>(
    SubscriptionOperation operation,
    Future<T> Function() work, {
    String? productId,
    bool silent = false,
  }) async {
    _counts.update(operation, (value) => value + 1, ifAbsent: () => 1);
    if (operation == SubscriptionOperation.purchasing ||
        operation == SubscriptionOperation.restoring) {
      _productId = productId;
      _silent = silent;
    }
    _publish();
    try {
      return await work();
    } finally {
      final count = _counts[operation] ?? 1;
      if (count == 1) {
        _counts.remove(operation);
      } else {
        _counts[operation] = count - 1;
      }
      if (!_counts.containsKey(SubscriptionOperation.purchasing) &&
          !_counts.containsKey(SubscriptionOperation.restoring)) {
        _productId = null;
        _silent = false;
      }
      _publish();
    }
  }

  void _publish() {
    if (_disposed) return;
    value = SubscriptionOperationState(
      running: Set.unmodifiable(_counts.keys),
      productId: _productId,
      silent: _silent,
    );
  }

  @override
  void dispose() {
    value = const SubscriptionOperationState();
    _disposed = true;
    super.dispose();
  }
}
