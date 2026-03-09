//
//  ShortcutLaunchManager.swift
//  context-camera
//
//  Tracks whether the app was opened from the Siri shortcut and should
//  trigger a one-shot capture once the camera is ready.
//
import Foundation
enum ShortcutLaunchManager {
    private static let pendingShortcutCaptureKey = "pendingShortcutCapture"
    static func requestCaptureOnNextLaunch() {
        UserDefaults.standard.set(true, forKey: pendingShortcutCaptureKey)
    }
    static func hasPendingCaptureRequest() -> Bool {
        UserDefaults.standard.bool(forKey: pendingShortcutCaptureKey)
    }
    static func consumePendingCaptureRequest() {
        UserDefaults.standard.removeObject(forKey: pendingShortcutCaptureKey)
    }
}
