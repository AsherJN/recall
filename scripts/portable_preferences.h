/* Candidate display invariants on every cold launch. Seed missing graphics
 * defaults once; explicit restore-candidate also restores the v6 graphics/FPS.
 * Never changes sensitivity, bindings or other sections. */
static NSString *settingsPath(void) {
    NSString *users=join(root,@"environment/drive_c/users");NSMutableArray *found=[NSMutableArray array];
    for(NSString *user in [fm contentsOfDirectoryAtPath:users error:nil]) {
        NSString *p=join(join(users,user),@"Documents/Overwatch/Settings/Settings_v0.ini");
        if([fm fileExistsAtPath:p]) {
            if(![[p stringByResolvingSymlinksInPath] hasPrefix:[root stringByAppendingString:@"/"]])fail(@"settings_outside_installation");
            [found addObject:p];
        }
    }
    if(found.count>1)fail(@"multiple_game_settings");return found.firstObject;
}
static BOOL supportedResolution(NSInteger width, NSInteger height) {
    for(NSArray *option in candidateResolutions())
        if([option[0] integerValue]==width && [option[1] integerValue]==height)return YES;
    return NO;
}
/* The resolution chosen in the app. Installations from before 1.0 stored only a height
 * (1080 or 1200), always 1920 pixels wide. */
static void chosenResolution(NSInteger *width, NSInteger *height) {
    NSDictionary *s=state();
    *width=[s[@"display_width"] integerValue]?:CANDIDATE_DEFAULT_WIDTH;
    *height=[s[@"display_height"] integerValue]?:CANDIDATE_DEFAULT_HEIGHT;
    if(!supportedResolution(*width,*height)) {*width=CANDIDATE_DEFAULT_WIDTH;*height=CANDIDATE_DEFAULT_HEIGHT;}
}
/* Saves the chosen resolution and writes the game's display settings. The game gets
 * gameWidth x gameHeight: the chosen size, or at launch the largest of the same shape
 * that fits the main display (fittedResolution). */
static void configurePreferences(NSInteger width, NSInteger height, NSInteger gameWidth, NSInteger gameHeight, BOOL restore) {
    if(!supportedResolution(width,height) || !supportedResolution(gameWidth,gameHeight))fail(@"unsupported_resolution");
    if(sessionProcesses().count)fail(@"close_game_before_maintenance");
    NSString *path=settingsPath();
    if(!path) {
        // A fresh prefix has one real user directory. Seed the accepted profile
        // before first game launch instead of inheriting hardware autodetection.
        NSString *users=join(root,@"environment/drive_c/users");NSMutableArray *profiles=[NSMutableArray array];
        for(NSString *name in [fm contentsOfDirectoryAtPath:users error:nil]) {
            if([@[@"public",@"default",@"default user",@"all users"] containsObject:name.lowercaseString])continue;
            NSString *directory=join(users,name);struct stat st;
            if(!lstat(directory.fileSystemRepresentation,&st) && S_ISDIR(st.st_mode))[profiles addObject:directory];
        }
        if(profiles.count==1) {
            path=join(profiles.firstObject,@"Documents/Overwatch/Settings/Settings_v0.ini");
            if(![[path stringByResolvingSymlinksInPath] hasPrefix:[root stringByAppendingString:@"/"]])fail(@"settings_outside_installation");
            mkdirs(path.stringByDeletingLastPathComponent);
            if(![@"[Render.13]\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil])fail(@"settings_write_failed");
        }
    }
    if(path) {
        if([[fm attributesOfItemAtPath:path error:nil][NSFileSize] unsignedLongLongValue]>(1ULL<<20))fail(@"invalid_game_settings");
        NSString *original=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if(!original)fail(@"invalid_game_settings");
        NSString *newline=[original containsString:@"\r\n"]?@"\r\n":@"\n";
        NSMutableArray *lines=[[original componentsSeparatedByString:newline] mutableCopy];
        NSInteger start=-1,end=lines.count;
        for(NSUInteger i=0;i<lines.count;i++) {
            NSString *line=[lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if([line isEqual:@"[Render.13]"]) {if(start>=0)fail(@"invalid_game_settings");start=i+1;}
            else if(start>=0 && end==(NSInteger)lines.count && [line hasPrefix:@"["])end=i;
        }
        if(start<0)fail(@"invalid_game_settings");
        NSMutableDictionary *values=[candidateLaunchPreferences() mutableCopy];
        NSString *gameW=[NSString stringWithFormat:@"%ld",(long)gameWidth],*gameH=[NSString stringWithFormat:@"%ld",(long)gameHeight];
        values[@"FullScreenWidth"]=gameW;values[@"WindowedWidth"]=gameW;
        values[@"FullScreenHeight"]=gameH;values[@"WindowedHeight"]=gameH;
        BOOL seed=restore || ![state()[@"candidate_baseline_profile"] isEqual:CANDIDATE_PROFILE];
        if(seed)for(NSString *key in candidateBaselinePreferences()) {
            BOOL present=NO;
            for(NSInteger i=start;i<end;i++) {
                NSString *left=[[lines[i] componentsSeparatedByString:@"="][0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if([left isEqual:key]) {if(present)fail(@"invalid_game_settings");present=YES;}
            }
            if(restore || !present)values[key]=candidateBaselinePreferences()[key];
        }
        for(NSString *key in [[values allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            NSInteger index=-1;
            for(NSInteger i=start;i<end;i++) {
                NSString *left=[[lines[i] componentsSeparatedByString:@"="][0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if([left isEqual:key]){if(index>=0)fail(@"invalid_game_settings");index=i;}
            }
            NSString *line=[NSString stringWithFormat:@"%@ = \"%@\"",key,values[key]];
            if(index>=0)lines[index]=line;else[lines insertObject:line atIndex:end++];
        }
        NSString *updated=[lines componentsJoinedByString:newline];
        if(![updated isEqual:original]) {
            mkdirs(join(root,@"settings-backup"));
            NSString *baselineBackup=join(root,@"settings-backup/before-candidate-baseline.ini");
            if(seed && ![fm fileExistsAtPath:baselineBackup] && ![original writeToFile:baselineBackup atomically:YES encoding:NSUTF8StringEncoding error:nil])fail(@"settings_backup_failed");
            if(restore && ![original writeToFile:join(root,@"settings-backup/before-candidate-restore.ini") atomically:YES encoding:NSUTF8StringEncoding error:nil])fail(@"settings_backup_failed");
            if(![original writeToFile:join(root,@"settings-backup/before-display-change.ini") atomically:YES encoding:NSUTF8StringEncoding error:nil])fail(@"settings_backup_failed");
            if(![updated writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil])fail(@"settings_write_failed");
        }
    }
    NSMutableDictionary *s=state();s[@"display_width"]=@(width);s[@"display_height"]=@(height);s[@"display_pending"]=@(!path);
    if(path)s[@"candidate_baseline_profile"]=CANDIDATE_PROFILE;
    writeJSON(s,join(root,@"state.json"));
    event(@"display_saved",@{@"width":@(width),@"height":@(height),@"pending_first_game":@(!path)});
}
static void configureDisplay(NSInteger width, NSInteger height) {configurePreferences(width,height,width,height,NO);}
/* The game's window must fit inside the main display as Wine sees it (twice its size in
 * points, in Retina mode), or Wine keeps the pointer out of part of it. A larger choice
 * (4K on a MacBook screen, say, after playing on a 4K monitor) is lowered for this
 * launch to the largest resolution of the same shape that fits, or the largest that
 * fits at all; the choice stays for the next larger display. */
static void fitResolution(NSInteger *width, NSInteger *height, NSInteger maxWidth, NSInteger maxHeight) {
    if(*width<=maxWidth && *height<=maxHeight)return;
    NSInteger bestWidth=0,bestHeight=0;
    for(int sameShape=1;sameShape>=0 && !bestWidth;sameShape--)
        for(NSArray *option in candidateResolutions()) {
            NSInteger w=[option[0] integerValue],h=[option[1] integerValue];
            if(w>maxWidth || h>maxHeight || (sameShape && w*(*height)!=h*(*width)))continue;
            if(w*h>bestWidth*bestHeight){bestWidth=w;bestHeight=h;}
        }
    if(bestWidth){*width=bestWidth;*height=bestHeight;}
}
static void fittedResolution(NSInteger *width, NSInteger *height) {
    CGDisplayModeRef mode=CGDisplayCopyDisplayMode(CGMainDisplayID());
    if(!mode)return;
    NSInteger maxWidth=(NSInteger)CGDisplayModeGetWidth(mode)*2,maxHeight=(NSInteger)CGDisplayModeGetHeight(mode)*2;
    CGDisplayModeRelease(mode);
    fitResolution(width,height,maxWidth,maxHeight);
}
/* The renderer profile with its canvas size set to this launch's resolution. DXMT matches
 * option names exactly, so the profile's own spelling is kept: a case-insensitive edit
 * once wrote "fullScreenCanvasHeight", which DXMT ignored, so 1080 turned the canvas off
 * and the game changed the display's mode instead. */
static NSString *canvasProfile(NSString *profile, NSInteger width, NSInteger height) {
    NSMutableArray *lines=[[profile componentsSeparatedByString:@"\n"] mutableCopy];
    int found=0;
    for(NSUInteger i=0;i<lines.count;i++) {
        NSString *key=[[lines[i] componentsSeparatedByString:@"="][0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if([key isEqual:@"dxgi.fullscreenCanvasWidth"]) {lines[i]=[NSString stringWithFormat:@"%@ = %ld",key,(long)width];found|=1;}
        else if([key isEqual:@"dxgi.fullscreenCanvasHeight"]) {lines[i]=[NSString stringWithFormat:@"%@ = %ld",key,(long)height];found|=2;}
    }
    if(found!=3)fail(@"runtime_missing");
    return [lines componentsJoinedByString:@"\n"];
}
