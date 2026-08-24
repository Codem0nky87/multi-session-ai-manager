import Testing
import Foundation
@testable import MultiSessionAIManager

@Test func installScriptIsIdempotentAndShellQuoted() {
    let pub = "ssh-ed25519 AAAAC3Nz... msam"
    let s = KeyInstallerScript.authorizedKeysInstallScript(publicKey: pub)
    #expect(s.contains("mkdir -p ~/.ssh"))
    #expect(s.contains("chmod 700 ~/.ssh"))
    #expect(s.contains("chmod 600 ~/.ssh/authorized_keys"))
    #expect(s.contains("grep -qxF"))
    #expect(s.contains(">> ~/.ssh/authorized_keys"))
    #expect(s.contains("'\(pub)'"))   // single-quoted exactly
}

@Test func installScriptEscapesSingleQuotes() {
    let s = KeyInstallerScript.authorizedKeysInstallScript(publicKey: "a'b")
    #expect(s.contains("'a'\\''b'"))   // ' -> '\'' inside single quotes
}
