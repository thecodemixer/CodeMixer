import Foundation

/// Pairing PIN exchange and lockout policy for LAN remote control.
///
/// Owned beside `RemoteDefaults` so `PairingService` and its tests do not
/// grow unexplained timeout literals.
public enum RemoteAuthTiming {
    public static let pinTTL: TimeInterval = 90
    public static let lockoutSeconds: TimeInterval = 300
    public static let minAttemptInterval: TimeInterval = 1
    public static let maxAttempts = 5
}
