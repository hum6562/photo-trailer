import UIKit
import Flutter
import GoogleMaps // 1. 구글 맵 임포트

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 2. 여기에 API 키를 입력하세요!
    GMSServices.provideAPIKey("AIzaSyAYyjgFRzXH9fW-av6DLUM-T70KYGB3reA")
    
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}