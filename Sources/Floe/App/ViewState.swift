import SwiftUI

/// SwiftUI's `@State`, used through a type alias. From the macOS 27 SDK on,
/// `@State` is a macro whose plugin ships only with Xcode, so building with
/// just the Command Line Tools (the install script, Homebrew) fails on it.
/// The alias names the property wrapper directly and skips the macro.
typealias ViewState = SwiftUI.State
