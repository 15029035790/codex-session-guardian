import Foundation

public enum XiaoxinSpeechIntensity: String, CaseIterable, Sendable {
    case off
    case light
    case active
}

public enum XiaoxinSpeechContext: Equatable, Sendable {
    case welcome
    case idle
    case working
    case thinking
    case reading
    case runningCommand
    case callingTool
    case editing
    case waitingForUser
    case responding
    case failed
    case multitask
    case refresh
    case watch
    case danger
    case handoff
    case success
    case hover
    case drag
    case doubleClick
}

public struct XiaoxinSpeechLine: Equatable, Sendable {
    public let localizationKey: String
    public let minimumIntensity: XiaoxinSpeechIntensity

    public init(_ localizationKey: String, minimumIntensity: XiaoxinSpeechIntensity = .light) {
        self.localizationKey = localizationKey
        self.minimumIntensity = minimumIntensity
    }
}

public enum XiaoxinSpeechCatalog {
    public static func lines(
        for context: XiaoxinSpeechContext,
        intensity: XiaoxinSpeechIntensity
    ) -> [XiaoxinSpeechLine] {
        guard intensity != .off else { return [] }
        return allLines(for: context).filter { line in
            switch (line.minimumIntensity, intensity) {
            case (.light, .light), (.light, .active), (.active, .active): true
            default: false
            }
        }
    }

    private static func allLines(for context: XiaoxinSpeechContext) -> [XiaoxinSpeechLine] {
        switch context {
        case .welcome:
            [
                XiaoxinSpeechLine("pet.speech.welcome.returned_home"),
                XiaoxinSpeechLine("pet.speech.welcome.hello", minimumIntensity: .active),
            ]
        case .idle:
            [
                XiaoxinSpeechLine("pet.speech.idle.sunny"),
                XiaoxinSpeechLine("pet.speech.idle.snack", minimumIntensity: .active),
            ]
        case .working:
            [
                XiaoxinSpeechLine("pet.speech.working.my_turn"),
                XiaoxinSpeechLine("pet.speech.working.watch_me", minimumIntensity: .active),
            ]
        case .thinking:
            [
                XiaoxinSpeechLine("pet.speech.thinking.clue"),
                XiaoxinSpeechLine("pet.speech.thinking.detective", minimumIntensity: .active),
            ]
        case .reading:
            [
                XiaoxinSpeechLine("pet.speech.reading.look_closer"),
                XiaoxinSpeechLine("pet.speech.reading.no_peeking", minimumIntensity: .active),
            ]
        case .runningCommand:
            [
                XiaoxinSpeechLine("pet.speech.command.go"),
                XiaoxinSpeechLine("pet.speech.command.machine", minimumIntensity: .active),
            ]
        case .callingTool:
            [
                XiaoxinSpeechLine("pet.speech.tool.helper"),
                XiaoxinSpeechLine("pet.speech.tool.gadget", minimumIntensity: .active),
            ]
        case .editing:
            [
                XiaoxinSpeechLine("pet.speech.editing.careful"),
                XiaoxinSpeechLine("pet.speech.editing.crayon", minimumIntensity: .active),
            ]
        case .waitingForUser:
            [
                XiaoxinSpeechLine("pet.speech.waiting.your_turn"),
                XiaoxinSpeechLine("pet.speech.waiting.not_rushing", minimumIntensity: .active),
            ]
        case .responding:
            [
                XiaoxinSpeechLine("pet.speech.responding.almost"),
                XiaoxinSpeechLine("pet.speech.responding.listen", minimumIntensity: .active),
            ]
        case .failed:
            [
                XiaoxinSpeechLine("pet.speech.failed.check"),
                XiaoxinSpeechLine("pet.speech.failed.try_again", minimumIntensity: .active),
            ]
        case .multitask:
            [
                XiaoxinSpeechLine("pet.speech.multitask.defense_force"),
                XiaoxinSpeechLine("pet.speech.multitask.busy", minimumIntensity: .active),
            ]
        case .refresh:
            [
                XiaoxinSpeechLine("pet.speech.refresh.let_me_see"),
                XiaoxinSpeechLine("pet.speech.refresh.found_it", minimumIntensity: .active),
            ]
        case .watch:
            [
                XiaoxinSpeechLine("pet.speech.watch.crowded"),
                XiaoxinSpeechLine("pet.speech.watch.take_it_easy", minimumIntensity: .active),
            ]
        case .danger:
            [
                XiaoxinSpeechLine("pet.speech.danger.do_not_push"),
            ]
        case .handoff:
            [
                XiaoxinSpeechLine("pet.speech.handoff.action_beam"),
                XiaoxinSpeechLine("pet.speech.handoff.pack_context", minimumIntensity: .active),
            ]
        case .success:
            [
                XiaoxinSpeechLine("pet.speech.success.amazing"),
                XiaoxinSpeechLine("pet.speech.success.ready", minimumIntensity: .active),
            ]
        case .hover:
            [
                XiaoxinSpeechLine("pet.speech.hover.oh"),
                XiaoxinSpeechLine("pet.speech.hover.hey"),
                XiaoxinSpeechLine("pet.speech.hover.not_slacking", minimumIntensity: .active),
                XiaoxinSpeechLine("pet.speech.hover.pretty_sister", minimumIntensity: .active),
            ]
        case .drag:
            [
                XiaoxinSpeechLine("pet.speech.drag.new_home"),
                XiaoxinSpeechLine("pet.speech.drag.hair"),
                XiaoxinSpeechLine("pet.speech.drag.moving_day", minimumIntensity: .active),
                XiaoxinSpeechLine("pet.speech.drag.good_fengshui", minimumIntensity: .active),
            ]
        case .doubleClick:
            [
                XiaoxinSpeechLine("pet.speech.double_click.smarter"),
                XiaoxinSpeechLine("pet.speech.double_click.action_beam"),
                XiaoxinSpeechLine("pet.speech.double_click.only_five", minimumIntensity: .active),
                XiaoxinSpeechLine("pet.speech.double_click.ticket", minimumIntensity: .active),
            ]
        }
    }
}

public struct XiaoxinSpeechScheduler: Sendable {
    private var lastEmissionAt: Date?
    private var shownAt: [String: Date] = [:]
    private var cursor = 0

    public init() {}

    public mutating func nextLine(
        for context: XiaoxinSpeechContext,
        intensity: XiaoxinSpeechIntensity,
        now: Date = Date(),
        minimumGap: TimeInterval = 8,
        repeatCooldown: TimeInterval = 10 * 60,
        bypassMinimumGap: Bool = false,
        bypassRepeatCooldown: Bool = false
    ) -> XiaoxinSpeechLine? {
        let lines = XiaoxinSpeechCatalog.lines(for: context, intensity: intensity)
        guard !lines.isEmpty else { return nil }
        if !bypassMinimumGap, let lastEmissionAt,
           now.timeIntervalSince(lastEmissionAt) < minimumGap {
            return nil
        }

        let start = cursor % lines.count
        let ordered = Array(lines[start...] + lines[..<start])
        guard let line = ordered.first(where: { candidate in
            if bypassRepeatCooldown { return true }
            guard let date = shownAt[candidate.localizationKey] else { return true }
            return now.timeIntervalSince(date) >= repeatCooldown
        }) else { return nil }

        cursor &+= 1
        shownAt[line.localizationKey] = now
        lastEmissionAt = now
        shownAt = shownAt.filter { now.timeIntervalSince($0.value) < repeatCooldown }
        return line
    }
}
