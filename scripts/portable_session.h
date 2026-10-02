/* Exact engine/prefix process membership. No command lines or environments.
 * The accepted Python closer's identity checks, ported to native Foundation. */
static NSString *capture(NSString *exe, NSArray *args) {
    NSTask *p=task(exe,args,@{@"PATH":@"/usr/bin:/bin:/usr/sbin:/sbin",@"LC_ALL":@"C"},[NSString stringWithFormat:@"session-query-%d.log",getpid()]);
    if(waitTask(p,5))return nil;
    NSString *path=join(join(root,@"logs"),[NSString stringWithFormat:@"session-query-%d.log",getpid()]);
    if([[fm attributesOfItemAtPath:path error:nil][NSFileSize] unsignedLongLongValue]>(4ULL<<20))return nil;
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
}
static NSMutableDictionary *membershipCache;
static NSArray *sessionProcesses(void) {
    if(!membershipCache)membershipCache=[NSMutableDictionary dictionary];
    if(membershipCache.count>256)[membershipCache removeAllObjects];
    NSString *engine=[runtime() stringByAppendingString:@"/"],*prefix=[join(root,@"environment") stringByAppendingString:@"/"];
    NSString *table=capture(@"/bin/ps",@[@"-axo",@"pid=,lstart=,comm="]);
    if(!table)fail(@"session_check_failed");
    NSRegularExpression *rx=[NSRegularExpression regularExpressionWithPattern:@"^\\s*(\\d+)\\s+(\\S+\\s+\\S+\\s+\\d+\\s+\\S+\\s+\\d+)\\s+(.+)$" options:0 error:nil];
    NSMutableArray *found=[NSMutableArray array];
    for(NSString *line in [table componentsSeparatedByString:@"\n"]) {
        NSTextCheckingResult *m=[rx firstMatchInString:line options:0 range:NSMakeRange(0,line.length)];if(!m)continue;
        NSString *name=[line substringWithRange:[m rangeAtIndex:3]];
        BOOL game=[name hasSuffix:@"Overwatch.exe"],client=[name hasSuffix:@"\\Battle.net.exe"];
        if(!game && !client)continue;
        NSString *pid=[line substringWithRange:[m rangeAtIndex:1]],*start=[line substringWithRange:[m rangeAtIndex:2]];
        NSString *identity=[NSString stringWithFormat:@"%@|%@",pid,start];
        if(membershipCache[identity]) { if([membershipCache[identity] boolValue])[found addObject:@{@"pid":@(pid.intValue),@"identity":start,@"kind":game?@"game":@"client"}];continue; }
        NSString *mapped=capture(@"/usr/sbin/lsof",@[@"-a",@"-p",pid,@"-d",@"txt",@"-Fn"]);
        if(!mapped) { if(kill(pid.intValue,0)==0)fail(@"session_membership_unknown");continue; }
        BOOL hasEngine=NO,hasPrefix=NO;
        for(NSString *file in [mapped componentsSeparatedByString:@"\n"]) {
            if(![file hasPrefix:@"n"])continue;
            // lsof escapes literal backslashes even in field output. Decode
            // them before resolving /var versus /private/var aliases.
            NSString *decoded=[[file substringFromIndex:1] stringByReplacingOccurrencesOfString:@"\\\\" withString:@"\\"];
            NSString *mappedPath=[decoded stringByResolvingSymlinksInPath];
            hasEngine|=[mappedPath hasPrefix:engine];
            hasPrefix|=[mappedPath hasPrefix:prefix];
        }
        membershipCache[identity]=@(hasEngine && hasPrefix);
        if(hasEngine && hasPrefix)[found addObject:@{@"pid":@([pid intValue]),@"identity":start,@"kind":game?@"game":@"client"}];
    }
    // Raw process inventory never becomes a retained support record.
    [fm removeItemAtPath:join(join(root,@"logs"),[NSString stringWithFormat:@"session-query-%d.log",getpid()]) error:nil];
    return found;
}
static BOOL focusSession(NSArray *processes) {
    for(NSString *kind in @[@"game",@"client"])for(NSDictionary *p in processes)if([p[@"kind"] isEqual:kind]) {
        NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:[p[@"pid"] intValue]];
        BOOL activated=app && [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
        event(@"session_existing",@{@"kind":kind,@"activated":@(activated)});return YES;
    }
    return NO;
}
static void watchClient(void) {
    // The monitor has its own lock. It never holds setup.lock during a match.
    int fd=open(join(root,@"launch-monitor.lock").fileSystemRepresentation,O_CREAT|O_RDWR|O_NOFOLLOW,0600);
    if(fd<0)fail(@"monitor_lock_failed");if(flock(fd,LOCK_EX|LOCK_NB)){close(fd);return;}
    flock(lockFD,LOCK_UN);close(lockFD);lockFD=-1;
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:1800],*seen=nil,*clientSeen=[NSDate date];
    while(deadline.timeIntervalSinceNow>0 && !cancelRequested) {
        NSArray *rows=sessionProcesses();NSMutableArray *clients=[NSMutableArray array];BOOL game=NO;
        for(NSDictionary *p in rows) {if([p[@"kind"] isEqual:@"game"])game=YES;else[clients addObject:p];}
        if(clients.count)clientSeen=[NSDate date];
        if(!game)seen=nil;else if(!seen)seen=[NSDate date];
        if(!game && -clientSeen.timeIntervalSinceNow>120)break;
        if(seen && -seen.timeIntervalSinceNow>=25) {
            [membershipCache removeAllObjects];
            NSArray *fresh=sessionProcesses();BOOL stillGame=NO;
            for(NSDictionary *p in fresh)stillGame|=[p[@"kind"] isEqual:@"game"];
            if(stillGame)for(NSDictionary *p in fresh)if([p[@"kind"] isEqual:@"client"] && [clients containsObject:p])kill([p[@"pid"] intValue],SIGTERM);
            event(@"client_monitor_finished",@{@"game_running":@(stillGame)});break;
        }
        [NSThread sleepForTimeInterval:2];
    }
    close(fd);
}
/* The displays as Wine takes them in when its session starts: each online display, which
 * one is main, where it sits, its size in points and pixels, and what it mirrors. Wine
 * keeps that layout for the whole session, and Battle.net's update Agent can keep a
 * session alive long after the client closes. After the owner unplugged an external main
 * display (QA, 2026-10-01), Overwatch started in such a session found "No usable outputs"
 * and said "No compatible graphics hardware was found". nil if the displays can't be read. */
static NSString *displaySignature(void) {
    CGDirectDisplayID ids[16];uint32_t count=0;
    if(CGGetOnlineDisplayList(16,ids,&count)!=kCGErrorSuccess || !count)return nil;
    NSMutableArray *parts=[NSMutableArray array];
    for(uint32_t i=0;i<count;i++) {
        CGRect bounds=CGDisplayBounds(ids[i]);size_t pixelWidth=0,pixelHeight=0;
        CGDisplayModeRef mode=CGDisplayCopyDisplayMode(ids[i]);
        if(mode){pixelWidth=CGDisplayModeGetPixelWidth(mode);pixelHeight=CGDisplayModeGetPixelHeight(mode);CGDisplayModeRelease(mode);}
        [parts addObject:[NSString stringWithFormat:@"%u%@ %.0f,%.0f %.0fx%.0f %zux%zu m%u",ids[i],CGDisplayIsMain(ids[i])?@" main":@"",
            bounds.origin.x,bounds.origin.y,bounds.size.width,bounds.size.height,pixelWidth,pixelHeight,CGDisplayMirrorsDisplay(ids[i])]];
    }
    [parts sortUsingSelector:@selector(compare:)];
    return [parts componentsJoinedByString:@"; "];
}
