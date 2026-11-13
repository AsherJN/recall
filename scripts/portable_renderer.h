/* Custom renderer settings (1.6.4, REC-85; Settings › Advanced): the player's own dxmt.conf lines,
 * which the app passes to launch as --renderer-custom TEXT while the setting is on. They go at the
 * end of this launch's dxmt.conf, in Overwatch's section after Recall's own lines, and DXMT keeps
 * the last line it reads for a setting, so the player's win. Only "name = value" lines are kept.
 * The canvas size and MetalFX sharpening stay Recall's: the resolution and Sharpening settings own
 * them, and a canvas the game doesn't match turns full screen off. Section headers are left out
 * too, since one would move the lines after it out of Overwatch's section. Names DXMT doesn't read
 * are kept (it ignores them); the app flags them as the player types.
 * An Overwatch started from a Battle.net that is already open reads the file when it starts, so a
 * hand-over to that Battle.net rewrites the player's lines as well (rendererRefresh), and a change
 * applies the next time the player presses Play. */
static NSString *const rendererMarker=@"# Custom renderer settings (Settings › Advanced)";
static BOOL rendererRecalls(NSString *name) {
    return [@[@"dxgi.fullscreenCanvasWidth",@"dxgi.fullscreenCanvasHeight",@"d3d11.metalfxSharpness"] containsObject:name];
}
/* The chip's name as macOS gives it ("Apple M1 Pro", "Apple A18 Pro"); nil when it doesn't.
 * OW2_SETUP_TEST_CHIP (tests only) stands in for it. */
static NSString *chipName(void) {
    NSString *test=NSProcessInfo.processInfo.environment[@"OW2_SETUP_TEST_CHIP"];
    if(test)return test;
    char value[128]={0};size_t size=sizeof(value)-1;
    if(sysctlbyname("machdep.cpu.brand_string",value,&size,NULL,0))return nil;
    return [NSString stringWithUTF8String:value];
}
/* Display sync on a Mac with an iPhone chip (the MacBook Neo's A18 Pro; REC-93). DXMT asks macOS
 * to show frames with vsync off (dxgi.displaySyncEnabled is False unless set). On these Macs alone,
 * macOS then moves the screen's buffers into memory it reserves for vsync off, and WindowServer
 * (macOS 26.6.2) can crash choosing among them: it reads a buffer that has none behind it. The
 * player lands on the Mac's login screen and Overwatch runs on with no window. With display sync on
 * the game is shown in step with the screen and macOS never takes that path; other Macs keep vsync
 * off. The line goes in Recall's part, before the player's lines, so a player's own
 * dxgi.displaySyncEnabled still wins; it is added once, so a hand-over keeps a single line. */
static NSString *const displaySyncLine=@"dxgi.displaySyncEnabled = True";
static NSString *displaySyncProfile(NSString *profile) {
    NSString *chip=chipName();
    if(![chip hasPrefix:@"Apple A"])return profile;
    event(@"display_sync",@{@"enabled":@YES,@"chip":chip});
    if([[profile componentsSeparatedByString:@"\n"] containsObject:displaySyncLine])return profile;
    return [profile stringByAppendingFormat:@"%@[Overwatch.exe]\n%@\n",[profile hasSuffix:@"\n"]?@"":@"\n",displaySyncLine];
}
/* PROFILE without any earlier player's lines, then Recall's display sync where a Mac needs it, then
 * the player's lines in TEXT (nil when the setting is off). Reports renderer_custom: the lines
 * used, and how many were left out. */
static NSString *rendererProfile(NSString *profile, NSString *text) {
    NSRange earlier=[profile rangeOfString:[@"\n" stringByAppendingString:rendererMarker]];
    if(earlier.location!=NSNotFound)profile=[profile substringToIndex:earlier.location+1];
    profile=displaySyncProfile(profile);
    if(!text)return profile;
    NSMutableArray *lines=[NSMutableArray array];NSUInteger ignored=0;
    for(NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if(!line.length || [line hasPrefix:@"#"])continue;
        NSRange equals=[line rangeOfString:@"="];
        NSString *name=equals.location==NSNotFound ? @"" : [[line substringToIndex:equals.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *value=equals.location==NSNotFound ? @"" : [[line substringFromIndex:NSMaxRange(equals)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if(!matches(name,@"^[A-Za-z0-9._]+$") || rendererRecalls(name)) {ignored++;continue;}
        [lines addObject:[NSString stringWithFormat:@"%@ = %@",name,value]];
    }
    event(@"renderer_custom",@{@"lines":@(lines.count),@"ignored":@(ignored)});
    if(!lines.count)return profile;
    return [profile stringByAppendingFormat:@"%@%@\n[Overwatch.exe]\n%@\n",[profile hasSuffix:@"\n"]?@"":@"\n",rendererMarker,[lines componentsJoinedByString:@"\n"]];
}
/* A hand-over to an open Battle.net: the dxmt.conf its session reads, with the player's lines as
 * they are now. Nothing to do without one (a session started before Recall wrote its own). */
static void rendererRefresh(NSString *text) {
    NSString *path=join(root,@"dxmt.conf");
    NSString *profile=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if(!profile)return;
    NSString *next=rendererProfile(profile,text);
    if(![next isEqual:profile] && ![next writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil])fail(@"settings_write_failed");
}
