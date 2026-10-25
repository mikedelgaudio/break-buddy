import ServiceManagement
import SwiftUI

/// Wide, tabbed settings. Choices are preset buttons rather than steppers; a value set some
/// other way (older settings file, test harness) is shown as an extra button so it's never hidden.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            BreaksPane(model: model).tabItem { Label("Breaks", systemImage: "eye") }
            MeetingsPane(model: model).tabItem { Label("Meetings", systemImage: "video") }
            SchedulePane(model: model).tabItem { Label("Schedule", systemImage: "calendar") }
            GeneralPane(model: model).tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: SettingsLayout.width)
    }
}

enum SettingsLayout {
    static let width: CGFloat = 600
}

// MARK: Panes

struct BreaksPane: View {
    let model: AppModel

    var body: some View {
        let s = SettingsBindings(model: model)
        Form {
            Section("Eye breaks — look at something far away") {
                s.presets("Every", \.eyeIntervalMinutes, [15, 20, 30, 45, 60], label: SettingsBindings.minutes)
                s.presets("For", \.eyeDurationSeconds, [20, 30, 60], label: SettingsBindings.seconds)
            }
            Section("Movement breaks — stand up and move") {
                s.presets("Every", \.moveIntervalMinutes, [30, 45, 50, 60, 90], label: SettingsBindings.minutes)
                s.presets("For", \.moveDurationSeconds, [60, 120, 180, 300], label: SettingsBindings.seconds)
            }
            Section("Reminders") {
                Picker("Show breaks as", selection: s.binding(\.reminderStyle)) {
                    Text("Full screen").tag(ReminderStyle.fullScreen)
                    Text("Notification").tag(ReminderStyle.notification)
                }
                .pickerStyle(.segmented)
                if model.settings.reminderStyle == .fullScreen {
                    Toggle("After meetings, wait for me to start the break", isOn: s.binding(\.catchUpRequiresClick))
                }
                s.presets("Snooze / remind again after", \.snoozeMinutes, [5, 10, 15, 30], label: SettingsBindings.minutes)
            }
            HStack {
                Spacer()
                Button("Restore Defaults") {
                    model.updateSettings { settings in
                        let defaults = BreakSettings()
                        settings.eyeIntervalMinutes = defaults.eyeIntervalMinutes
                        settings.eyeDurationSeconds = defaults.eyeDurationSeconds
                        settings.moveIntervalMinutes = defaults.moveIntervalMinutes
                        settings.moveDurationSeconds = defaults.moveDurationSeconds
                        settings.snoozeMinutes = defaults.snoozeMinutes
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct MeetingsPane: View {
    let model: AppModel

    var body: some View {
        let s = SettingsBindings(model: model)
        Form {
            Section {
                Toggle("Hold reminders while an app is using the microphone", isOn: s.binding(\.detectMicrophone))
                Toggle("Hold reminders while the camera is on", isOn: s.binding(\.detectCamera))
                s.presets("After a meeting, wait", \.graceSeconds, [0, 30, 60, 120], label: SettingsBindings.seconds)
            } header: {
                HStack {
                    Text("Meeting detection")
                    Spacer()
                    Text(model.detectionStatusText).foregroundStyle(.secondary)
                }
            }
            Section {
                let seen = model.seenMicApps.sorted { $0.value < $1.value }
                if seen.isEmpty {
                    Text("Apps appear here once they use the microphone.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(seen, id: \.key) { id, name in
                        Toggle(name, isOn: s.ignoreBinding(id)).help(id)
                    }
                }
            } header: {
                Text("Ignore these apps")
            } footer: {
                Text("Dictation and Siri are always ignored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                s.presets("Away after no input for", \.idleMinutes, [2, 3, 5, 10, 15], label: SettingsBindings.minutes)
                Toggle("Count time away as a break", isOn: s.binding(\.creditTimeAway))
            } header: {
                Text("Stepping away")
            } footer: {
                Text("Only your keyboard, mouse and trackpad count; agents working on their own don't. Watching a video or a meeting counts as screen time. Locked, asleep and idle time count as away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SchedulePane: View {
    let model: AppModel

    private static let hours: [(String, Int, Int)] = [("8–4", 8, 16), ("9–5", 9, 17), ("9–6", 9, 18), ("10–6", 10, 18)]

    var body: some View {
        let s = SettingsBindings(model: model)
        Form {
            Section {
                Toggle("Only remind during working hours", isOn: s.binding(\.workingHoursEnabled))
            }
            if model.settings.workingHoursEnabled {
                Section("Days") {
                    HStack(spacing: 6) {
                        ForEach(Self.weekdayOrder, id: \.self) { weekday in
                            let on = model.settings.workDays.contains(weekday)
                            ChoiceButton(title: Calendar.current.shortWeekdaySymbols[weekday - 1], selected: on) {
                                s.dayBinding(weekday).wrappedValue = !on
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    HStack {
                        Button("Weekdays") { model.updateSettings { $0.workDays = [2, 3, 4, 5, 6] } }
                        Button("Every day") { model.updateSettings { $0.workDays = Set(1...7) } }
                    }
                }
                Section("Hours") {
                    HStack {
                        ForEach(Self.hours, id: \.0) { name, start, end in
                            ChoiceButton(title: name, selected: model.settings.workStartMinutes == start * 60 && model.settings.workEndMinutes == end * 60) {
                                model.updateSettings { $0.workStartMinutes = start * 60; $0.workEndMinutes = end * 60 }
                            }
                        }
                        Spacer()
                        DatePicker("From", selection: s.timeBinding(\.workStartMinutes), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                        Text("to")
                        DatePicker("To", selection: s.timeBinding(\.workEndMinutes), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Monday first, matching most work calendars.
    private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]
}

struct GeneralPane: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Launch Break Buddy at login", isOn: Binding(
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
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                HStack {
                    Spacer()
                    Button("Quit Break Buddy") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A button that is visibly filled when selected, in light and dark mode alike.
struct ChoiceButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.08), in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Bindings

struct SettingsBindings {
    let model: AppModel

    static func minutes(_ value: Double) -> String { "\(Int(value)) min" }

    static func seconds(_ value: Double) -> String {
        value == 0 ? "None" : value < 60 || value.truncatingRemainder(dividingBy: 60) != 0 ? "\(Int(value)) sec" : "\(Int(value / 60)) min"
    }

    func binding<T>(_ keyPath: WritableKeyPath<BreakSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { value in model.updateSettings { $0[keyPath: keyPath] = value } })
    }

    func presets(_ title: String, _ keyPath: WritableKeyPath<BreakSettings, Double>, _ options: [Double], label: @escaping (Double) -> String) -> some View {
        let current = model.settings[keyPath: keyPath]
        let choices = options.contains(current) ? options : (options + [current]).sorted()
        return Picker(title, selection: binding(keyPath)) {
            ForEach(choices, id: \.self) { Text(label($0)).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    func ignoreBinding(_ appID: String) -> Binding<Bool> {
        Binding(
            get: { model.settings.ignoredApps.contains(appID) },
            set: { on in model.updateSettings { s in
                s.ignoredApps.removeAll { $0 == appID }
                if on { s.ignoredApps.append(appID) }
            } }
        )
    }

    func dayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { model.settings.workDays.contains(weekday) },
            set: { on in model.updateSettings { if on { $0.workDays.insert(weekday) } else { $0.workDays.remove(weekday) } } }
        )
    }

    func timeBinding(_ keyPath: WritableKeyPath<BreakSettings, Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(model.settings[keyPath: keyPath] * 60)) },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.updateSettings { $0[keyPath: keyPath] = (c.hour ?? 0) * 60 + (c.minute ?? 0) }
            }
        )
    }
}
