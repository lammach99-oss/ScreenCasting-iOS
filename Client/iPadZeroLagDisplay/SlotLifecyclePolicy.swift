// Coordinator executes these effects in order on the indicated manager.
// Release covers input, audio and clipboard. Park leaves transport readers and timers running.
struct SlotLifecyclePolicy {
    enum Effect: Equatable {
        case releaseAuthority(SlotOrdinal)
        case hidePreview(SlotOrdinal)
        case suspendUSB(SlotOrdinal)
        case applyWiFiGrace(SlotOrdinal)
        case revalidateSessionPictureAndAuthority(SlotOrdinal)
    }

    func park(_ slot: SlotOrdinal) -> [Effect] {
        [.releaseAuthority(slot)]
    }

    func background(primary: SlotTransportClass, secondary: SlotRoute?) -> [Effect] {
        let slots: [SlotOrdinal] = secondary == nil ? [.one] : [.one, .two]
        var effects: [Effect] = slots.flatMap { [.releaseAuthority($0), .hidePreview($0)] }
        effects.append(primary == .usb ? .suspendUSB(.one) : .applyWiFiGrace(.one))
        if secondary != nil { effects.append(.applyWiFiGrace(.two)) }
        return effects
    }

    func foreground(hasSecondary: Bool) -> [Effect] {
        let slots: [SlotOrdinal] = hasSecondary ? [.one, .two] : [.one]
        return slots.map { .revalidateSessionPictureAndAuthority($0) }
    }
}
