import WidgetKit
import SwiftUI

@main
struct AgorWidgetBundle: WidgetBundle {
    var body: some Widget {
        VoiceLauncherWidget()
        SessionMonitorWidget()
    }
}
