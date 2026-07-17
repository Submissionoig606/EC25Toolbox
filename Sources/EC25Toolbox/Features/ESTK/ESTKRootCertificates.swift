import Foundation
import Security

/// GSMA eSIM CI trust anchors used only for ES9+ HTTPS connections.
/// The identifiers are the CI public-key IDs reported by EUICCInfo2. The
/// certificates are the public roots registered for consumer RSP deployments.
/// Reference: OpenEUICC RootCertificates and the GSMA Root CI registry.
enum ESTKRootCertificates {
    static let defaultGSMAKeyID = "81370f5125d0b1d408d4c3b232e6d25e795bebfb"

    private static let pemByKeyID: [String: String] = [
        // GSM Association - RSP2 Root CI1 (CA: DigiCert)
        defaultGSMAKeyID: """
        MIICSTCCAe+gAwIBAgIQbmhWeneg7nyF7hg5Y9+qejAKBggqhkjOPQQDAjBEMRgw
        FgYDVQQKEw9HU00gQXNzb2NpYXRpb24xKDAmBgNVBAMTH0dTTSBBc3NvY2lhdGlv
        biAtIFJTUDIgUm9vdCBDSTEwIBcNMTcwMjIyMDAwMDAwWhgPMjA1MjAyMjEyMzU5
        NTlaMEQxGDAWBgNVBAoTD0dTTSBBc3NvY2lhdGlvbjEoMCYGA1UEAxMfR1NNIEFz
        c29jaWF0aW9uIC0gUlNQMiBSb290IENJMTBZMBMGByqGSM49AgEGCCqGSM49AwEH
        A0IABJ1qutL0HCMX52GJ6/jeibsAqZfULWj/X10p/Min6seZN+hf5llovbCNuB2n
        unLz+O8UD0SUCBUVo8e6n9X1TuajgcAwgb0wDgYDVR0PAQH/BAQDAgEGMA8GA1Ud
        EwEB/wQFMAMBAf8wEwYDVR0RBAwwCogIKwYBBAGC6WAwFwYDVR0gAQH/BA0wCzAJ
        BgdngRIBAgEAME0GA1UdHwRGMEQwQqBAoD6GPGh0dHA6Ly9nc21hLWNybC5zeW1h
        dXRoLmNvbS9vZmZsaW5lY2EvZ3NtYS1yc3AyLXJvb3QtY2kxLmNybDAdBgNVHQ4E
        FgQUgTcPUSXQsdQI1MOyMubSXnlb6/swCgYIKoZIzj0EAwIDSAAwRQIgIJdYsOMF
        WziPK7l8nh5mu0qiRiVf25oa9ullG/OIASwCIQDqCmDrYf+GziHXBOiwJwnBaeBO
        aFsiLzIEOaUuZwdNUw==
        """,
        // OISITE GSMA CI G1 (CA: WISeKey)
        "4c27967ad20c14b391e9601e41e604ad57c0222f": """
        MIIB9zCCAZ2gAwIBAgIUSpBSCCDYPOEG/IFHUCKpZ2pIAQMwCgYIKoZIzj0EAwIw
        QzELMAkGA1UEBhMCQ0gxGTAXBgNVBAoMEE9JU1RFIEZvdW5kYXRpb24xGTAXBgNV
        BAMMEE9JU1RFIEdTTUEgQ0kgRzEwIBcNMjQwMTE2MjMxNzM5WhgPMjA1OTAxMDcy
        MzE3MzhaMEMxCzAJBgNVBAYTAkNIMRkwFwYDVQQKDBBPSVNURSBGb3VuZGF0aW9u
        MRkwFwYDVQQDDBBPSVNURSBHU01BIENJIEcxMFkwEwYHKoZIzj0CAQYIKoZIzj0D
        AQcDQgAEvZ3s3PFC4NgrCcCMmHJ6DJ66uzAHuLcvjJnOn+TtBNThS7YHLDyHCa2v
        7D+zTP+XTtgqgcLoB56Gha9EQQQ4xKNtMGswDwYDVR0TAQH/BAUwAwEB/zAQBgNV
        HREECTAHiAVghXQFDjAXBgNVHSABAf8EDTALMAkGB2eBEgECAQAwHQYDVR0OBBYE
        FEwnlnrSDBSzkelgHkHmBK1XwCIvMA4GA1UdDwEB/wQEAwIBBjAKBggqhkjOPQQD
        AgNIADBFAiBVcywTj017jKpAQ+gwy4MqK2hQvzve6lkvQkgSP6ykHwIhAI0KFwCD
        jnPbmcJsG41hUrWNlf+IcrMvFuYii0DasBNi
        """,
        // Entrust eSIM Certification Authority
        "16704b7f351e3607f18c4b70005c3a003dfd414a": """
        MIIC6DCCAo2gAwIBAgIRAIy4GT7M5nHsAAAAAFgsinowCgYIKoZIzj0EAwIwgbkx
        CzAJBgNVBAYTAlVTMRYwFAYDVQQKEw1FbnRydXN0LCBJbmMuMSgwJgYDVQQLEx9T
        ZWUgd3d3LmVudHJ1c3QubmV0L2xlZ2FsLXRlcm1zMTkwNwYDVQQLEzAoYykgMjAx
        NiBFbnRydXN0LCBJbmMuIC0gZm9yIGF1dGhvcml6ZWQgdXNlIG9ubHkxLTArBgNV
        BAMTJEVudHJ1c3QgZVNJTSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTAgFw0xNjEx
        MTYxNjA0MDJaGA8yMDUxMTAxNjE2MzQwMlowgbkxCzAJBgNVBAYTAlVTMRYwFAYD
        VQQKEw1FbnRydXN0LCBJbmMuMSgwJgYDVQQLEx9TZWUgd3d3LmVudHJ1c3QubmV0
        L2xlZ2FsLXRlcm1zMTkwNwYDVQQLEzAoYykgMjAxNiBFbnRydXN0LCBJbmMuIC0g
        Zm9yIGF1dGhvcml6ZWQgdXNlIG9ubHkxLTArBgNVBAMTJEVudHJ1c3QgZVNJTSBD
        ZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IA
        BAdzwGHeQ1Wb2f4DmHTByR5/IWL3JugQ1U3908a++bHdlt+TTA7K4c5cYZ+51Yz/
        hg/bacxguPDh9uQUK6Wg3a6jcjBwMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/
        BAQDAgEGMBcGA1UdIAEB/wQNMAswCQYHZ4ESAQIBADAVBgNVHREEDjAMiApghkgB
        hvpsFAoAMB0GA1UdDgQWBBQWcEt/NR42B/GMS3AAXDoAPf1BSjAKBggqhkjOPQQD
        AgNJADBGAiEAspjXMvaBZyAg86Z0AAtT0yBRAi1EyaAfNz9kDJeAE04CIQC3efj8
        ATL7/tDBOhANy3cK8PS/1NIlu9vqMLCZsZvJ0Q==
        """
    ]

    static func certificates(for reportedKeyIDs: [String]) -> [SecCertificate] {
        var selected = Set(reportedKeyIDs.map { $0.lowercased() })
        // OpenEUICC also always includes RSP2 Root CI1 because SM-DP+ servers
        // commonly use it for HTTPS even when older cards omit it from Info2.
        selected.insert(defaultGSMAKeyID)
        return selected.compactMap { keyID in
            guard let encoded = pemByKeyID[keyID] else { return nil }
            let compact = encoded.filter { !$0.isWhitespace }
            guard let der = Data(base64Encoded: compact) else { return nil }
            return SecCertificateCreateWithData(nil, der as CFData)
        }
    }
}
