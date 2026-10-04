abstract interface class DesktopWindowService {
  bool get isSupported;

  Future<void> initialize();

  Future<bool> isVisible();

  Future<void> showQuick();

  Future<void> hideQuick();

  Future<void> showFull();
}

class NoopDesktopWindowService implements DesktopWindowService {
  const NoopDesktopWindowService();

  @override
  bool get isSupported => false;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isVisible() async => true;

  @override
  Future<void> showQuick() async {}

  @override
  Future<void> hideQuick() async {}

  @override
  Future<void> showFull() async {}
}
