/* Settings › Advanced › Logging (REC-40). Launches start Wine with its logging off (WINEDEBUG=-all)
 * and the graphics layer's at errors only, which keeps Overwatch fast. A player chasing a problem
 * picks a preset named for it, or Custom: Wine's own WINEDEBUG text, as they would type it in
 * Terminal, starting from Wine's defaults the same way (launch --logging <setting>
 * [--logging-custom <text>]). Every line then carries Wine's clock and process (+timestamp,+pid),
 * so the saved logs line up. Battle.net carries the setting from when it opens, as it does the HUD,
 * and Overwatch gets it from Battle.net.
 * Each Battle.net start has its own folder, logs/sessions/<UTC start>: session.json, what it
 * started with (account-free; the monitor adds when Overwatch ran and when the session ended), and
 * battlenet.log, what Battle.net, Wine and the game print (logs/battlenet.log before 1.5, replaced
 * at every start). Old folders go, oldest first, only while the logs would take more room than the
 * disk has left (pruneSessionLogs). The app's Save Logs reads them (LogBundle.swift). */
#include <mach/mach_time.h>
// Tests stand in the room the disk has left.
#ifndef LOG_ROOM
#define LOG_ROOM freeBytes()
#endif
static NSDictionary *loggingPresets(void) {
    // What each preset records (measured in play for REC-40); the app names them for the problem.
    return @{@"crashes":@{@"WINEDEBUG":@"-all,err+all,+seh,+loaddll,+timestamp,+pid"},
             @"graphics":@{@"WINEDEBUG":@"-all,err+all,+timestamp,+pid",@"DXMT_LOG_LEVEL":@"info"},
             @"battlenet":@{@"WINEDEBUG":@"-all,err+all,warn+winhttp,warn+wininet,warn+secur32,+loaddll,+timestamp,+pid"}};
}
/* Wine's own grammar (dlls/ntdll/unix/debug.c, parse_options): comma-separated
 * [process:][class]+channel or -channel, where a bare name turns a channel on. Classes are fixme,
 * err, warn and trace; channel names are lowercase, at most 15 characters. The app trims what the
 * player pastes (a WINEDEBUG= prefix, quotes, spaces) before it gets here. */
static BOOL validCustomLogging(NSString *text) {
    if(!text.length || text.length>1024)return NO;
    for(NSString *item in [text componentsSeparatedByString:@","])
        if(!matches(item,@"^([A-Za-z0-9 ._()-]{1,64}:)?((fixme|err|warn|trace)?[+-])?(all|[a-z0-9_]{1,15})$"))return NO;
    return YES;
}
static NSDictionary *loggingEnvironment(NSString *setting, NSString *custom) {
    if(!setting || [setting isEqual:@"off"])return @{};
    if([setting isEqual:@"custom"]) {
        if(!validCustomLogging(custom))fail(@"invalid_logging_settings");
        NSMutableArray *items=[[custom componentsSeparatedByString:@","] mutableCopy];
        for(NSString *flag in @[@"timestamp",@"pid"]) {
            BOOL named=NO;
            for(NSString *item in items)named|=matches(item,[NSString stringWithFormat:@"^([^:]*:)?(trace)?[+-]?%@$",flag]);
            if(!named)[items addObject:[@"+" stringByAppendingString:flag]];
        }
        return @{@"WINEDEBUG":[items componentsJoinedByString:@","]};
    }
    NSDictionary *preset=loggingPresets()[setting];
    if(!preset)fail(@"invalid_logging_settings");
    return preset;
}
static NSString *sessionsFolder(void) { return join(join(root,@"logs"),@"sessions"); }
static BOOL validSessionName(id name) { return [name isKindOfClass:NSString.class] && matches(name,@"^[0-9]{8}T[0-9]{6}Z(-[0-9]{1,2})?$"); }
static NSString *isoTime(NSDate *date) { return [[NSISO8601DateFormatter new] stringFromDate:date]; }
// Wine's clock (+timestamp): milliseconds since the Mac started, sleep included, as a 32-bit count
// (dlls/ntdll/unix/sync.c, monotonic_counter). With it the saved logs turn Wine's seconds into
// the time of day.
static uint32_t wineClock(void) {
    mach_timebase_info_data_t timebase;mach_timebase_info(&timebase);
    return (uint32_t)(mach_continuous_time()*timebase.numer/timebase.denom/1000000);
}
static NSArray *sessionLogNames(void) {
    NSMutableArray *names=[NSMutableArray array];
    for(NSString *name in [fm contentsOfDirectoryAtPath:sessionsFolder() error:nil])if(validSessionName(name))[names addObject:name];
    [names sortUsingSelector:@selector(compare:)];
    return names;
}
static unsigned long long folderBytes(NSString *path) {
    unsigned long long bytes=0;
    NSDirectoryEnumerator *files=[fm enumeratorAtPath:path];
    for(NSString *file in files) { (void)file;if([files.fileAttributes[NSFileType] isEqual:NSFileTypeRegular])bytes+=[files.fileAttributes[NSFileSize] unsignedLongLongValue]; }
    return bytes;
}
// The logs never take more room than the disk has left: oldest first, folders go until they fit.
static void pruneSessionLogs(void) {
    NSArray *names=sessionLogNames();NSMutableDictionary *sizes=[NSMutableDictionary dictionary];unsigned long long total=0;
    for(NSString *name in names) {sizes[name]=@(folderBytes(join(sessionsFolder(),name)));total+=[sizes[name] unsignedLongLongValue];}
    for(NSString *name in names) {
        if(total<=LOG_ROOM)break;
        if([fm removeItemAtPath:join(sessionsFolder(),name) error:nil]) {
            total-=[sizes[name] unsignedLongLongValue];
            event(@"session_log_removed",@{@"session":name});
        }
    }
}
// A Battle.net start's folder and record; the start's name is kept in state.json for its monitors.
static NSString *startSessionLog(NSDictionary *details) {
    pruneSessionLogs();
    NSDateFormatter *format=[NSDateFormatter new];format.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    format.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0];format.dateFormat=@"yyyyMMdd'T'HHmmss'Z'";
    NSDate *now=[NSDate date];NSString *stamp=[format stringFromDate:now],*name=stamp;
    for(int i=2;i<100 && [fm fileExistsAtPath:join(sessionsFolder(),name)];i++)name=[NSString stringWithFormat:@"%@-%d",stamp,i];
    mkdirs(join(sessionsFolder(),name));
    NSMutableDictionary *record=[details mutableCopy];
    [record addEntriesFromDictionary:@{@"schema":@1,@"started":isoTime(now),@"wine_clock_ms":@(wineClock())}];
    writeJSON(record,join(join(sessionsFolder(),name),@"session.json"));
    NSMutableDictionary *s=state();s[@"log_session"]=name;writeJSON(s,join(root,@"state.json"));
    return name;
}
// Monitors add to the record as the session goes. A record that can't be read or written is
// left alone: logs never stop a session.
static void recordSession(NSString *name, void (^change)(NSMutableDictionary *record)) {
    if(!validSessionName(name))return;
    NSString *path=join(join(sessionsFolder(),name),@"session.json");
    if(![fm fileExistsAtPath:path])return;
    @try { NSMutableDictionary *record=[readJSON(path) mutableCopy];change(record);writeJSON(record,path); }
    @catch(NSException *ignored) { (void)ignored; }
}
static void recordGameStarted(NSString *name) {
    recordSession(name,^(NSMutableDictionary *record) {
        NSMutableArray *games=[record[@"games"] isKindOfClass:NSArray.class] ? [record[@"games"] mutableCopy] : [NSMutableArray array];
        [games addObject:@{@"started":isoTime([NSDate date])}];record[@"games"]=games;
    });
}
static void recordGameEnded(NSString *name) {
    recordSession(name,^(NSMutableDictionary *record) {
        NSMutableArray *games=[record[@"games"] isKindOfClass:NSArray.class] ? [record[@"games"] mutableCopy] : nil;
        NSMutableDictionary *last=[games.lastObject isKindOfClass:NSDictionary.class] ? [games.lastObject mutableCopy] : nil;
        if(!last || last[@"ended"])return;
        last[@"ended"]=isoTime([NSDate date]);games[games.count-1]=last;record[@"games"]=games;
    });
}
// When the session ended: as Overwatch closed, or when Battle.net was last seen.
static void recordSessionEnded(NSString *name, NSDate *lastSeen) {
    recordSession(name,^(NSMutableDictionary *record) {
        if(record[@"ended"])return;
        NSDictionary *game=[record[@"games"] isKindOfClass:NSArray.class] ? [record[@"games"] lastObject] : nil;
        NSString *gameEnded=[game isKindOfClass:NSDictionary.class] ? game[@"ended"] : nil;
        NSString *seen=isoTime(lastSeen);
        record[@"ended"]=[gameEnded isKindOfClass:NSString.class] && [gameEnded compare:seen]==NSOrderedDescending ? gameEnded : seen;
    });
}
