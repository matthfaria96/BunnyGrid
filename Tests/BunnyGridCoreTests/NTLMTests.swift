import Foundation
import NIOCore
import Testing
@testable import BunnyGridCore

@Suite("NTLMv2 (MS-NLMP 4.2.4 vectors)")
struct NTLMTests {
    static func hex(_ text: String) -> [UInt8] {
        let chars = Array(text.replacingOccurrences(of: " ", with: ""))
        return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0 + 1]), radix: 16)! }
    }

    @Test func md4() {
        #expect(MD4.hash([]) == Self.hex("31d6cfe0d16ae931b73c59d7e0c089c0"))
        #expect(MD4.hash(Array("abc".utf8)) == Self.hex("a448017aaf21d8525fc10ae87aa6729d"))
        #expect(MD4.hash(Array("12345678901234567890123456789012345678901234567890123456789012345678901234567890".utf8))
                == Self.hex("e33b4ddc9c38f2199c3e7b164fcc0536"))
    }

    @Test func specVectors() throws {
        #expect(NTLMClient.ntowfv2(password: "Password", user: "User", domain: "Domain") == Self.hex("0c868a403bfd7a93a3001ef22ef02e3f"))
        // AV pairs: MsvAvNbDomainName "Domain", MsvAvNbComputerName "Server", MsvAvEOL.
        let info = [2, 0, 12, 0] + TDSLogin7.utf16("Domain") + [1, 0, 12, 0] + TDSLogin7.utf16("Server") + [0, 0, 0, 0]
        let challenge = NTLMClient.Challenge(flags: 0xE28A_8233, serverChallenge: Self.hex("0123456789abcdef"), targetInfo: info)
        let client = NTLMClient(account: "Domain\\User", password: "Password", workstation: "COMPUTER")
        #expect(client.domain == "Domain" && client.user == "User")
        let r = client.responses(challenge, clientChallenge: [UInt8](repeating: 0xAA, count: 8), time: [UInt8](repeating: 0, count: 8))
        #expect(r.ntProof == Self.hex("68cd0ab851e51c96aabc927bebef6a1c"))
        #expect(r.lm == Self.hex("86c35097ac9cec102554764a57cccc19aaaaaaaaaaaaaaaa"))
        #expect(r.sessionBaseKey == Self.hex("8de40ccadbc14a82f15cb0ad0de95ca3"))
    }

    @Test func messagesRoundTrip() throws {
        let client = NTLMClient(account: "CORP\\alice", password: "pw")
        let negotiate = client.negotiate()
        #expect(Array(negotiate[0..<8]) == Array("NTLMSSP".utf8) + [0])
        #expect(negotiate[8] == 1 && negotiate.count == 40)
        // A CHALLENGE as a server would build it.
        let info = [7, 0, 8, 0] + [UInt8](repeating: 1, count: 8) + [0, 0, 0, 0]
        var challenge = Array("NTLMSSP".utf8) + [0, 2, 0, 0, 0] + [0, 0, 0, 0, 56, 0, 0, 0]
        challenge += [0x35, 0x82, 0x8A, 0xE2] + Array(1...8) + [UInt8](repeating: 0, count: 8)
        challenge += [UInt8(info.count), 0, UInt8(info.count), 0, 56, 0, 0, 0] + NTLMClient.versionBytes + info
        let parsed = try NTLMClient.parseChallenge(challenge)
        #expect(parsed.serverChallenge == Array(1...8))
        #expect(parsed.timestamp == [UInt8](repeating: 1, count: 8))
        let message = client.authenticate(parsed)
        #expect(message[8] == 3)
        let ntLength = Int(message[20]) | Int(message[21]) << 8
        #expect(ntLength == 16 + 28 + info.count + 4)
        // With a server timestamp the LM response is 24 zero bytes.
        let lmOffset = Int(message[16]) | Int(message[17]) << 8
        #expect(Array(message[lmOffset..<(lmOffset + 24)]) == [UInt8](repeating: 0, count: 24))
        #expect(throws: (any Error).self) { try NTLMClient.parseChallenge([1, 2, 3]) }
    }

    @Test func login7CarriesSSPI() {
        var login = TDSLogin7(hostName: "h", userName: "CORP\\alice", password: "pw", appName: "a", serverName: "s", database: "")
        login.sspi = [9, 8, 7]
        var buffer = login.encode()
        let bytes = buffer.readBytes(length: buffer.readableBytes)!
        #expect(bytes[25] == 0x83) // OptionFlags2 with fIntSecurity
        let sspiOffset = Int(bytes[78]) | Int(bytes[79]) << 8, sspiLength = Int(bytes[80]) | Int(bytes[81]) << 8
        #expect(sspiLength == 3 && Array(bytes[sspiOffset..<(sspiOffset + 3)]) == [9, 8, 7])
        let userLength = Int(bytes[42]) | Int(bytes[43]) << 8
        #expect(userLength == 0)
    }
}
