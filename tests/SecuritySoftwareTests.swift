import Foundation

// REC-94: which security software Repair's note and the support report name (SecuritySoftware.swift),
// read from `systemextensionsctl list`. Build and run:
//   swiftc -O -target arm64-apple-macos26.5 -parse-as-library app/Sources/SecuritySoftware.swift \
//     tests/SecuritySoftwareTests.swift -o runtime/phase-3/security-software-tests
//   runtime/phase-3/security-software-tests
@main struct SecuritySoftwareTests {
    @MainActor static func main() async {
        // The owner's Mac on November 12: a mouse driver, a virtual camera waiting for approval and a
        // VPN. None of them scans files, so nothing is named.
        let owner="""
        5 extension(s)
        --- com.apple.system_extension.driver_extension (Go to 'System Settings > General > Login Items & Extensions > Driver Extensions' to modify these system extension(s))
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tR2H967U7J8\tcom.razer.appengine.driver (0.0.14/1)\tRazer HID Driver Extension\t[activated enabled]
        *\t*\tR2H967U7J8\tcom.razer.appengine.virtual.driver (0.0.13/1)\tRazer Virtual HID Driver Extension\t[activated enabled]
        --- com.apple.system_extension.cmio (Go to 'System Settings > General > Login Items & Extensions > Camera Extensions' to modify these system extension(s))
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        \t*\t2MMRE5MTB8\tcom.obsproject.obs-studio.mac-camera-extension (32.2.2/31845296735)\tOBS Virtual Camera\t[activated waiting for user]
        --- com.apple.system_extension.network_extension (Go to 'System Settings > General > Login Items & Extensions > Network Extensions' to modify these system extension(s))
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tJ6S6Q257EK\tch.protonvpn.mac.WireGuard-Extension (6.1.0/2695771.2510281342)\tProton VPN WireGuard\t[activated enabled]
        *\t*\tJ6S6Q257EK\tch.protonvpn.mac.OpenVPN-Extension (3.3.2/2308221116)\tProtonVPN OpenVPN\t[activated enabled]
        """
        precondition(SecuritySoftware.extensions(in:owner).isEmpty)
        precondition(SecuritySoftware.names(in:owner,appName:{ _ in nil }).isEmpty)

        // A Mac with a scanner (made up for the test: names and identifiers aren't a real product's),
        // one extension switched off and one waiting for approval, plus a VPN from the same vendor.
        let scanner="""
        4 extension(s)
        --- com.apple.system_extension.endpoint_security (Go to 'System Settings > General > Login Items & Extensions > Endpoint Security Extensions' to modify these system extension(s))
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tAAAAAAAAAA\tcom.example.shield.scanner (1.2/3)\tShield Scanner\t[activated enabled]
        *\t*\tAAAAAAAAAA\tcom.example.shield.realtime (1.2/3)\tShield Realtime\t[activated enabled]
        \t\tBBBBBBBBBB\tcom.example.off.scanner (1.0/1)\tOff Scanner\t[terminated waiting to uninstall on reboot]
        \t*\tCCCCCCCCCC\tcom.example.pending.scanner (1.0/1)\tPending Scanner\t[activated waiting for user]
        --- com.apple.system_extension.network_extension (Go to 'System Settings > General > Login Items & Extensions > Network Extensions' to modify these system extension(s))
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tAAAAAAAAAA\tcom.example.shield.vpn (1.2/3)\tShield VPN\t[activated enabled]
        """
        let found=SecuritySoftware.extensions(in:scanner)
        precondition(found == [.init(bundleID:"com.example.shield.scanner",name:"Shield Scanner"),
                               .init(bundleID:"com.example.shield.realtime",name:"Shield Realtime")],"\(found)")
        // Without the app macOS knows, each extension's own name stands in.
        precondition(SecuritySoftware.names(in:scanner,appName:{ _ in nil }) == ["Shield Scanner","Shield Realtime"])
        // The app both came with is named once.
        let app={ (bundleID:String) in bundleID.hasPrefix("com.example.shield.") ? "Shield Antivirus" : nil }
        precondition(SecuritySoftware.names(in:scanner,appName:app) == ["Shield Antivirus"])

        // Nothing usable: empty output, another format, a header without rows.
        for listing in ["","0 extension(s)\n","enabled active teamID\n* * X com.example.shield.scanner Shield [activated enabled]\n",
                        "--- com.apple.system_extension.endpoint_security\nenabled\tactive\tteamID\tbundleID (version)\tname\t[state]\n"] {
            precondition(SecuritySoftware.extensions(in:listing).isEmpty,listing)
        }
        // A category whose name only starts like Endpoint Security's doesn't count.
        precondition(SecuritySoftware.extensions(in:"--- com.apple.system_extension.endpoint_security_other (…)\n*\t*\tA\tcom.example.x (1)\tX\t[activated enabled]\n").isEmpty)

        // The support report's values.
        precondition(SecuritySoftware.Check.notChecked.report as? String == "not_checked")
        precondition(SecuritySoftware.Check.unavailable.report as? String == "unavailable")
        precondition(SecuritySoftware.Check.found([]).report as? String == "none")
        precondition(SecuritySoftware.Check.found(["Shield Antivirus"]).report as? [String] == ["Shield Antivirus"])

        // This Mac's own list reads without an administrator (the owner's Mac names nothing).
        let here=await SecuritySoftware.check()
        precondition(here != .unavailable,"systemextensionsctl list couldn't be read")
        print("PASS: security software names Endpoint Security extensions only, enabled and active, by their app; this Mac: \(here.names.isEmpty ? "none" : here.names.joined(separator:", "))")
    }
}
