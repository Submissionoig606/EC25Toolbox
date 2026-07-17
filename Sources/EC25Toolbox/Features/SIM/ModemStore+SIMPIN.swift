import Foundation

/// SIM PIN management through the EC25's standard CPIN/CLCK/CPWD commands.
extension ModemStore {
    func unlockSIM(pin: String, rememberForAutomaticUnlock: Bool) {
        run {
            let pin = try normalizedSIMPIN(pin)
            guard self.state.simSecurity.requiresPIN else { throw SIMPINError.simNotReady }
            _ = try await self.sendUnlogged("AT+CPIN=\"\(pin)\"", timeout: 12_000)
            try await self.waitForSIMReady()

            let iccid = try await self.currentSIMICCID()
            if rememberForAutomaticUnlock {
                do {
                    try SIMPINKeychain.save(pin, for: iccid)
                    self.updateSettings { $0.simAutoUnlock = true }
                } catch {
                    self.updateSettings { $0.simAutoUnlock = false }
                    try? SIMPINKeychain.delete(for: iccid)
                    await self.refreshSIMSecurityState(allowAutoUnlock: false)
                    throw error
                }
            }
            self.simAutoUnlockAttemptedICCID = iccid
            await self.refreshSIMSecurityState(allowAutoUnlock: false)
            try await self.refreshInfoImpl()
            try await self.refreshMessagesImpl()
            self.state.lastUpdated = Date()
        }
    }

    func setSIMLockEnabled(_ enabled: Bool, pin: String) {
        let previousValue = state.simSecurity.lockEnabled
        state.simSecurity.lockEnabled = enabled
        run {
            do {
                let pin = try normalizedSIMPIN(pin)
                guard self.state.simSecurity.isReady else { throw SIMPINError.simNotReady }
                _ = try await self.sendUnlogged(
                    "AT+CLCK=\"SC\",\(enabled ? 1 : 0),\"\(pin)\"",
                    timeout: 12_000
                )

                let iccid = try await self.currentSIMICCID()
                await self.refreshSIMSecurityState(allowAutoUnlock: false)
                if enabled, self.settings.simAutoUnlock == true {
                    do {
                        try SIMPINKeychain.save(pin, for: iccid)
                    } catch {
                        self.updateSettings { $0.simAutoUnlock = false }
                        try? SIMPINKeychain.delete(for: iccid)
                        await self.refreshSIMSecurityState(allowAutoUnlock: false)
                        throw error
                    }
                } else if !enabled {
                    self.updateSettings { $0.simAutoUnlock = false }
                    try SIMPINKeychain.delete(for: iccid)
                }
                await self.refreshSIMSecurityState(allowAutoUnlock: false)
                self.state.lastUpdated = Date()
            } catch {
                self.state.simSecurity.lockEnabled = previousValue
                throw error
            }
        }
    }

    func changeSIMPIN(currentPIN: String, newPIN: String, confirmation: String) {
        run {
            let currentPIN = try normalizedSIMPIN(currentPIN)
            let newPIN = try normalizedSIMPIN(newPIN)
            guard newPIN == trimmed(confirmation) else { throw SIMPINError.pinMismatch }
            guard self.state.simSecurity.isReady else { throw SIMPINError.simNotReady }

            _ = try await self.sendUnlogged(
                "AT+CPWD=\"SC\",\"\(currentPIN)\",\"\(newPIN)\"",
                timeout: 12_000
            )
            let iccid = try await self.currentSIMICCID()
            await self.refreshSIMSecurityState(allowAutoUnlock: false)
            if self.settings.simAutoUnlock == true || self.state.simSecurity.storedPINAvailable {
                do {
                    try SIMPINKeychain.save(newPIN, for: iccid)
                } catch {
                    self.updateSettings { $0.simAutoUnlock = false }
                    try? SIMPINKeychain.delete(for: iccid)
                    await self.refreshSIMSecurityState(allowAutoUnlock: false)
                    throw error
                }
            }
            await self.refreshSIMSecurityState(allowAutoUnlock: false)
            self.state.lastUpdated = Date()
        }
    }

    func configureSIMAutoUnlock(enabled: Bool, pin: String) {
        run {
            let iccid = try await self.currentSIMICCID()
            if enabled {
                let pin = try normalizedSIMPIN(pin)
                try SIMPINKeychain.save(pin, for: iccid)
            } else {
                self.updateSettings { $0.simAutoUnlock = false }
                try SIMPINKeychain.delete(for: iccid)
            }
            if enabled {
                self.updateSettings { $0.simAutoUnlock = true }
            }
            await self.refreshSIMSecurityState(allowAutoUnlock: false)
        }
    }

    /// Refreshes SIM status and performs at most one guarded automatic attempt per ICCID/session.
    func refreshSIMSecurityState(allowAutoUnlock: Bool) async {
        let status = parseSIMStatus((try? await sendUnlogged("AT+CPIN?", timeout: 5_000)) ?? [])
        let iccid = normalizedSIMICCID((try? await sendUnlogged("AT+QCCID", timeout: 5_000)) ?? [])
        let lockEnabled = parseSIMLockEnabled(
            (try? await sendUnlogged("AT+CLCK=\"SC\",2", timeout: 5_000)) ?? []
        )
        let retries = parseSIMRetries(
            (try? await sendUnlogged("AT+QPINC=\"SC\"", timeout: 5_000)) ?? []
        )

        var storedPIN: String?
        var keychainError: String?
        if !iccid.isEmpty {
            do {
                storedPIN = try SIMPINKeychain.read(for: iccid)
            } catch {
                keychainError = error.localizedDescription
            }
        }

        state.simSecurity = SIMSecurityState(
            status: status,
            lockEnabled: lockEnabled,
            pinRetries: retries.pin,
            pukRetries: retries.puk,
            iccid: iccid,
            storedPINAvailable: storedPIN != nil,
            lastError: keychainError
        )

        guard allowAutoUnlock,
              settings.simAutoUnlock == true,
              state.simSecurity.requiresPIN,
              !iccid.isEmpty,
              let storedPIN,
              simAutoUnlockAttemptedICCID != iccid else { return }

        guard retries.pin.map({ $0 > 1 }) ?? true else {
            state.simSecurity.lastError = SIMPINError.automaticAttemptBlocked.localizedDescription
            return
        }

        simAutoUnlockAttemptedICCID = iccid
        do {
            let pin = try normalizedSIMPIN(storedPIN)
            _ = try await sendUnlogged("AT+CPIN=\"\(pin)\"", timeout: 12_000)
            try await waitForSIMReady()
            await refreshSIMSecurityState(allowAutoUnlock: false)
        } catch {
            try? SIMPINKeychain.delete(for: iccid)
            updateSettings { $0.simAutoUnlock = false }
            await refreshSIMSecurityState(allowAutoUnlock: false)
            state.simSecurity.lastError = localized("sim_pin.error.auto_unlock_failed")
        }
    }

    private func waitForSIMReady() async throws {
        for attempt in 0..<6 {
            let status = parseSIMStatus((try? await sendUnlogged("AT+CPIN?", timeout: 5_000)) ?? [])
            if status.caseInsensitiveCompare("READY") == .orderedSame { return }
            if attempt < 5 { try? await Task.sleep(for: .seconds(1)) }
        }
        throw SIMPINError.unlockFailed
    }

    private func currentSIMICCID() async throws -> String {
        let cached = SIMPINKeychain.account(for: state.simSecurity.iccid)
        if !cached.isEmpty { return cached }
        let queried = normalizedSIMICCID((try? await sendUnlogged("AT+QCCID", timeout: 5_000)) ?? [])
        guard !queried.isEmpty else { throw SIMPINError.simIdentityUnavailable }
        return queried
    }
}
