import Foundation
import MarkdownCore
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Testing
#if canImport(UIKit)
import UIKit

@MainActor
private final class AppearanceDriver: RenderSessionDriving {
    let resourceTaskOwner = RenderSessionResourceTaskOwner()
    let linkConfiguration = MarkdownLinkConfiguration.webOnly()
    var configurations: [RenderConfigurationSnapshot] = []
    func send(_ mutation: RenderSessionMutation) {
        switch mutation {
        case .setSource(_, let configuration), .replaceConfiguration(let configuration):
            self.configurations.append(configuration)
        default: break
        }
    }

    func replaceLinkConfiguration(_ configuration: MarkdownLinkConfiguration) {}
    func activateLink(_ url: URL, sourceRange: MarkdownSourceRange?) {}
}

@MainActor
struct AppearanceRefreshTests {
    @Test func existingViewRefreshesColorsWhenAppearanceChanges() throws {
        let driver = AppearanceDriver()
        let view = MarkdownLabelView(frame: CGRect(x: 0, y: 0, width: 350, height: 500), driver: driver)
        view.traitOverrides.userInterfaceStyle = .light
        view.updateTraitsIfNeeded()
        view.setMarkdown("Existing **text**")
        let light = try #require(driver.configurations.last)
        let count = driver.configurations.count
        view.traitOverrides.userInterfaceStyle = .dark
        view.updateTraitsIfNeeded()
        #expect(driver.configurations.count > count)
        let dark = try #require(driver.configurations.last)
        #expect(light.colors.body != dark.colors.body)
        view.traitOverrides.userInterfaceStyle = .light
        view.updateTraitsIfNeeded()
        #expect(driver.configurations.last?.colors.body == light.colors.body)
    }

    @Test func explicitThemeStaysFixedAndClearingItRestoresSystem() throws {
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 350, height: 500))
        parent.traitOverrides.userInterfaceStyle = .dark
        let driver = AppearanceDriver()
        let view = MarkdownLabelView(frame: parent.bounds, driver: driver)
        parent.addSubview(view)
        parent.updateTraitsIfNeeded()
        view.theme = .light
        view.setMarkdown("Fixed theme")
        let light = try #require(driver.configurations.last?.colors.body)
        parent.traitOverrides.userInterfaceStyle = .light
        parent.updateTraitsIfNeeded()
        parent.traitOverrides.userInterfaceStyle = .dark
        parent.updateTraitsIfNeeded()
        #expect(driver.configurations.last?.colors.body == light)
        view.theme = nil
        parent.updateTraitsIfNeeded()
        #expect(driver.configurations.last?.colors.body != light)
        view.theme = .light
        #expect(driver.configurations.last?.colors.body == light)
    }
}
#endif
