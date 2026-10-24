/* Korean account support (issue #16), experimental, off unless the player turns it on in
 * Settings › Advanced (state.json's korean_support). Since 2026-08-12 Nexon runs Overwatch
 * on Battle.net in Korea, and the Korean build ships Nexon's anti-cheat. Two Wine gaps
 * stopped it; neither change touches the anti-cheat:
 * - At start the game checks that the signature on gamescale64.dll chains to DigiCert
 *   Assured ID Root CA. Windows gets there through "DigiCert Trusted Root G4" cross-signed
 *   by that root; Wine can instead stop at the self-signed G4 that macOS provides, so the
 *   game exits ("Manager failed to start", 0xE01300B0). The cross-signed G4 alone does not
 *   fix this when macOS no longer supplies Assured ID Root CA. Recall installs both
 *   pinned public certificates into its Wine environment's HKCU Root store, which Wine's
 *   chain engine consults first. This adds the named Assured root to that environment's
 *   trust store only; macOS's keychain is untouched. Turning support off removes both
 *   managed keys, including copies that were previously installed by hand.
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
// DigiCert Assured ID Root CA (self-signed, valid 2006-11-10 to 2031-11-10).
// Official DER and fingerprints: https://knowledge.digicert.com/general-information/digicert-trusted-root-authority-certificates
// This completes the cross-signed G4 chain even when macOS no longer supplies this root.
static NSString *const assuredRoot=
    @"MIIDtzCCAp+gAwIBAgIQDOfg5RfYRv6P5WD8G/AwOTANBgkqhkiG9w0BAQUFADBlMQswCQYDVQQG"
    @"EwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSQw"
    @"IgYDVQQDExtEaWdpQ2VydCBBc3N1cmVkIElEIFJvb3QgQ0EwHhcNMDYxMTEwMDAwMDAwWhcNMzEx"
    @"MTEwMDAwMDAwWjBlMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQL"
    @"ExB3d3cuZGlnaWNlcnQuY29tMSQwIgYDVQQDExtEaWdpQ2VydCBBc3N1cmVkIElEIFJvb3QgQ0Ew"
    @"ggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCtDhXO5EOAXLGH87dg+XESpa7cJpSIqvTO"
    @"9SA5KFhgDPiA2qkVlTJhPLWxKISKityfCgyDF3qPkKyK53lTXDGEKvYPmDI2dsze3Tyoou9q+yHy"
    @"UmHfnyDXH+Kx2f4YZNISW1/5WBg1vEfNoTb5a3/UsDg+wRvDjDPZ2C8Y/igPs6eD1sNuRMBhNZYW"
    @"/lmci3Zt1/GiSw0r/wty2p5g0I6QNcZ4VYcgoc/lbQrISXwxmDNsIumH0DJaoroTghHtORedmTpy"
    @"oeb6pNnVFzF1roV9Iq4/AUaG9ih5yLHa5FcXxH4cDrC0kqZWs72yl+2qp/C3xag/lRbQ/6GW6whf"
    @"GHdPAgMBAAGjYzBhMA4GA1UdDwEB/wQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBRF"
    @"66Kv9JLLgjEtUYunpyGd823IDzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzANBgkq"
    @"hkiG9w0BAQUFAAOCAQEAog683+Lt8ONyc3pklL/3cmbYMuRCdWKuh+vy1dneVrOfzM4UKLkNl2Bc"
    @"EkxY5NM9g0lFWJc1aRqoR+pWxnmrEthngYTffwk8lOa4JiwgvT2zKIn3X/8i4peEH+ll74fg38Fn"
    @"SbNd67IJKusm7Xi+fT8r87cmNW1fiQG2SVufAQWbqz0lwcy2f8Lxb4bG+mRo64EtlOtCt/qMHt1i"
    @"8b5QZ7dsvfPxH2sMNgcWfzd8qVttevESRmCD1ycEvkvOl77DZypoEd+A5wwzZr8TDRRu838fYxAe"
    @"+o0bJW1sj6W3YQGx0qMmoRBxna3iw/nDmVG3KwcIzi7mULKn+gpFL6Lw8g==";
static NSString *const assuredRootSHA256=@"3e9099b5015e8f486c00bcea9d111ee721faba355a89bcf1df69561e3dc6325c";
static NSString *const assuredRootKey=@"0563B8630D62D75ABBC8AB1E4BDFB5A899B24D43";
static NSString *const rootCertificatesKey=@"Software\\Microsoft\\SystemCertificates\\Root\\Certificates";
static BOOL koreanSupportChosen(void) { return [state()[@"korean_support"] isEqual:@YES]; }
// The certificate as Wine's registry store keeps it ("Blob"): its SHA-1 hash property
// (3), then the certificate itself (32), each as {id, 1, size} and the bytes.
static NSData *koreanCertificateBlob(NSString *encoded, NSString *expectedSHA256, NSString *key) {
    NSData *der=[[NSData alloc] initWithBase64EncodedString:encoded options:0];
    unsigned char sha256[CC_SHA256_DIGEST_LENGTH],sha1[CC_SHA1_DIGEST_LENGTH];
    if(!der)fail(@"korean_support_failed");
    CC_SHA256(der.bytes,(CC_LONG)der.length,sha256);CC_SHA1(der.bytes,(CC_LONG)der.length,sha1);
    if(![hexString([NSData dataWithBytes:sha256 length:sizeof(sha256)]) isEqual:expectedSHA256] ||
       ![hexString([NSData dataWithBytes:sha1 length:sizeof(sha1)]).uppercaseString isEqual:key])fail(@"korean_support_failed");
    NSMutableData *blob=[NSMutableData data];
    uint32_t hash[3]={3,1,sizeof(sha1)},certificate[3]={32,1,(uint32_t)der.length};
    [blob appendBytes:hash length:sizeof(hash)];[blob appendBytes:sha1 length:sizeof(sha1)];
    [blob appendBytes:certificate length:sizeof(certificate)];[blob appendData:der];
    return blob;
}
// Check the serialized certificate and its hash, not just the registry key's name. Wine
// may add other certificate properties, so accept them and any property order, but reject
// truncated records, an incorrect hash, or a different certificate under this key.
static BOOL koreanCertificateInstalled(NSDictionary *values, NSData *expected) {
    NSData *blob=registryBinary(values[@"Blob"]);
    BOOL hash=NO,certificate=NO;NSUInteger offset=0;
    while(offset<blob.length) {
        uint32_t property[3];
        if(blob.length-offset<sizeof(property))return NO;
        [blob getBytes:property range:NSMakeRange(offset,sizeof(property))];offset+=sizeof(property);
        if(property[1]!=1 || property[2]>blob.length-offset)return NO;
        NSData *value=[blob subdataWithRange:NSMakeRange(offset,property[2])];
        if(property[0]==3) {
            if(hash || ![value isEqualToData:[expected subdataWithRange:NSMakeRange(12,20)]])return NO;
            hash=YES;
        }
        else if(property[0]==32) {
            if(certificate || ![value isEqualToData:[expected subdataWithRange:NSMakeRange(44,expected.length-44)]])return NO;
            certificate=YES;
        }
        offset+=property[2];
    }
    return hash && certificate;
}
/* Adds both certificates (ENABLED) or removes their two managed keys. Without ENGINE it
 * only reports what would change; with KEEP, installed certificates are never removed
 * (setup and launch only add, until the player turns the option off). Never fails:
 * callers decide. Reports korean_support. */
static BOOL configureKoreanCertificate(NSString *engine, BOOL enabled, BOOL keep) {
    NSArray *certificates=@[@[assuredRootKey,koreanCertificateBlob(assuredRoot,assuredRootSHA256,assuredRootKey)],
                            @[crossSignedG4Key,koreanCertificateBlob(crossSignedG4,crossSignedG4SHA256,crossSignedG4Key)]];
    BOOL ok=YES,changed=NO;
    NSMutableDictionary *details=[@{@"enabled":@(enabled),@"changed":@NO} mutableCopy];
    for(NSArray *certificate in certificates) {
        NSString *name=certificate[0];NSData *blob=certificate[1];
        NSDictionary *values=userRegistryValues([rootCertificatesKey stringByAppendingFormat:@"\\%@",name]);
        BOOL installed=values && koreanCertificateInstalled(values,blob),present=values.count>0;
        // Removing support also removes malformed values under either managed key.
        BOOL change=enabled ? !installed : (!keep && (present || !values));
        if(!values)details[@"registry"]=@"unreadable";
        if(engine && change) {
            NSString *key=[NSString stringWithFormat:@"HKCU\\%@\\%@",rootCertificatesKey,name];
            BOOL applied=enabled ? registryTool(engine,@[@"add",key,@"/v",@"Blob",@"/t",@"REG_BINARY",@"/d",hexString(blob),@"/f"],@"korean-support.log")
                                 : registryTool(engine,@[@"delete",key,@"/f"],@"korean-support.log");
            // Removing a key that was never there fails; nothing is installed then.
            if(!applied && !enabled && values && !present)applied=YES;
            changed|=applied;ok&=applied;
        }
        else if(!engine)changed|=change;
    }
    details[@"changed"]=@(changed);
    if(!ok)details[@"failed"]=@YES;
    event(@"korean_support",details);
    return ok;
}
// The Korean build installs Nexon's anti-cheat beside the game (grap64.dll and grap\).
static BOOL nexonBuild(void) {
    NSString *game=gameFolder();
    return [fm fileExistsAtPath:join(game,@"grap64.dll")] || [fm fileExistsAtPath:join(game,@"grap")];
}
