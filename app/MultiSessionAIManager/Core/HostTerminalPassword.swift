//
//  HostTerminalPassword.swift
//  MultiSessionAIManager
//
//  A password the user saves for a host so the bar's key button can type it
//  into that host's terminal (a sudo prompt, say). It is not the SSH sign-in:
//  hosts sign in with keys. It never leaves the device, is never shown again,
//  never goes on the pasteboard, and is typed only after the device owner has
//  been asked.
//

import Foundation
import LocalAuthentication
import Observation
import Security

enum HostTerminalPasswordError: Error, Equatable {
    /// The owner dismissed the question.
    case cancelled
    case nothingSaved
    /// The device did not accept the face, finger or passcode.
    case refused
    /// The keychain would not do it: no device passcode, for one.
    case unavailable
}

/// Where the saved passwords are kept, one per host.
protocol HostTerminalPasswordStoring: AnyObject, Sendable {
    func hasPassword(for host: UUID) -> Bool
    func save(_ password: String, for host: UUID) throws
    func forget(for host: UUID)
    /// Asks the device owner, telling them `reason`, and hands the password over.
    func reveal(for host: UUID, reason: String) async throws -> String
}

/// For tests: keeps passwords in memory and plays the device owner.
final class InMemoryHostTerminalPasswords: HostTerminalPasswordStoring, @unchecked Sendable {
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiter: CheckedContinuation<Void, Never>?
        func open() {
            lock.lock(); isOpen = true; let waiting = waiter; waiter = nil; lock.unlock()
            waiting?.resume()
        }
        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if isOpen { lock.unlock(); continuation.resume(); return }
                waiter = continuation
                lock.unlock()
            }
        }
    }

    private let lock = NSLock()
    private var passwords: [UUID: String] = [:]
    private var asked: [String] = []
    private var failure: HostTerminalPasswordError?
    private var gate: Gate?
    private var failsToSave = false

    /// What the owner was told, once per question.
    var reasons: [String] { lock.withLock { asked } }
    /// The next question ends this way instead of with the password.
    var nextReveal: HostTerminalPasswordError? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    var savingFails: Bool {
        get { lock.withLock { failsToSave } }
        set { lock.withLock { failsToSave = newValue } }
    }

    /// The next question stays on screen until the gate is opened.
    func holdNextReveal() -> Gate {
        let held = Gate()
        lock.withLock { gate = held }
        return held
    }

    func hasPassword(for host: UUID) -> Bool { lock.withLock { passwords[host] != nil } }

    func save(_ password: String, for host: UUID) throws {
        try lock.withLock {
            if failsToSave { throw HostTerminalPasswordError.unavailable }
            passwords[host] = password
        }
    }

    func forget(for host: UUID) { lock.withLock { passwords[host] = nil } }

    func reveal(for host: UUID, reason: String) async throws -> String {
        let (held, failing, password): (Gate?, HostTerminalPasswordError?, String?) = lock.withLock {
            asked.append(reason)
            defer { gate = nil; failure = nil }
            return (gate, failure, passwords[host])
        }
        await held?.wait()
        if let failing { throw failing }
        guard let password else { throw HostTerminalPasswordError.nothingSaved }
        return password
    }
}

/// The device's keychain. A password is kept on this device only, is not in a
/// backup, goes away if the device passcode is removed, and is handed over only
/// after Face ID, Touch ID or the passcode. The system asks; the app cannot read
/// it any other way.
final class KeychainHostTerminalPasswords: HostTerminalPasswordStoring, Sendable {
    static let service = "com.codem0nky87.MultiSessionAIManager.terminal-passwords"

    private static func item(_ host: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host.uuidString,
        ]
    }

    func hasPassword(for host: UUID) -> Bool {
        var query = Self.item(host)
        // Look, never ask: an item that would need the owner counts as there.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    func save(_ password: String, for host: UUID) throws {
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, nil) else {
            throw HostTerminalPasswordError.unavailable
        }
        SecItemDelete(Self.item(host) as CFDictionary)
        var attributes = Self.item(host)
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrAccessControl as String] = access
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw HostTerminalPasswordError.unavailable
        }
    }

    func forget(for host: UUID) {
        SecItemDelete(Self.item(host) as CFDictionary)
    }

    func reveal(for host: UUID, reason: String) async throws -> String {
        // The system's question blocks the call until it is answered, so it is
        // made off the main thread.
        let (status, data): (OSStatus, Data?) = await Task.detached {
            var query = Self.item(host)
            let context = LAContext()
            context.localizedReason = reason
            query[kSecUseAuthenticationContext as String] = context
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        }.value
        switch status {
        case errSecSuccess:
            guard let data, let password = String(data: data, encoding: .utf8) else {
                throw HostTerminalPasswordError.unavailable
            }
            return password
        case errSecUserCanceled:
            throw HostTerminalPasswordError.cancelled
        case errSecItemNotFound:
            throw HostTerminalPasswordError.nothingSaved
        case errSecAuthFailed:
            throw HostTerminalPasswordError.refused
        default:
            throw HostTerminalPasswordError.unavailable
        }
    }
}

/// The bar's password button: saves a password for a host and types it into that
/// host's terminal after the device owner has been asked.
@MainActor
@Observable
final class HostTerminalPasswordKey {
    enum Outcome: Equatable {
        case typed
        /// The owner dismissed the question. Nothing to report.
        case cancelled
        /// A question is already on screen.
        case busy
        case failed(String)
    }

    @ObservationIgnored private let store: any HostTerminalPasswordStoring
    /// A question is on screen. A second tap meanwhile does nothing.
    private(set) var isAsking = false
    /// Which hosts have one saved, as far as has been looked up.
    private var saved: [UUID: Bool] = [:]

    init(store: any HostTerminalPasswordStoring = KeychainHostTerminalPasswords()) {
        self.store = store
    }

    func isSaved(for host: UUID) -> Bool {
        if let known = saved[host] { return known }
        return store.hasPassword(for: host)
    }

    /// Looks a host up once, so drawing the button does not go to the keychain.
    func refresh(for host: UUID) {
        saved[host] = store.hasPassword(for: host)
    }

    /// Saves, replacing what was there. Returns what went wrong, or nil.
    func save(_ password: String, for host: UUID) -> String? {
        guard !password.isEmpty else { return "Type the password to save." }
        do {
            try store.save(password, for: host)
            saved[host] = true
            return nil
        } catch {
            saved[host] = store.hasPassword(for: host)
            return "The password could not be saved. It is kept behind the device passcode, so this device needs one."
        }
    }

    func forget(for host: UUID) {
        store.forget(for: host)
        saved[host] = false
    }

    /// Asks the owner and types the host's password: exactly as saved, with no
    /// Return after it. Only ever the password saved for this host.
    func type(for host: UUID, named name: String, into send: ([UInt8]) -> Void) async -> Outcome {
        guard !isAsking else { return .busy }
        guard isSaved(for: host) else { return .failed("No password is saved for \(name).") }
        isAsking = true
        defer { isAsking = false }
        do {
            let password = try await store.reveal(for: host, reason: "Type the saved password for \(name) into its terminal.")
            send(Array(password.utf8))
            return .typed
        } catch HostTerminalPasswordError.cancelled {
            return .cancelled
        } catch HostTerminalPasswordError.nothingSaved {
            saved[host] = false
            return .failed("No password is saved for \(name).")
        } catch {
            return .failed("The password was not typed: this device did not confirm it is you.")
        }
    }
}
