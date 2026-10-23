import SwiftUI

struct MenuContent: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.statusText)

        Divider()

        if model.activeBreak != nil {
            Button("End break early") { model.endBreakEarly() }
        } else {
            Menu("Take break now") {
                Button("Eye") { model.startBreak([.eye]) }
                Button("Movement") { model.startBreak([.move]) }
                Button("Combined") { model.startBreak([.eye, .move]) }
            }
        }
        if !model.due.isEmpty && model.activeBreak == nil {
            Button("Snooze \(Int(model.settings.snoozeMinutes))m") { model.snooze() }
            Button("Already took a break") { model.creditDue() }
        }

        if model.pausedUntil != nil {
            Button("Resume reminders") { model.resume() }
        } else {
            Menu("Pause reminders") {
                Button("15 minutes") { model.pause(minutes: 15) }
                Button("1 hour") { model.pause(minutes: 60) }
                Button("Until tomorrow") { model.pauseUntilTomorrow() }
            }
        }

        if model.presentationMode {
            Button("End presentation mode") { model.setPresentationMode(false) }
        } else {
            Menu("Presentation mode") {
                Button("Until turned off") { model.setPresentationMode(true) }
                Button("For 1 hour") { model.setPresentationMode(true, minutes: 60) }
                Button("For 2 hours") { model.setPresentationMode(true, minutes: 120) }
            }
        }

        Divider()

        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit Break Buddy") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
