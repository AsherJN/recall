/* Wine's Retina mode (RetinaMode) is one switch for every display, read when a Wine session
 * starts: on, a Windows pixel is half a point on every display. That suits a Retina main
 * display, where Overwatch opens: a window or a borderless game is drawn at the screen's own
 * pixels, and the fullscreen canvas (cocoa_v1.m) relies on neither. On a main display macOS
 * draws at one pixel a point (most external monitors) it made Wine see the screen at twice
 * its size: a borderless game drew 5120x2880 on a 2560x1440 monitor (38 FPS against 80 in
 * the Practice Range, REC-45) and a window came out half the size the game asked for. So
 * each session starts with the setting that suits its main display; displays changing end
 * the session (displaySignature), and the next starts with the new one's.
 * OW2_SETUP_TEST_DISPLAY_SCALE (1 or 2, tests only) stands in for the main display. */
static NSInteger mainDisplayScale(void) {
    NSString *test=NSProcessInfo.processInfo.environment[@"OW2_SETUP_TEST_DISPLAY_SCALE"];
    if([test isEqual:@"1"] || [test isEqual:@"2"])return test.integerValue;
    CGDisplayModeRef mode=CGDisplayCopyDisplayMode(CGMainDisplayID());
    if(!mode)return 2;
    NSInteger scale=CGDisplayModeGetPixelWidth(mode)>CGDisplayModeGetWidth(mode) ? 2 : 1;
    CGDisplayModeRelease(mode);
    return scale;
}
static NSString *retinaRegistry(void) {
    NSString *path=join(root,@"environment/user.reg");struct stat st;
    if(lstat(path.fileSystemRepresentation,&st) || !S_ISREG(st.st_mode) || st.st_size>(8<<20))
        fail(@"retina_configuration_failed");
    NSString *text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if(!text)fail(@"retina_configuration_failed");return text;
}
/* The prefix's RetinaMode: "Y", "N" or nil when it has none. */
static NSString *retinaSetting(void) {
    BOOL section=NO;
    for(NSString *raw in [retinaRegistry() componentsSeparatedByString:@"\n"]) {
        NSString *line=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if([line hasPrefix:@"["])
            section=[line hasPrefix:@"[Software\\\\Wine\\\\Mac Driver]"];
        else if(section && [line isEqual:@"\"RetinaMode\"=\"Y\""])return @"Y";
        else if(section && [line isEqual:@"\"RetinaMode\"=\"N\""])return @"N";
    }
    return nil;
}
static BOOL retinaConfigured(void) {return [retinaSetting() isEqual:@"Y"];}
/* Windows pixels a point in this session's Wine coordinates: 2 in Retina mode, and before
 * the environment exists (setup sets Retina mode when it creates it). */
static NSInteger wineScale(void) {
    NSString *path=join(root,@"environment/user.reg");struct stat st;
    if(lstat(path.fileSystemRepresentation,&st) || !S_ISREG(st.st_mode))return 2;
    return [retinaSetting() isEqual:@"N"] ? 1 : 2;
}
static NSString *retinaWanted(void) {return mainDisplayScale()>1 ? @"Y" : @"N";}
/* A session left running (Battle.net's update Agent) keeps the setting it started with. */
static BOOL retinaChangeNeeded(void) {return ![retinaSetting() isEqual:retinaWanted()];}
static void configureRetina(void) {
    NSString *wanted=retinaWanted();
    if([retinaSetting() isEqual:wanted])return;
    NSString *engine=runtime();
    // Wine caches desktop geometry in the running session. Never change the
    // registry underneath a client/game, or kill one to perform this migration.
    if(sessionProcesses().count || busy(engine))fail(@"close_game_before_setup");
    mkdirs(join(root,@"settings-backup"));
    NSString *backup=join(root,@"settings-backup/before-retina-user.reg");
    if(![fm fileExistsAtPath:backup] &&
       ![fm copyItemAtPath:join(root,@"environment/user.reg") toPath:backup error:nil])
        fail(@"settings_backup_failed");
    ownedPreparation=YES;
    if(waitTask(task(join(engine,@"bin/wine"),
        @[@"reg.exe",@"add",@"HKCU\\Software\\Wine\\Mac Driver",@"/v",@"RetinaMode",@"/t",@"REG_SZ",@"/d",wanted,@"/f"],
        wineEnv(engine),@"retina-configuration.log"),60))fail(@"retina_configuration_failed");
    // The registry tool itself starts Wine with the old geometry. Wait for its
    // server to exit and flush the registry before starting Battle.net afresh.
    if(waitTask(task(join(engine,@"bin/wineserver"),@[@"-w"],wineEnv(engine),@"retina-wait.log"),60))
        fail(@"environment_initialization_busy");
    ownedPreparation=NO;
    if(![retinaSetting() isEqual:wanted])fail(@"retina_configuration_failed");
    event(@"retina_configured",@{@"retina":@([wanted isEqual:@"Y"])});
}
