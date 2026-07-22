import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Shared binary messenger for platform channels, accessible by CarPlay.
  static var sharedBinaryMessenger: FlutterBinaryMessenger?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Store the binary messenger so CarPlay can create method channels
    AppDelegate.sharedBinaryMessenger = engineBridge.applicationRegistrar.messenger()
  }
}
