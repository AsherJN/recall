/* The accepted canvas requires the prefix-wide Retina setting, not just the
 * native launcher's NSHighResolutionCapable flag. Migrate only while idle. */
static NSString *retinaRegistry(void) {
    NSString *path=join(root,@"environment/user.reg");struct stat st;
    if(lstat(path.fileSystemRepresentation,&st) || !S_ISREG(st.st_mode) || st.st_size>(8<<20))
        fail(@"retina_configuration_failed");
    NSString *text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if(!text)fail(@"retina_configuration_failed");return text;
}
static BOOL retinaConfigured(void) {
    BOOL section=NO;
    for(NSString *raw in [retinaRegistry() componentsSeparatedByString:@"\n"]) {
        NSString *line=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if([line hasPrefix:@"["])
            section=[line hasPrefix:@"[Software\\\\Wine\\\\Mac Driver]"];
        else if(section && [line isEqual:@"\"RetinaMode\"=\"Y\""])return YES;
    }
    return NO;
}
static void configureRetina(void) {
    if(retinaConfigured())return;
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
        @[@"reg.exe",@"add",@"HKCU\\Software\\Wine\\Mac Driver",@"/v",@"RetinaMode",@"/t",@"REG_SZ",@"/d",@"Y",@"/f"],
        wineEnv(engine),@"retina-configuration.log"),60))fail(@"retina_configuration_failed");
    // The registry tool itself starts Wine with the old geometry. Wait for its
    // server to exit and flush the registry before starting Battle.net afresh.
    if(waitTask(task(join(engine,@"bin/wineserver"),@[@"-w"],wineEnv(engine),@"retina-wait.log"),60))
        fail(@"environment_initialization_busy");
    ownedPreparation=NO;
    if(!retinaConfigured())fail(@"retina_configuration_failed");
    event(@"retina_configured",nil);
}
