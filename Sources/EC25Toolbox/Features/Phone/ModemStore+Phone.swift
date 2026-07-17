import Foundation

/// Phone-oriented modem actions isolated from the core status, SMS, and
/// configuration flows.
extension ModemStore {
    /// Starts a voice call through the modem's AT dial command.
    ///
    /// - Parameter number: The phone number or service code to dial. Characters
    ///   outside `+`, digits, `*`, and `#` are stripped before sending.
    func dial(number: String) {
        let clean = sanitizedDialNumber(number)
        guard !clean.isEmpty else {
            addCallEvent(title: "phone.call_failed", detail: "phone.number_required", failed: true)
            return
        }

        run {
            _ = try await self.send("ATD\(clean);", timeout: 15_000)
            self.state.activeCallNumber = clean
            self.addCallEvent(title: "phone.calling", detail: clean)
        }
    }

    /// Hangs up the current voice call, if the modem accepts `ATH`.
    func hangUp() {
        run {
            _ = try await self.send("ATH", timeout: 8_000)
            let number = self.state.activeCallNumber ?? "phone.current_call"
            self.state.activeCallNumber = nil
            self.addCallEvent(title: "phone.ended", detail: number)
        }
    }
}
