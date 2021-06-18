import Foundation
@_implementationOnly import MapboxCommon_Private

enum NavigationBillingMethod: String {
    case user = "user"
    case request = "request"
    
    static let allValues: [Self] = [.user, .request]
}

@objc(MBXAccounts)
public class Accounts: NSObject {
    @objc public static var serviceSkuToken: String? {
        return BillingHandler.shared.getSessionToken()
    }
}
