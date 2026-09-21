import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var captureController: ScriptMirrorCaptureController?
  private var previewFactory: ScriptMirrorPreviewFactory?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let controller = ScriptMirrorCaptureController(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
    let factory = ScriptMirrorPreviewFactory(controller: controller)
    captureController = controller
    previewFactory = factory
    engineBridge.applicationRegistrar.register(factory, withId: "scriptmirror.camera_preview")
  }
}
