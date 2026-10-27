import SwiftUI

// Keep the macOS 14 property wrapper explicit when newer SDKs also expose a State macro.
typealias ForgeState<Value> = SwiftUI.State<Value>
