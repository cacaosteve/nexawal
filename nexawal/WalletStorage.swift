import Foundation
import LocalAuthentication
import Security

// MARK: - Receive Subaddresses (Account 0)
//
// NexaWal supports a single wallet, but we still want multiple receive subaddresses (minor indices)
// for privacy and usability. We persist a small "subaddress book" in UserDefaults and derive
// the actual address string deterministically from the mnemonic using WalletCoreFFI.
//
// Notes:
// - We only manage account 0 here.
// - We store labels + indices, not private keys.
// - Addresses are derived on demand from the mnemonic already stored in Keychain.
//
// JSON storage key: "wallet.subaddresses.v1"

enum WalletStorageError: LocalizedError {
    case encodingFailed
    case decodingFailed
    case walletNotStored
    case missingMnemonic
    case authenticationFailed
    case cancelled
    case biometryNotAvailable
    case biometryNotEnrolled
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Unable to encode wallet metadata."
        case .decodingFailed:
            return "Unable to decode wallet metadata."
        case .walletNotStored:
            return "No wallet has been stored on this device."
        case .missingMnemonic:
            return "Stored mnemonic could not be found."
        case .authenticationFailed:
            return "Authentication was not successful."
        case .cancelled:
            return "Authentication was cancelled."
        case .biometryNotAvailable:
            return "Biometric authentication is not available on this device."
        case .biometryNotEnrolled:
            return "No biometric information is enrolled on this device."
        case .keychain(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "\(message) (status: \(status))"
            }
            return "Keychain error (status: \(status))."
        }
    }
}

struct StoredWalletMetadata: Codable, Equatable, Sendable {
    let walletId: String
    var restoreHeight: UInt64
    var lastScannedHeight: UInt64
    var chainHeight: UInt64 = 0
    var totalBalance: UInt64 = 0
    var unlockedBalance: UInt64 = 0
    var mainnet: Bool
    var biometricsEnabled: Bool
    var creationDate: Date
    var lastUpdated: Date

    init(walletId: String,
         restoreHeight: UInt64,
         lastScannedHeight: UInt64,
         chainHeight: UInt64 = 0,
         totalBalance: UInt64 = 0,
         unlockedBalance: UInt64 = 0,
         mainnet: Bool,
         biometricsEnabled: Bool,
         creationDate: Date = Date(),
         lastUpdated: Date = Date()) {
        self.walletId = walletId
        self.restoreHeight = restoreHeight
        self.lastScannedHeight = lastScannedHeight
        self.chainHeight = chainHeight
        self.totalBalance = totalBalance
        self.unlockedBalance = unlockedBalance
        self.mainnet = mainnet
        self.biometricsEnabled = biometricsEnabled
        self.creationDate = creationDate
        self.lastUpdated = lastUpdated
    }

    private enum CodingKeys: String, CodingKey {
        case walletId
        case restoreHeight
        case lastScannedHeight
        case chainHeight
        case totalBalance
        case unlockedBalance
        case mainnet
        case biometricsEnabled
        case creationDate
        case lastUpdated
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        walletId = try container.decode(String.self, forKey: .walletId)
        restoreHeight = try container.decodeIfPresent(UInt64.self, forKey: .restoreHeight) ?? 0
        lastScannedHeight = try container.decodeIfPresent(UInt64.self, forKey: .lastScannedHeight) ?? 0
        chainHeight = try container.decodeIfPresent(UInt64.self, forKey: .chainHeight) ?? 0
        totalBalance = try container.decodeIfPresent(UInt64.self, forKey: .totalBalance) ?? 0
        unlockedBalance = try container.decodeIfPresent(UInt64.self, forKey: .unlockedBalance) ?? 0
        mainnet = try container.decodeIfPresent(Bool.self, forKey: .mainnet) ?? true
        biometricsEnabled = try container.decodeIfPresent(Bool.self, forKey: .biometricsEnabled) ?? false
        let creation = try container.decodeIfPresent(Date.self, forKey: .creationDate) ?? Date()
        creationDate = creation
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? creation
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(walletId, forKey: .walletId)
        try container.encode(restoreHeight, forKey: .restoreHeight)
        try container.encode(lastScannedHeight, forKey: .lastScannedHeight)
        try container.encode(chainHeight, forKey: .chainHeight)
        try container.encode(totalBalance, forKey: .totalBalance)
        try container.encode(unlockedBalance, forKey: .unlockedBalance)
        try container.encode(mainnet, forKey: .mainnet)
        try container.encode(biometricsEnabled, forKey: .biometricsEnabled)
        try container.encode(creationDate, forKey: .creationDate)
        try container.encode(lastUpdated, forKey: .lastUpdated)
    }
}

// MARK: - Receive subaddress book (Account 0)

nonisolated struct StoredSubaddressEntry: Codable, Equatable, Sendable, Identifiable {
    /// Always account 0 for now.
    let accountIndex: UInt32
    /// Subaddress minor index.
    let subaddressIndex: UInt32
    /// User-defined label (optional).
    var label: String
    /// When it was created locally (for UX ordering).
    var createdAt: Date

    var id: String { "a\(accountIndex)-s\(subaddressIndex)" }

    init(accountIndex: UInt32 = 0, subaddressIndex: UInt32, label: String = "", createdAt: Date) {
        self.accountIndex = accountIndex
        self.subaddressIndex = subaddressIndex
        self.label = label
        self.createdAt = createdAt
    }
}

nonisolated struct StoredSubaddressBook: Codable, Equatable, Sendable {
    /// Always 0 for MVP (account 0).
    var accountIndex: UInt32 = 0
    /// Next minor index to allocate for "New address".
    var nextSubaddressIndex: UInt32 = 1
    /// Stored entries for account 0.
    var entries: [StoredSubaddressEntry] = []

    init() {}

    // Pure value-type helpers (no actor isolation intended).
    mutating func ensurePrimaryExists() {
        if !entries.contains(where: { $0.accountIndex == 0 && $0.subaddressIndex == 0 }) {
            entries.insert(StoredSubaddressEntry(accountIndex: 0, subaddressIndex: 0, label: "Primary", createdAt: Date()), at: 0)
        }
        // Ensure next index is always > max existing (excluding primary).
        let maxExisting = entries
            .filter { $0.accountIndex == 0 }
            .map { $0.subaddressIndex }
            .max() ?? 0
        let (next, overflow) = maxExisting.addingReportingOverflow(1)
        let minNext = overflow ? UInt32.max : next
        nextSubaddressIndex = max(nextSubaddressIndex, minNext)
    }

    mutating func allocateNew(label: String = "") -> StoredSubaddressEntry {
        ensurePrimaryExists()
        let idx = nextSubaddressIndex
        let (next, overflow) = nextSubaddressIndex.addingReportingOverflow(1)
        nextSubaddressIndex = overflow ? UInt32.max : next
        let e = StoredSubaddressEntry(accountIndex: 0, subaddressIndex: idx, label: label, createdAt: Date())
        entries.append(e)
        return e
    }
}

actor WalletStorage {
    static let shared = WalletStorage()

    private let keychainService = "com.nexawal.wallet"
    private let mnemonicAccount = "wallet.mnemonic"
    private let metadataKey = "wallet.metadata"
    private let simulatorMnemonicKey = "wallet.mnemonic.simulator"
    private let defaults = UserDefaults.standard

    // Receive subaddresses (account 0) persisted in UserDefaults
    private let subaddressesKey = "wallet.subaddresses.v1"

    private init() {}

    /// Persist mnemonic in the Keychain and metadata in UserDefaults.
    func storeWallet(mnemonic: String,
                     metadata: StoredWalletMetadata,
                     requireBiometrics: Bool) throws {
        try saveMnemonic(mnemonic, requireBiometrics: requireBiometrics)
        try saveMetadata(metadataUpdatingBiometrics(metadata, requireBiometrics: requireBiometrics))
    }

    /// Persist metadata without touching the mnemonic.
    func saveMetadataOnly(_ metadata: StoredWalletMetadata) throws {
        guard isWalletStored() else {
            throw WalletStorageError.walletNotStored
        }
        try saveMetadata(metadata)
    }

    /// Load stored wallet metadata (if any).
    func loadMetadata() throws -> StoredWalletMetadata? {
        guard let data = defaults.data(forKey: metadataKey) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(StoredWalletMetadata.self, from: data)
        } catch {
            throw WalletStorageError.decodingFailed
        }
    }

    /// Apply mutations to the stored metadata.
    func updateMetadata(_ transform: (inout StoredWalletMetadata) -> Void) throws {
        guard var metadata = try loadMetadata() else {
            throw WalletStorageError.walletNotStored
        }
        transform(&metadata)
        metadata.lastUpdated = Date()
        try saveMetadata(metadata)
    }

    /// Retrieve mnemonic from the Keychain, authenticating if needed.
    func loadMnemonic(prompt: String = "Unlock your wallet") throws -> String {
        guard let metadata = try loadMetadata() else {
            throw WalletStorageError.walletNotStored
        }

        #if targetEnvironment(simulator)
        if let stored = defaults.string(forKey: simulatorMnemonicKey) {
            return stored
        }
        throw WalletStorageError.missingMnemonic
        #else
        var query = baseMnemonicQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()

        if metadata.biometricsEnabled {
            query[kSecUseAuthenticationContext as String] = context
            query[kSecUseOperationPrompt as String] = prompt
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard
                let data = result as? Data,
                let mnemonic = String(data: data, encoding: .utf8)
            else {
                throw WalletStorageError.missingMnemonic
            }
            return mnemonic
        case errSecItemNotFound:
            throw WalletStorageError.missingMnemonic
        case errSecAuthFailed:
            throw WalletStorageError.authenticationFailed
        case errSecUserCanceled:
            throw WalletStorageError.cancelled
        case errSecInteractionNotAllowed:
            throw WalletStorageError.cancelled
        default:
            throw WalletStorageError.keychain(status)
        }
        #endif
    }

    /// Prompt the user for biometric/passcode authentication if it is required.
    func evaluateBiometricsIfNeeded(prompt: String = "Unlock your wallet") async throws {
        guard let metadata = try loadMetadata(), metadata.biometricsEnabled else {
            return
        }

        let context = LAContext()
        var error: NSError?
        let policy: LAPolicy = .deviceOwnerAuthentication

        guard context.canEvaluatePolicy(policy, error: &error) else {
            if let laError = error as? LAError {
                switch laError.code {
                case .biometryNotAvailable:
                    throw WalletStorageError.biometryNotAvailable
                case .biometryNotEnrolled:
                    throw WalletStorageError.biometryNotEnrolled
                default:
                    break
                }
            }
            throw WalletStorageError.authenticationFailed
        }

        try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: prompt) { success, evalError in
                if success {
                    continuation.resume()
                } else if let laError = evalError as? LAError {
                    switch laError.code {
                    case .userCancel, .appCancel, .systemCancel:
                        continuation.resume(throwing: WalletStorageError.cancelled)
                    case .biometryNotAvailable:
                        continuation.resume(throwing: WalletStorageError.biometryNotAvailable)
                    case .biometryNotEnrolled:
                        continuation.resume(throwing: WalletStorageError.biometryNotEnrolled)
                    default:
                        continuation.resume(throwing: WalletStorageError.authenticationFailed)
                    }
                } else {
                    continuation.resume(throwing: WalletStorageError.authenticationFailed)
                }
            }
        }
    }

    /// Remove all stored wallet data.
    func clearWallet() throws {
        defaults.removeObject(forKey: metadataKey)
        defaults.removeObject(forKey: subaddressesKey)
        try deleteMnemonic()
    }

    /// Check if metadata exists.
    func isWalletStored() -> Bool {
        defaults.object(forKey: metadataKey) != nil
    }

    /// Check if the mnemonic is present in the Keychain.
    func hasStoredMnemonic() -> Bool {
        #if targetEnvironment(simulator)
        return defaults.string(forKey: simulatorMnemonicKey) != nil
        #else
        var query = baseMnemonicQuery(includeData: false)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
        #endif
    }

    /// Determine whether biometrics are available/enrolled on this device.
    func biometricAvailability() -> (available: Bool, enrolled: Bool) {
        let context = LAContext()
        var error: NSError?
        let policy: LAPolicy = .deviceOwnerAuthenticationWithBiometrics

        if context.canEvaluatePolicy(policy, error: &error) {
            return (true, true)
        }

        if let laError = error as? LAError {
            switch laError.code {
            case .biometryNotEnrolled:
                return (true, false)
            case .biometryNotAvailable:
                return (false, false)
            default:
                break
            }
        }

        return (false, false)
    }

    // MARK: - Receive subaddresses (Account 0)

    /// Load the persisted subaddress book (account 0). If none exists, returns a default book with primary.
    func loadSubaddressBook() throws -> StoredSubaddressBook {
        if let data = defaults.data(forKey: subaddressesKey) {
            do {
                var book = try JSONDecoder().decode(StoredSubaddressBook.self, from: data)
                book.ensurePrimaryExists()
                return book
            } catch {
                throw WalletStorageError.decodingFailed
            }
        }
        var book = StoredSubaddressBook()
        book.ensurePrimaryExists()
        return book
    }

    /// Save the subaddress book (account 0).
    func saveSubaddressBook(_ book: StoredSubaddressBook) throws {
        do {
            let data = try JSONEncoder().encode(book)
            defaults.set(data, forKey: subaddressesKey)
        } catch {
            throw WalletStorageError.encodingFailed
        }
    }

    /// Create a new receive subaddress entry (account 0), persist it, and return it.
    /// This does NOT derive the address string; derive it later from the mnemonic using WalletCoreFFI.
    func createNewReceiveSubaddress(label: String = "") throws -> StoredSubaddressEntry {
        var book = try loadSubaddressBook()
        let entry = book.allocateNew(label: label)
        try saveSubaddressBook(book)
        return entry
    }

    /// Update the label for an existing subaddress entry (account 0).
    func updateReceiveSubaddressLabel(subaddressIndex: UInt32, label: String) throws {
        var book = try loadSubaddressBook()
        guard let i = book.entries.firstIndex(where: { $0.accountIndex == 0 && $0.subaddressIndex == subaddressIndex }) else {
            // If entry doesn't exist, ignore to keep UX forgiving.
            return
        }
        book.entries[i].label = label
        try saveSubaddressBook(book)
    }

    // MARK: - Private helpers

    private func saveMetadata(_ metadata: StoredWalletMetadata) throws {
        do {
            let data = try JSONEncoder().encode(metadata)
            defaults.set(data, forKey: metadataKey)
        } catch {
            throw WalletStorageError.encodingFailed
        }
    }

    private func saveMnemonic(_ mnemonic: String, requireBiometrics: Bool) throws {
        // On iOS, Keychain writes should be robust:
        // - Prefer "add or update" behavior (do not require a prior delete).
        // - Use a simple user-presence policy for biometric/passcode unlock (more typical UX).
        //
        // Note: We still keep ThisDeviceOnly so the mnemonic will not migrate via iCloud backups.
        #if targetEnvironment(simulator)
        defaults.set(mnemonic, forKey: simulatorMnemonicKey)
        return
        #else
        let mnemonicData = Data(mnemonic.utf8)

        // Base identity of the keychain item (no data).
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: mnemonicAccount
        ]

        // Attributes/value we want to set.
        let desiredAttributes: [String: Any]
        if requireBiometrics {
            // Typical behavior: require user presence (Face ID/Touch ID OR device passcode fallback).
            guard let accessControl = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.userPresence],
                nil
            ) else {
                throw WalletStorageError.keychain(errSecParam)
            }
            #if DEBUG
            print("🔐 Saving mnemonic with user-presence protection (biometrics/passcode)")
            #endif
            desiredAttributes = [
                kSecAttrAccessControl as String: accessControl,
                kSecValueData as String: mnemonicData
            ]
        } else {
            #if DEBUG
            print("🔐 Saving mnemonic without biometrics using accessibility \(String(describing: kSecAttrAccessibleWhenUnlockedThisDeviceOnly))")
            #endif
            desiredAttributes = [
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                kSecValueData as String: mnemonicData
            ]
        }

        // Attempt to add first.
        var addQuery = base
        for (k, v) in desiredAttributes { addQuery[k] = v }

        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Update existing item instead of failing.
            // For update, the value/attributes must be supplied in the "attributesToUpdate" dictionary.
            let attributesToUpdate = desiredAttributes
            status = SecItemUpdate(base as CFDictionary, attributesToUpdate as CFDictionary)
        }

        guard status == errSecSuccess else {
            print("🔐 Keychain save failed with status \(status) requireBiometrics=\(requireBiometrics)")
            throw WalletStorageError.keychain(status)
        }
        #endif
    }

    private func deleteMnemonic() throws {
        #if targetEnvironment(simulator)
        defaults.removeObject(forKey: simulatorMnemonicKey)
        return
        #else
        let status = SecItemDelete(baseMnemonicQuery(includeData: false) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WalletStorageError.keychain(status)
        }
        #endif
    }

    private func baseMnemonicQuery(includeData: Bool = true) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: mnemonicAccount,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        query[kSecReturnData as String] = includeData
        return query
    }

    private func metadataUpdatingBiometrics(_ metadata: StoredWalletMetadata,
                                            requireBiometrics: Bool) -> StoredWalletMetadata {
        var updated = metadata
        updated.biometricsEnabled = requireBiometrics
        updated.lastUpdated = Date()
        return updated
    }
}
