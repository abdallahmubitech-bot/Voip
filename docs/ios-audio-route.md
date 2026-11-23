# iOS: implementing the audio route channel

The Dart side talks to a MethodChannel named `esp32_voip/audio_route`
(see `lib/core/audio/audio_route_service.dart`). Android implements it in
`MainActivity.kt`. iOS has no implementation yet, so the channel degrades to a
no-op there (`MissingPluginException` is caught) — the call still works, it just
uses whatever route iOS picked.

To reach parity, run `flutter create . --platforms=ios` and add this to
`ios/Runner/AppDelegate.swift`:

```swift
import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let channelName = "esp32_voip/audio_route"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: channelName,
                                         binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { call, result in
        let session = AVAudioSession.sharedInstance()
        switch call.method {
        case "enterCallMode":
          // .voiceChat mode is what enables Apple's AEC on the input path.
          try? session.setCategory(.playAndRecord,
                                  mode: .voiceChat,
                                  options: [.allowBluetooth, .defaultToSpeaker])
          // start on the earpiece, like a phone call
          try? session.overrideOutputAudioPort(.none)
          try? session.setActive(true)
          result(nil)
        case "exitCallMode":
          try? session.overrideOutputAudioPort(.none)
          try? session.setActive(false, options: [.notifyOthersOnDeactivation])
          result(nil)
        case "setLoudspeaker":
          let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
          try? session.overrideOutputAudioPort(enabled ? .speaker : .none)
          result(enabled)
        case "isLoudspeaker":
          result(session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker })
        default:
          result(FlutterMethodNotImplemented)
        }
        return
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
```

Note: `.defaultToSpeaker` above is overridden immediately by
`overrideOutputAudioPort(.none)`, so calls start on the earpiece; drop that
override if you prefer speaker-first on iOS.
