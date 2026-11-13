/* Settings Recall keeps in Wine's registry (HKCU, environment/user.reg), each written with
 * Wine's registry tool and read back from that file. The file is current once Wine's
 * server has exited; while it runs (Battle.net's update Agent can keep it alive), the
 * file may lag a little, and a value written again is harmless. */

// The values of one key in user.reg, each as written there ("hex:..." for binary data,
// continuation lines joined). Nil when the file can't be read; a missing key has none.
// Key names compare without regard to case, as Windows compares them.
static NSDictionary *userRegistryValues(NSString *key) {
    NSString *path=join(root,@"environment/user.reg");struct stat st;
    if(lstat(path.fileSystemRepresentation,&st) || !S_ISREG(st.st_mode) || st.st_size>(8<<20))return nil;
    NSString *text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if(!text)return nil;
    NSString *header=[[NSString stringWithFormat:@"[%@]",[key stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]] lowercaseString];
    NSMutableDictionary *values=[NSMutableDictionary dictionary];
    BOOL inside=NO;NSString *name=nil;NSMutableString *continued=nil;
    for(NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *line=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if(continued) {
            BOOL more=[line hasSuffix:@"\\"];
            [continued appendString:more ? [line substringToIndex:line.length-1] : line];
            if(!more) {values[name]=continued;continued=nil;}
            continue;
        }
        if([line hasPrefix:@"["]) {
            NSString *lower=line.lowercaseString;
            inside=[lower hasPrefix:header] && (lower.length==header.length || [lower characterAtIndex:header.length]==' ');
            continue;
        }
        if(!inside || line.length<4 || ![line hasPrefix:@"\""])continue;
        NSRange end=[line rangeOfString:@"\"=" options:0 range:NSMakeRange(1,line.length-1)];
        if(end.location==NSNotFound)continue;
        name=[line substringWithRange:NSMakeRange(1,end.location-1)];
        NSString *data=[line substringFromIndex:end.location+2];
        if([data hasSuffix:@"\\"])continued=[[data substringToIndex:data.length-1] mutableCopy];
        else values[name]=data;
    }
    return values;
}
// REG_BINARY data as user.reg writes it ("hex:46,00,..."); nil for anything else.
static NSData *registryBinary(NSString *value) {
    if(![value hasPrefix:@"hex:"])return nil;
    NSMutableData *data=[NSMutableData data];
    for(NSString *byte in [[value substringFromIndex:4] componentsSeparatedByString:@","]) {
        if(!byte.length)continue;
        if(!matches(byte,@"^[0-9a-fA-F]{2}$"))return nil;
        uint8_t b=(uint8_t)strtoul(byte.UTF8String,NULL,16);[data appendBytes:&b length:1];
    }
    return data;
}
static NSString *hexString(NSData *data) {
    NSMutableString *hex=[NSMutableString stringWithCapacity:data.length*2];
    for(NSUInteger i=0;i<data.length;i++)[hex appendFormat:@"%02x",(unsigned)((const uint8_t *)data.bytes)[i]];
    return hex;
}
// Wine's registry tool; YES when it succeeded.
static BOOL registryTool(NSString *engine, NSArray *arguments, NSString *log) {
    return !waitTask(task(join(engine,@"bin/wine"),[@[@"reg.exe"] arrayByAddingObjectsFromArray:arguments],wineEnv(engine),log),60);
}
// After the registry tool: YES once Wine's server has exited and saved user.reg. Battle.net's
// update Agent may keep it running; the change is live in it anyway.
static BOOL registrySaved(NSString *engine, double seconds) {
    return !waitTask(task(join(engine,@"bin/wineserver"),@[@"-w"],wineEnv(engine),@"registry-wait.log"),seconds);
}

/* Automatic proxy detection (issue #15). Windows looks for a network proxy on its own
 * unless told not to: Wine's WinHTTP asks DNS for "wpad.<domain>" (on a Mac, wpad.local).
 * Some internet providers answer every unknown name with an address that never responds,
 * so each check waited out WinHTTP's 60-second connect timeout, while Battle.net's update
 * Agent gives up after about 20 seconds and is restarted: the installer stalled at 45% for
 * good. Recall's environment connects directly instead: HKCU's DefaultConnectionSettings
 * with only PROXY_TYPE_DIRECT, which WinHttpGetIEProxyConfigForCurrentUser (dlls/winhttp/
 * session.c) reads as no auto-detection; wininet reads the same value. Settings › Advanced
 * turns detection back on for networks that hand out their proxy that way, by removing the
 * value (Wine's default, as before 1.3). The choice is state.json's proxy_auto_detect;
 * absent, detection is off. */
static NSString *const internetConnectionsKey=@"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings\\Connections";
// Version 0x46, change counter 1, flags PROXY_TYPE_DIRECT, no proxy, bypass list or
// configuration script, three reserved DWORDs.
static NSData *directConnectionSettings(void) {
    static const uint32_t words[9]={0x46,1,1,0,0,0,0,0,0};
    return [NSData dataWithBytes:words length:sizeof(words)];
}
static BOOL proxyDetectionChosen(void) { return [state()[@"proxy_auto_detect"] isEqual:@YES]; }
// Whether the registry already has DETECT: no value (Wine's default) or one with the
// auto-detect flag for on; a direct connection without it for off.
static BOOL proxyMatches(NSDictionary *values, BOOL detect) {
    NSString *value=values[@"DefaultConnectionSettings"];
    NSData *data=registryBinary(value);
    uint32_t words[3]={0};
    if(data.length>=sizeof(words))[data getBytes:words length:sizeof(words)];
    BOOL settings=data.length>=sizeof(words) && words[0]==0x46;
    if(detect)return !value || (settings && (words[2] & 0x8));
    return settings && words[2]==0x1;
}
/* Sets automatic proxy detection to DETECT. Without ENGINE it only reports what would
 * change. The registry tool runs only when the value differs. Never fails: callers decide
 * (Settings fails on NO, setup and launch go on). Reports network_proxy. */
static BOOL configureProxy(NSString *engine, BOOL detect) {
    NSDictionary *values=userRegistryValues(internetConnectionsKey);
    BOOL matches=values && proxyMatches(values,detect),ok=YES;
    NSMutableDictionary *details=[@{@"detect":@(detect),@"changed":@NO} mutableCopy];
    if(!values)details[@"registry"]=@"unreadable";
    if(engine && !matches) {
        NSString *key=[@"HKCU\\" stringByAppendingString:internetConnectionsKey];
        ok=detect ? registryTool(engine,@[@"delete",key,@"/v",@"DefaultConnectionSettings",@"/f"],@"network-proxy.log")
                  : registryTool(engine,@[@"add",key,@"/v",@"DefaultConnectionSettings",@"/t",@"REG_BINARY",@"/d",hexString(directConnectionSettings()),@"/f"],@"network-proxy.log");
        // Removing a value that was never there fails; Wine's default is then in place.
        if(!ok && detect && values && !values[@"DefaultConnectionSettings"])ok=YES;
        details[@"changed"]=@(ok);
        if(!ok)details[@"failed"]=@YES;
    }
    else if(!engine)details[@"changed"]=@(!matches);
    event(@"network_proxy",details);
    return ok;
}

/* The left Option key in Overwatch (REC-20). Mac keyboards label Option "alt", but Wine's Mac
 * driver sends Windows nothing for either Option key and makes Command the Alt key
 * (winemac.drv keyboard.c), so Overwatch's Alt actions, choosing a perk among them, answered
 * only to Command. LeftOptionIsAlt, read for Overwatch.exe alone (the driver's AppDefaults),
 * makes the left Option key Alt as well. Command stays Alt; the right Option key still types
 * accented letters and symbols in the game, and Battle.net keeps both for email and password
 * (an "@" is Option+L on some keyboards). Wine reads it when Overwatch starts. */
static NSString *const gameKeyboardKey=@"Software\\Wine\\AppDefaults\\Overwatch.exe\\Mac Driver";
/* Without ENGINE it only reports whether the value is missing. The registry tool runs only
 * then. Never fails: setup and launches go on, and the next launch tries again. Reports
 * keyboard. */
static BOOL configureOptionKey(NSString *engine) {
    NSDictionary *values=userRegistryValues(gameKeyboardKey);
    BOOL set=[values[@"LeftOptionIsAlt"] isEqual:@"\"Y\""],ok=YES;
    NSMutableDictionary *details=[@{@"left_option_is_alt":@YES,@"changed":@NO} mutableCopy];
    if(!values)details[@"registry"]=@"unreadable";
    if(engine && !set) {
        ok=registryTool(engine,@[@"add",[@"HKCU\\" stringByAppendingString:gameKeyboardKey],@"/v",@"LeftOptionIsAlt",@"/t",@"REG_SZ",@"/d",@"Y",@"/f"],@"keyboard.log");
        details[@"changed"]=@(ok);
        if(!ok)details[@"failed"]=@YES;
    }
    else if(!engine)details[@"changed"]=@(!set);
    event(@"keyboard",details);
    return ok;
}

/* Room in memory for Battle.net (REC-75; GitHub #48, #51). Battle.net.exe is a 32-bit Windows
 * program built without the large-address-aware flag, so each of its processes (the client and
 * every process of its built-in browser, which all run Battle.net.exe) can address only 2 GB.
 * Recall has that browser draw on the CPU (launchClient), so a page also keeps what it has drawn
 * there. On some Macs (both reports: MacBooks on macOS 27, at the built-in display's "More Space")
 * a page used up its 2 GB seconds after it opened: the browser aborted it (0xE0000008, Chromium's
 * out-of-memory code), opened another, and after a few tries Battle.net closed, on every launch.
 * CrossOver's Wine gives a program named in AppDefaults with a non-zero LargeAddressAware DWORD
 * the 4 GB 64-bit Windows gives a large-address-aware one (dlls/ntdll/unix/virtual.c, force_laa;
 * the preloader keeps the low 8 GB for Windows memory). Only Battle.net.exe is named: Overwatch
 * is 64-bit, and the installer and update Agent keep Windows' default. Each process reads it as
 * it starts, so a Battle.net already open keeps its 2 GB until it closes. */
static NSString *const battleNetMemoryKey=@"Software\\Wine\\AppDefaults\\Battle.net.exe";
/* Without ENGINE it only reports whether the value is missing. The registry tool runs only
 * then. Never fails: setup and launches go on, and the next launch tries again. Reports
 * battlenet_memory. */
static BOOL configureBattleNetMemory(NSString *engine) {
    NSDictionary *values=userRegistryValues(battleNetMemoryKey);
    BOOL set=[values[@"LargeAddressAware"] isEqual:@"dword:00000001"],ok=YES;
    NSMutableDictionary *details=[@{@"large_address_aware":@YES,@"changed":@NO} mutableCopy];
    if(!values)details[@"registry"]=@"unreadable";
    if(engine && !set) {
        ok=registryTool(engine,@[@"add",[@"HKCU\\" stringByAppendingString:battleNetMemoryKey],@"/v",@"LargeAddressAware",@"/t",@"REG_DWORD",@"/d",@"1",@"/f"],@"battlenet-memory.log");
        details[@"changed"]=@(ok);
        if(!ok)details[@"failed"]=@YES;
    }
    else if(!engine)details[@"changed"]=@((BOOL)!set);
    event(@"battlenet_memory",details);
    return ok;
}

/* Links opened from Battle.net or Overwatch (REC-84; GitHub #69). Windows programs open a web or
 * email link through Wine's winebrowser.exe, which runs the Mac command named in WineBrowser's
 * Browsers (Mailers for email) with the link added (programs/winebrowser/main.c; each entry is
 * split into arguments as a Windows command line is). Without them Wine runs /usr/bin/open, and
 * a Mac program Wine starts inherits Recall's environment: HOME and TMPDIR inside the data folder,
 * USER "player", and Wine's, DXMT's and the Metal HUD's settings. LaunchServices hands a browser
 * that wasn't running the environment of the program that opened it, so Chrome started with
 * Recall's HOME, found no keychain, and deleted every sign-in it could no longer decrypt.
 * Started with an empty environment, open leaves LaunchServices to give the browser the
 * player's own session, as a link clicked anywhere else on the Mac does. A browser already
 * running only receives the link. */
static NSString *const browserLinksKey=@"Software\\Wine\\WineBrowser";
static NSString *const browserLinksCommand=@"/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/open";
/* Without ENGINE it only reports whether either value differs. The registry tool runs only for a
 * value that does. Never fails: setup and launches go on, and the next launch tries again.
 * Reports browser_links. */
static BOOL configureBrowserLinks(NSString *engine) {
    NSDictionary *values=userRegistryValues(browserLinksKey);
    NSString *expected=[NSString stringWithFormat:@"\"%@\"",browserLinksCommand];
    NSMutableArray *missing=[NSMutableArray array];
    for(NSString *name in @[@"Browsers",@"Mailers"])if(![values[name] isEqual:expected])[missing addObject:name];
    BOOL ok=YES,changed=NO;
    NSMutableDictionary *details=[@{@"clean_environment":@YES,@"changed":@NO} mutableCopy];
    if(!values)details[@"registry"]=@"unreadable";
    if(engine) {
        for(NSString *name in missing) {
            if(registryTool(engine,@[@"add",[@"HKCU\\" stringByAppendingString:browserLinksKey],@"/v",name,@"/t",@"REG_SZ",@"/d",browserLinksCommand,@"/f"],@"browser-links.log"))changed=YES;
            else ok=NO;
        }
        details[@"changed"]=@(changed);
        if(!ok)details[@"failed"]=@YES;
    }
    else details[@"changed"]=@((BOOL)(missing.count>0));
    event(@"browser_links",details);
    return ok;
}
