/* Korean account support (issue #16), experimental, off unless the player turns it on in
 * Settings › Advanced (state.json's korean_support). Since 2026-08-12 Nexon runs Overwatch
 * on Battle.net in Korea, and the Korean build ships Nexon's anti-cheat. Two Wine gaps
 * stopped it; neither change touches the anti-cheat:
 * - At start the game checks that the signature on gamescale64.dll chains to DigiCert
 *   Assured ID Root CA. Windows gets there through "DigiCert Trusted Root G4" cross-signed
 *   by that root; Wine stops at the self-signed G4 that macOS's keychain provides, so the
 *   game exited ("Manager failed to start", 0xE01300B0). Recall adds the cross-signed G4
 *   to HKCU's Root store, which Wine's chain engine consults first. It is the same key as
 *   the G4 root macOS already trusts, signed by another root macOS trusts, so it adds no
 *   trust; it lives only in Recall's Windows environment and goes when the option is off.
 * - The anti-cheat takes screenshots of the screen now and then (GetDC(NULL) + StretchBlt).
 *   Wine's Mac driver can't read the screen back, so the call failed and the game crashed
 *   about five minutes in. With WINEMAC_SCREEN_READBACK=1 (set at launch while the option
 *   is on) the driver answers with a black image instead (wine-winemac-activation.patch).
 * Recall suggests the option when the game folder holds Nexon's files (nexonBuild). */

// DigiCert Trusted Root G4, cross-signed by DigiCert Assured ID Root CA (serial
// 0E9B188EF9D02DE7EFDB50E20840185A, valid 2022-08-01 to 2031-11-09), DER in base64.
static NSString *const crossSignedG4=
    @"MIIFjTCCBHWgAwIBAgIQDpsYjvnQLefv21DiCEAYWjANBgkqhkiG9w0BAQwFADBlMQswCQYDVQQG"
    @"EwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSQw"
    @"IgYDVQQDExtEaWdpQ2VydCBBc3N1cmVkIElEIFJvb3QgQ0EwHhcNMjIwODAxMDAwMDAwWhcNMzEx"
    @"MTA5MjM1OTU5WjBiMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQL"
    @"ExB3d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwggIi"
    @"MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC/5pBzaN675F1KPDAiMGkz7MKnJS7JIT3yithZ"
    @"wuEppz1Yq3aaza57G4QNxDAf8xukOBbrVsaXbR2rsnnyyhHS5F/WBTxSD1Ifxp4VpX6+n6lXFllV"
    @"cq9ok3DCsrp1mWpzMpTREEQQLt+C8weE5nQ7bXHiLQwb7iDVySAdYyktzuxeTsiT+CFhmzTrBcZe"
    @"7FsavOvJz82sNEBfsXpm7nfISKhmV1efVFiODCu3T6cw2Vbuyntd463JT17lNecxy9qTXtyOj4Da"
    @"tpGYQJB5w3jHtrHEtWoYOAMQjdjUN6QuBX2I9YI+EJFwq1WCQTLX2wRzKm6RAXwhTNS8rhsDdV14"
    @"Ztk6MUSaM0C/CNdaSaTC5qmgZ92kJ7yhTzm1EVgX9yRcRo9k98FpiHaYdj1ZXUJ2h4mXaXpI8OCi"
    @"EhtmmnTK3kse5w5jrubU75KSOp493ADkRSWJtppEGSt+wJS00mFt6zPZxd9LBADMfRyVw4/3IbKy"
    @"Ebe7f/LVjHAsQWCqsWMYRJUadmJ+9oCw++hkpjPRiQfhvbfmQ6QYuKZ3AeEPlAwhHbJUKSWJbOUO"
    @"UlFHdL4mrLZBdd56rF+NP8m800ERElvlEFDrMcXKchYiCd98THU/Y+whX8QgUWtvsauGi0/C1kVf"
    @"nSD8oR7FwI+isX4KJpn15GkvmB0t9dmpsh3lGwIDAQABo4IBOjCCATYwDwYDVR0TAQH/BAUwAwEB"
    @"/zAdBgNVHQ4EFgQU7NfjgtJxXWRM3y5nP+e6mK4cD08wHwYDVR0jBBgwFoAUReuir/SSy4IxLVGL"
    @"p6chnfNtyA8wDgYDVR0PAQH/BAQDAgGGMHkGCCsGAQUFBwEBBG0wazAkBggrBgEFBQcwAYYYaHR0"
    @"cDovL29jc3AuZGlnaWNlcnQuY29tMEMGCCsGAQUFBzAChjdodHRwOi8vY2FjZXJ0cy5kaWdpY2Vy"
    @"dC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3J0MEUGA1UdHwQ+MDwwOqA4oDaGNGh0dHA6"
    @"Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcmwwEQYDVR0gBAow"
    @"CDAGBgRVHSAAMA0GCSqGSIb3DQEBDAUAA4IBAQBwoL9DXFXnOF+go3QbPbYW1/e/Vwe9mqyhhyzs"
    @"hV6pGrsi+IcaaVQi7aSId229GhT0E0p6Ly23OO/0/4C5+KH38nLeJLxSA8hO0Cre+i1Wz/n096ww"
    @"epqLsl7Uz9FDRJtDIeuWcqFItJnLnU+nBgMTdydE1Od/6Fmo8L8vC6bp8jQ87PcDx4eo0kxAGTVG"
    @"amlUsLihVo7spNU96LHc/RzY9HdaXFSMb++hUD38dglohJ9vytsgjTVgHAIDyyCwrFigDkBjxZgi"
    @"wbJZ9VVrzyerbHbObyMt9H5xaiNrIv8SuFQtJ37YOtnwtoeW/VvRXKwYw02fc7cBqZ9Xql4o4rmU";
static NSString *const crossSignedG4SHA256=@"33846b545a49c9be4903c60e01713c1bd4e4ef31ea65cd95d69e62794f30b941";
// Its SHA-1, the key name Wine's registry store requires (uppercase).
static NSString *const crossSignedG4Key=@"A99D5B79E9F1CDA59CDAB6373169D5353F5874C6";
static NSString *const rootCertificatesKey=@"Software\\Microsoft\\SystemCertificates\\Root\\Certificates";
static BOOL koreanSupportChosen(void) { return [state()[@"korean_support"] isEqual:@YES]; }
// The certificate as Wine's registry store keeps it ("Blob"): its SHA-1 hash property
// (3), then the certificate itself (32), each as {id, 1, size} and the bytes.
static NSData *crossSignedG4Blob(void) {
    NSData *der=[[NSData alloc] initWithBase64EncodedString:crossSignedG4 options:0];
    unsigned char sha256[CC_SHA256_DIGEST_LENGTH],sha1[CC_SHA1_DIGEST_LENGTH];
    if(!der)fail(@"korean_support_failed");
    CC_SHA256(der.bytes,(CC_LONG)der.length,sha256);CC_SHA1(der.bytes,(CC_LONG)der.length,sha1);
    if(![hexString([NSData dataWithBytes:sha256 length:sizeof(sha256)]) isEqual:crossSignedG4SHA256] ||
       ![hexString([NSData dataWithBytes:sha1 length:sizeof(sha1)]).uppercaseString isEqual:crossSignedG4Key])fail(@"korean_support_failed");
    NSMutableData *blob=[NSMutableData data];
    uint32_t hash[3]={3,1,sizeof(sha1)},certificate[3]={32,1,(uint32_t)der.length};
    [blob appendBytes:hash length:sizeof(hash)];[blob appendBytes:sha1 length:sizeof(sha1)];
    [blob appendBytes:certificate length:sizeof(certificate)];[blob appendData:der];
    return blob;
}
// Whether the Root store has the certificate (any Blob under its key: Wine checks the hash).
static BOOL crossSignedG4Installed(NSDictionary *values) { return registryBinary(values[@"Blob"]).length>0; }
/* Adds the certificate (ENABLED) or removes it. Without ENGINE it only reports what would
 * change; with KEEP, an installed certificate is never removed (setup and launch only add
 * it, so one a player added by hand stays until they turn the option off). Never fails:
 * callers decide. Reports korean_support. */
static BOOL configureKoreanCertificate(NSString *engine, BOOL enabled, BOOL keep) {
    NSDictionary *values=userRegistryValues([rootCertificatesKey stringByAppendingFormat:@"\\%@",crossSignedG4Key]);
    BOOL installed=values && crossSignedG4Installed(values),ok=YES;
    BOOL change=enabled ? !installed : (!keep && (installed || !values));
    NSMutableDictionary *details=[@{@"enabled":@(enabled),@"changed":@NO} mutableCopy];
    if(!values)details[@"registry"]=@"unreadable";
    if(engine && change) {
        NSString *key=[NSString stringWithFormat:@"HKCU\\%@\\%@",rootCertificatesKey,crossSignedG4Key];
        ok=enabled ? registryTool(engine,@[@"add",key,@"/v",@"Blob",@"/t",@"REG_BINARY",@"/d",hexString(crossSignedG4Blob()),@"/f"],@"korean-support.log")
                   : registryTool(engine,@[@"delete",key,@"/f"],@"korean-support.log");
        // Removing a key that was never there fails; nothing is installed then.
        if(!ok && !enabled && values && !installed)ok=YES;
        details[@"changed"]=@(ok);
        if(!ok)details[@"failed"]=@YES;
    }
    else if(!engine)details[@"changed"]=@(change);
    event(@"korean_support",details);
    return ok;
}
// The Korean build installs Nexon's anti-cheat beside the game (grap64.dll and grap\).
static BOOL nexonBuild(void) {
    NSString *game=join(root,@"environment/drive_c/Program Files (x86)/Overwatch/_retail_");
    return [fm fileExistsAtPath:join(game,@"grap64.dll")] || [fm fileExistsAtPath:join(game,@"grap")];
}
