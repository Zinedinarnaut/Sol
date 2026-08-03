import WidgetKit
import SwiftUI

@main
struct SolWidgets: WidgetBundle {
    var body: some Widget {
        RecentlyPlayedWidget()
        TopPlayedWidget()
        QuickLaunchWidget()
    }
}
