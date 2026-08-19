import Foundation
import Security

/// Verifica che il processo all'altro capo di una connessione XPC sia
/// davvero l'app Watt firmata dal nostro team.
///
/// Un helper root senza questo controllo e' una escalation di privilegi
/// pronta all'uso: qualunque processo dell'utente potrebbe connettersi al
/// Mach service e chiedere modifiche di sistema.
///
/// Il controllo usa l'*audit token* e non il PID. Il PID e' riciclabile:
/// fra il momento in cui lo leggi e il momento in cui lo verifichi, il
/// processo puo' essere morto e un altro puo' averne ereditato il numero.
/// L'audit token identifica l'istanza esatta ed e' immune al problema.
public enum ClientVerification {

    public enum Failure: Error, CustomStringConvertible {
        case auditTokenUnavailable
        case codeObjectUnavailable(OSStatus)
        case invalidRequirement(OSStatus)
        case requirementNotMet(OSStatus)

        public var description: String {
            switch self {
            case .auditTokenUnavailable:
                return "Impossibile leggere l'audit token del client."
            case .codeObjectUnavailable(let s):
                return "SecCodeCopyGuestWithAttributes fallita (OSStatus \(s))."
            case .invalidRequirement(let s):
                return "Requisito di codesign non compilabile (OSStatus \(s))."
            case .requirementNotMet(let s):
                return "Il client non soddisfa il requisito di firma (OSStatus \(s))."
            }
        }
    }

    /// Valida la connessione contro `requirement`.
    public static func validate(connection: NSXPCConnection,
                                requirement: String) throws {
        if WattBuildConfig.skipClientVerification { return }
        guard let token = auditToken(of: connection) else {
            throw Failure.auditTokenUnavailable
        }
        try validate(auditToken: token, requirement: requirement)
    }

    public static func validate(auditToken: audit_token_t,
                                requirement: String) throws {
        var token = auditToken
        let tokenData = Data(bytes: &token,
                             count: MemoryLayout<audit_token_t>.size)
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary

        var code: SecCode?
        let copyStatus = SecCodeCopyGuestWithAttributes(nil, attributes,
                                                        [], &code)
        guard copyStatus == errSecSuccess, let clientCode = code else {
            throw Failure.codeObjectUnavailable(copyStatus)
        }

        var secRequirement: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(
            requirement as CFString, [], &secRequirement)
        guard reqStatus == errSecSuccess, let req = secRequirement else {
            throw Failure.invalidRequirement(reqStatus)
        }

        let checkStatus = SecCodeCheckValidity(clientCode, [], req)
        guard checkStatus == errSecSuccess else {
            throw Failure.requirementNotMet(checkStatus)
        }
    }

    /// `NSXPCConnection.auditToken` non fa parte dell'API pubblica, ma e'
    /// l'unico modo sicuro di identificare un client: `processIdentifier`
    /// espone al riciclo dei PID descritto sopra. Vi si accede via KVC e in
    /// caso di assenza si fallisce chiuso, rifiutando la connessione, mai
    /// ripiegando su un controllo piu' debole.
    private static func auditToken(of connection: NSXPCConnection) -> audit_token_t? {
        guard connection.responds(to: Selector(("auditToken"))),
              let boxed = connection.value(forKey: "auditToken") as? NSValue
        else { return nil }

        var token = audit_token_t()
        withUnsafeMutableBytes(of: &token) { buffer in
            boxed.getValue(buffer.baseAddress!,
                           size: MemoryLayout<audit_token_t>.size)
        }
        return token
    }
}
