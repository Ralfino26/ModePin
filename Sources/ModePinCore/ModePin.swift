import Foundation

public enum ModePin {
    public static let bundleIdentifier = "com.ralfh.ModePin"
    public static let version = "1.0.0"

    /// Posted (distributed) when profiles change, so a running app reloads them.
    public static let profilesChangedNotification = Notification.Name("com.ralfh.ModePin.profilesChanged")
    /// Posted (distributed) to ask a running app to quit, e.g. before reinstalling.
    public static let quitNotification = Notification.Name("com.ralfh.ModePin.quit")
}
