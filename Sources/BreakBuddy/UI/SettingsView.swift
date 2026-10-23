import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Eye breaks") {
                stepper("Every", \.eyeIntervalMinutes, in: 5...120, step: 5, unit: "min")
                stepper("For", \.eyeDurationSeconds, in: 10...120, step: 5, unit: "sec")
            }
            Section("Movement breaks") {
                stepper("Every", \.moveIntervalMinutes, in: 15...180, step: 5, unit: "min")
                stepper("For", \.moveDurationSeconds, in: 30...600, step: 30, unit: "sec")
            }
            Section("Reminders") {
                stepper("Snooze", \.snoozeMinutes, in: 1...30, step: 1, unit: "min")
                stepper("Wait after meetings", \.graceSeconds, in: 0...600, step: 15, unit: "sec")
                Toggle("Count locked or asleep time as a break", isOn: binding(\.creditTimeAway))
            }
            Section("Working hours") {
                Toggle("Only remind during working hours", isOn: binding(\.workingHoursEnabled))
                if model.settings.workingHoursEnabled {
                    HStack {
                        ForEach(Array(Calendar.current.veryShortWeekdaySymbols.enumerated()), id: \.offset) { index, symbol in
                            Toggle(symbol, isOn: dayBinding(index + 1))
                                .toggleStyle(.button)
                        }
                    }
                    DatePicker("Start", selection: timeBinding(\.workStartMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: timeBinding(\.workEndMinutes), displayedComponents: .hourAndMinute)
                }
            }
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.settings.launchAtLogin },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            model.updateSettings { $0.launchAtLogin = on }
                        } catch {
                            NSLog("Launch at login change failed: \(error)")
                        }
                    }
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<BreakSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { value in model.updateSettings { $0[keyPath: keyPath] = value } })
    }

    private func stepper(_ title: String, _ keyPath: WritableKeyPath<BreakSettings, Double>, in range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        Stepper(value: binding(keyPath), in: range, step: step) {
            LabeledContent(title, value: "\(Int(model.settings[keyPath: keyPath])) \(unit)")
        }
    }

    private func dayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { model.settings.workDays.contains(weekday) },
            set: { on in model.updateSettings { if on { $0.workDays.insert(weekday) } else { $0.workDays.remove(weekday) } } }
        )
    }

    private func timeBinding(_ keyPath: WritableKeyPath<BreakSettings, Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(model.settings[keyPath: keyPath] * 60)) },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.updateSettings { $0[keyPath: keyPath] = (c.hour ?? 0) * 60 + (c.minute ?? 0) }
            }
        )
    }
}
