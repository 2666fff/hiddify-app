abstract class ManagedClientConfig {
  // First target is Windows. Keep this as a product-level switch instead of
  // checking Platform.isWindows so desktop tests and future ports can opt in.
  static const enabled = true;
  static const apiBaseUrl = String.fromEnvironment(
    'HUIJIA_API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8787',
  );
}
