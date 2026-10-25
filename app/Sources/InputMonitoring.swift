import Foundation
import IOKit
import IOKit.hid

/// Settings › General › Mouse › High-precision (REC-52, AppModel.MouseInput.highPrecision): Overwatch
/// reads the mouse's own reports through IOHID instead of Apple's mouse input for games (GCMouse),
/// which drops some of them in game. Reading a mouse that way needs macOS's Input Monitoring. To
/// macOS the game runs as part of this app, so the permission is the app's: it is asked for when the
/// player chooses High-precision and continues past its explanation (HighPrecisionMouseSheet), never
/// from inside the game, and only the player can change it afterwards, in System Settings. macOS's
/// prompt speaks of keystrokes; the window driver opens only mice and reads only their movement and
/// buttons (cocoa_app.m hid_start). Without the permission the mouse works as Standard does.
enum InputMonitoring {
    enum Access:String { case allowed, denied, undecided }
    static var access:Access {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .allowed
        case kIOHIDAccessTypeDenied: return .denied
        default: return .undecided
        }
    }
    /// Shows macOS's prompt the first time; the player then turns the app on in System Settings.
    static func ask() { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
    static let privacySettings=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
    /// Whether a mouse High-precision would read is connected, by the window driver's rule
    /// (cocoa_app.m hid_start, hid_is_trackpad): a HID device with a mouse collection that is
    /// neither built in nor named a trackpad. It reads the I/O Registry, which needs no
    /// permission; opening the mice, as the driver does, would.
    static var mouseConnected:Bool {
        var services:io_iterator_t=0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,mouseMatching,&services) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(services) }
        var found=false
        while case let service=IOIteratorNext(services), service != 0 {
            defer { IOObjectRelease(service) }
            if !found && !isTrackpad(service) { found=true }
        }
        return found
    }
    private static var mouseMatching:CFDictionary {
        let matching=IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary
        matching[kIOHIDDeviceUsagePageKey]=kHIDPage_GenericDesktop
        matching[kIOHIDDeviceUsageKey]=kHIDUsage_GD_Mouse
        return matching
    }
    private static func isTrackpad(_ service:io_service_t)->Bool {
        if IORegistryEntryCreateCFProperty(service,kIOHIDBuiltInKey as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? Bool == true { return true }
        let product=IORegistryEntryCreateCFProperty(service,kIOHIDProductKey as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? String
        return product?.range(of:"Trackpad",options:.caseInsensitive) != nil
    }
    /// Calls changed on the main queue whenever a HID device with a mouse collection connects or
    /// disconnects, so the home screen's invitation (HighPrecisionInvite) follows a mouse being
    /// plugged in or unplugged. Keep the watch for as long as it should call.
    final class MouseWatch {
        private let port:IONotificationPortRef
        private var iterators:[io_iterator_t]=[]
        private let changed:()->Void
        init(changed:@escaping ()->Void) {
            self.changed=changed
            port=IONotificationPortCreate(kIOMainPortDefault)
            IONotificationPortSetDispatchQueue(port,.main)
            let context=Unmanaged.passUnretained(self).toOpaque()
            for kind in [kIOFirstMatchNotification,kIOTerminatedNotification] {
                var iterator:io_iterator_t=0
                let callback:IOServiceMatchingCallback={ context,iterator in
                    MouseWatch.drain(iterator)
                    if let context { Unmanaged<MouseWatch>.fromOpaque(context).takeUnretainedValue().changed() }
                }
                if IOServiceAddMatchingNotification(port,kind,InputMonitoring.mouseMatching,callback,context,&iterator) == KERN_SUCCESS {
                    // The iterator arms only once it has been read to the end.
                    MouseWatch.drain(iterator);iterators.append(iterator)
                }
            }
        }
        deinit {
            iterators.forEach { IOObjectRelease($0) }
            IONotificationPortDestroy(port)
        }
        private static func drain(_ iterator:io_iterator_t) {
            while case let service=IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
        }
    }
}

/// The home screen's card for High-precision (REC-64; owner, October 25): an invitation to every
/// player with a mouse, existing and new, and, once High-precision is chosen, a reminder to finish
/// macOS's permission. Only on the Play screen while Battle.net and Overwatch are closed (the
/// mouse is one of the settings Battle.net carries from when it opens), once Overwatch is
/// installed. Its close button hides it for good, as does leaving High-precision after choosing it.
/// Setup never asks: macOS makes each player allow Input Monitoring themselves.
enum HighPrecisionInvite:String {
    case invite, permission
    static func stage(closed:Bool, gameInstalled:Bool, highPrecision:Bool, access:InputMonitoring.Access, mouseConnected:Bool)->HighPrecisionInvite? {
        guard !closed && gameInstalled else { return nil }
        if highPrecision { return access == .allowed ? nil : .permission }
        return mouseConnected ? .invite : nil
    }
}
