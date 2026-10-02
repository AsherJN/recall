/* Opt-in evidence from the same launch path. Never record account arguments,
 * the inherited environment or personal preference sections. */
static NSDictionary *parityReport(NSString *engine, NSDictionary *env) {
    NSMutableDictionary *files=[NSMutableDictionary dictionary];
    for(NSString *name in @[@"bin/wine",@"bin/wineserver",@"lib/wine/x86_64-windows/d3d11.dll",@"lib/wine/x86_64-windows/dxgi.dll",@"lib/wine/x86_64-windows/winemetal.dll",@"lib/wine/x86_64-unix/winemetal.so",@"lib/wine/x86_64-unix/winemac.so",@"lib/wine/x86_64-unix/ntdll.so",@"lib/wine/x86_64-unix/win32u.so"])
        files[name]=hashFile(join(engine,name));
    NSMutableDictionary *preferences=[NSMutableDictionary dictionary];
    NSString *path=settingsPath();
    NSString *text=path?[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]:nil;
    BOOL render=NO;
    NSMutableSet *keys=[NSMutableSet setWithArray:candidateLaunchPreferences().allKeys];
    [keys addObjectsFromArray:candidateBaselinePreferences().allKeys];
    for(NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if([line hasPrefix:@"["]) {render=[line isEqual:@"[Render.13]"];continue;}
        NSRange equals=[line rangeOfString:@"="];
        if(!render || equals.location==NSNotFound)continue;
        NSString *key=[[line substringToIndex:equals.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if([keys containsObject:key])preferences[key]=[[line substringFromIndex:equals.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t\""]];
    }
    return @{@"schema":@1,@"candidate_profile":CANDIDATE_PROFILE,@"contract_sha256":CANDIDATE_CONTRACT_SHA256,
        @"runtime":state()[@"active_runtime"],@"runtime_files":files,@"launch_environment":env,
        @"retina_enabled":@(retinaConfigured()),@"render_preferences":preferences,@"free_bytes":@(freeBytes()),
        @"worker_sha256":hashFile(NSProcessInfo.processInfo.arguments[0]),
        @"config_sha256":hashFile([fm fileExistsAtPath:join(root,@"dxmt.conf")]?join(root,@"dxmt.conf"):join(engine,@"config/dxmt.conf"))};
}
static NSMutableDictionary *diagnosticEnvironment(NSString *engine) {
    NSString *folder=join(root,join(@"logs",[@"parity-" stringByAppendingString:NSUUID.UUID.UUIDString]));
    mkdirs(folder);
    NSMutableDictionary *env=wineEnv(engine);
    for(NSString *kind in @[@"FRAME",@"GEOMETRY",@"WINDOW",@"DISPLAY",@"CANVAS"]) {
        NSString *path=join(folder,kind.lowercaseString);
        if([@[@"FRAME",@"GEOMETRY",@"WINDOW"] containsObject:kind])path=[@"Z:" stringByAppendingString:[path stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]];
        env[[NSString stringWithFormat:@"DXMT_%@_LOG",kind]]=path;
    }
    writeJSON(parityReport(engine,env),join(folder,@"launch.json"));
    event(@"diagnostics_started",@{@"folder":folder});
    return env;
}
