/* Which Battle.net Recall installs (issue #23): Global or China's (国服, run by NetEase), chosen
 * at setup with the language Battle.net installs in. Accounts don't carry over between the two.
 * state.json keeps the choice (battlenet_region, battlenet_language); an installation from
 * before 1.4 is Global, installed in English. China's Battle.net is Simplified Chinese only.
 * Once Battle.net is installed the choice stays: the app's Change region moves the whole
 * installation to the Trash first (uninstall), then setup starts over. */
static NSArray *battleNetRegions(void) { return @[@"global",@"cn"]; }
static NSArray *battleNetLanguages(void) { return @[@"enUS",@"zhCN",@"koKR"]; }
static NSString *battleNetRegion(void) { return [state()[@"battlenet_region"] isEqual:@"cn"] ? @"cn" : @"global"; }
static NSString *battleNetLanguage(void) {
    if([battleNetRegion() isEqual:@"cn"])return @"zhCN";
    NSString *language=state()[@"battlenet_language"];
    return [battleNetLanguages() containsObject:language] ? language : @"enUS";
}

/* Where Battle.net and Overwatch are, inside the Wine environment's drive C: their usual
 * folders, else the first folder directly under Program Files (x86) or Program Files that
 * holds them (China's installer is the same program as the global one, but its game folder
 * hasn't been seen on a Mac). An absent program reports its usual path. */
static NSString *installedProgram(NSString *usual, NSString *inFolder) {
    NSString *drive=join(root,@"environment/drive_c"),*path=join(drive,usual);
    if([fm fileExistsAtPath:path])return path;
    for(NSString *top in @[@"Program Files (x86)",@"Program Files"]) {
        NSString *folder=join(drive,top);
        for(NSString *name in [[fm contentsOfDirectoryAtPath:folder error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *candidate=join(join(folder,name),inFolder);
            if([fm fileExistsAtPath:candidate])return candidate;
        }
    }
    return path;
}
// The launcher stub can relaunch the client without forwarding Chromium flags.
// Invoke the same executable as the accepted v6 launcher.
static NSString *clientPath(void) { return installedProgram(@"Program Files (x86)/Battle.net/Battle.net.exe",@"Battle.net.exe"); }
// The game's _retail_ folder.
static NSString *gameFolder(void) {
    return [installedProgram(@"Program Files (x86)/Overwatch/_retail_/Overwatch.exe",@"_retail_/Overwatch.exe") stringByDeletingLastPathComponent];
}
// China's build installs NetEase's anti-cheat beside the game (NeacSafe64.sys, NeacLoader.exe,
// OWNeacClient.exe), in the game folder or one below it. Support reports name it.
static BOOL neacBuild(void) {
    NSString *game=gameFolder();
    for(NSString *name in [fm contentsOfDirectoryAtPath:game error:nil]) {
        NSString *lower=name.lowercaseString;BOOL directory=NO;
        if([lower hasPrefix:@"neac"] || [lower hasPrefix:@"owneac"])return YES;
        if(![fm fileExistsAtPath:join(game,name) isDirectory:&directory] || !directory)continue;
        for(NSString *inner in [fm contentsOfDirectoryAtPath:join(game,name) error:nil])
            if([inner.lowercaseString hasPrefix:@"neac"])return YES;
    }
    return NO;
}
/* Setup's Choose your Battle.net. Kept before Battle.net installs; after, only the same choice
 * is accepted (battlenet_already_installed otherwise). */
static void chooseBattleNet(NSString *region, NSString *language) {
    if(![battleNetRegions() containsObject:region] || ![battleNetLanguages() containsObject:language] ||
       ([region isEqual:@"cn"] && ![language isEqual:@"zhCN"]))fail(@"invalid_arguments");
    NSMutableDictionary *s=state();
    BOOL same=[s[@"battlenet_region"] isEqual:region] && [s[@"battlenet_language"] isEqual:language];
    if(!same && [fm fileExistsAtPath:clientPath()])fail(@"battlenet_already_installed");
    s[@"battlenet_region"]=region;s[@"battlenet_language"]=language;writeJSON(s,join(root,@"state.json"));
    event(@"battlenet_choice",@{@"region":region,@"language":language});
}

/* Chinese and Korean text. Windows programs ask for Windows' own fonts by name (Microsoft
 * YaHei, SimSun, Malgun Gothic), and Wine's DirectWrite falls back to "Noto Sans CJK SC/TC/JP/KR"
 * (dlls/dwrite/analyzer.c) for characters a font lacks. A Mac has none of these, and Wine's
 * links from Tahoma to Chinese and Korean fonts name Windows' font files, so Chinese and Korean
 * came out as empty boxes in GDI and DirectWrite alike (font probe, 1.3.1 engine, macOS 26.5,
 * October 12). Wine's font replacements (HKCU\Software\Wine\Fonts\Replacements), which both
 * read, give those names to fonts every Mac has, as Wine names them: "Hiragino Sans GB W3" and
 * Heiti for Chinese, Apple SD Gothic Neo for Korean. PingFang isn't among them: it lives in a
 * private system folder Wine doesn't load. With them, Tahoma's links resolve too. Each lists
 * several (REG_MULTI_SZ): Wine takes the first one present, and never replaces a font that
 * exists. Added with Chinese or Korean chosen for Battle.net, or China's Battle.net; never
 * removed. */
static NSString *const fontReplacementsKey=@"Software\\Wine\\Fonts\\Replacements";
static NSDictionary *fontReplacements(void) {
    NSArray *simplified=@[@"Hiragino Sans GB W3",@"Hiragino Sans GB",@"Heiti SC"];
    NSArray *traditional=@[@"Heiti TC",@"Songti TC",@"Hiragino Sans GB W3"];
    NSArray *korean=@[@"Apple SD Gothic Neo",@"AppleGothic"];
    NSMutableDictionary *fonts=[NSMutableDictionary dictionary];
    for(NSString *name in @[@"Microsoft YaHei",@"Microsoft YaHei UI",@"SimSun",@"NSimSun",@"SimHei",@"DengXian",@"Noto Sans CJK SC",@"Noto Sans CJK JP"])fonts[name]=simplified;
    for(NSString *name in @[@"Microsoft JhengHei",@"Microsoft JhengHei UI",@"PMingLiU",@"MingLiU",@"Noto Sans CJK TC"])fonts[name]=traditional;
    for(NSString *name in @[@"Malgun Gothic",@"Gulim",@"GulimChe",@"Dotum",@"DotumChe",@"Batang",@"Noto Sans CJK KR"])fonts[name]=korean;
    return fonts;
}
static BOOL cjkFontsChosen(void) { return [battleNetRegion() isEqual:@"cn"] || ![battleNetLanguage() isEqual:@"enUS"]; }
/* Adds the replacements user.reg doesn't have yet, with one import of Wine's registry tool.
 * Without ENGINE it only reports what would change. Never fails: callers decide (setup and
 * launches go on). Reports fonts. */
static BOOL configureFonts(NSString *engine, BOOL enabled) {
    NSDictionary *values=userRegistryValues(fontReplacementsKey),*fonts=fontReplacements();
    NSMutableArray *missing=[NSMutableArray array];
    if(enabled)for(NSString *name in fonts)if(![values[name] containsString:[fonts[name] firstObject]])[missing addObject:name];
    [missing sortUsingSelector:@selector(compare:)];
    BOOL ok=YES;
    NSMutableDictionary *details=[@{@"enabled":@(enabled),@"changed":@NO} mutableCopy];
    if(!values)details[@"registry"]=@"unreadable";
    if(engine && missing.count) {
        // REGEDIT4 with each list as REG_MULTI_SZ (hex(7)). Wine's importer reads that data as
        // the file's own single-byte text (UTF-16 only in a UTF-16 file), so: the names, each
        // ending in a zero, and one more zero at the end. The names are plain ASCII.
        NSMutableString *file=[NSMutableString stringWithFormat:@"REGEDIT4\r\n\r\n[HKEY_CURRENT_USER\\%@]\r\n",fontReplacementsKey];
        for(NSString *name in missing) {
            NSMutableData *list=[NSMutableData data];uint8_t zero=0;
            for(NSString *font in fonts[name]) {[list appendData:[font dataUsingEncoding:NSASCIIStringEncoding]];[list appendBytes:&zero length:1];}
            [list appendBytes:&zero length:1];
            NSMutableArray *bytes=[NSMutableArray array];
            for(NSUInteger i=0;i<list.length;i++)[bytes addObject:[NSString stringWithFormat:@"%02x",((const uint8_t *)list.bytes)[i]]];
            [file appendFormat:@"\"%@\"=hex(7):%@\r\n",name,[bytes componentsJoinedByString:@","]];
        }
        NSString *path=join(root,@"tmp/fonts.reg");
        ok=[file writeToFile:path atomically:YES encoding:NSASCIIStringEncoding error:nil] &&
           registryTool(engine,@[@"import",[@"Z:" stringByAppendingString:[path stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]]],@"fonts.log");
        [fm removeItemAtPath:path error:nil];
        details[@"changed"]=@(ok);details[@"added"]=@(missing.count);
        if(!ok)details[@"failed"]=@YES;
    }
    else if(!engine)details[@"changed"]=@((BOOL)(missing.count>0));
    event(@"fonts",details);
    return ok;
}
