/* Candidate display invariants on every cold launch. Seed missing graphics
 * defaults once; explicit restore-candidate also restores the v6 graphics/FPS.
 * Never changes sensitivity, bindings or other sections. */
static NSArray *settingsFiles(void) {
    NSString *users=join(root,@"environment/drive_c/users");NSMutableArray *found=[NSMutableArray array];
    for(NSString *user in [fm contentsOfDirectoryAtPath:users error:nil]) {
        NSString *p=join(join(users,user),@"Documents/Overwatch/Settings/Settings_v0.ini");
        if([fm fileExistsAtPath:p])[found addObject:p];
    }
    return found;
}
static BOOL insideRoot(NSString *path) {return [[path stringByResolvingSymlinksInPath] hasPrefix:[root stringByAppendingString:@"/"]];}
static NSString *settingsPath(void) {
    NSArray *found=settingsFiles();
    for(NSString *p in found)if(!insideRoot(p))fail(@"settings_outside_installation");
    if(found.count>1)fail(@"multiple_game_settings");return found.firstObject;
}
/* The resolutions Settings offers (the contract's six). */
static BOOL supportedResolution(NSInteger width, NSInteger height) {
    for(NSArray *option in candidateResolutions())
        if([option[0] integerValue]==width && [option[1] integerValue]==height)return YES;
    return NO;
}
/* A resolution the game can have: one of Settings' six or one chosen in Overwatch's own
 * Video settings. The window driver's canvas shows each of those that fits inside the
 * display as Wine sees it, up to 16384 (cocoa_v1.m); fittedResolution keeps to that. */
static BOOL gameResolution(NSInteger width, NSInteger height) {
    return width>=640 && height>=480 && width<=16384 && height<=16384;
}
/* The resolution last chosen, in the app or in the game. Installations from before 1.0
 * stored only a height (1080 or 1200), always 1920 pixels wide. */
static void chosenResolution(NSInteger *width, NSInteger *height) {
    NSDictionary *s=state();
    *width=[s[@"display_width"] integerValue]?:CANDIDATE_DEFAULT_WIDTH;
    *height=[s[@"display_height"] integerValue]?:CANDIDATE_DEFAULT_HEIGHT;
    if(!gameResolution(*width,*height)) {*width=CANDIDATE_DEFAULT_WIDTH;*height=CANDIDATE_DEFAULT_HEIGHT;}
}
/* A key's value in the settings sections whose header starts with section, or nil if it
 * is missing or listed with different values. Some files have lines that begin with a
 * stray line feed (an early seed wrote "\n" into a CRLF file), so keys are trimmed of
 * both kinds of whitespace. */
static NSString *gameSetting(NSArray *lines, NSString *section, NSString *key) {
    NSString *value=nil;BOOL inside=NO;
    for(NSString *raw in lines) {
        NSString *line=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if([line hasPrefix:@"["]) {inside=[line hasPrefix:section];continue;}
        NSRange equals=[line rangeOfString:@"="];
        if(!inside || equals.location==NSNotFound)continue;
        NSString *left=[[line substringToIndex:equals.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if(![left isEqual:key])continue;
        NSString *right=[[line substringFromIndex:equals.location+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if(right.length>=2 && [right hasPrefix:@"\""] && [right hasSuffix:@"\""])right=[right substringWithRange:NSMakeRange(1,right.length-2)];
        if(value && ![value isEqual:right])return nil;
        value=right;
    }
    return value;
}
/* The graphics card Overwatch last saw, from its own record ([GPU.6]); "" without one. */
static NSString *gameGPU(NSArray *lines) {
    NSString *name=gameSetting(lines,@"[GPU.",@"GPUName"),*vendor=gameSetting(lines,@"[GPU.",@"GPUVenderID");
    return name||vendor ? [NSString stringWithFormat:@"%@|%@",name?:@"",vendor?:@""] : @"";
}
static BOOL pixelCount(NSString *text, NSInteger *value) {
    if(!matches(text,@"^[0-9]{3,5}$"))return NO;
    *value=text.integerValue;return YES;
}
/* The game's settings as they are now, without failing: the status and launch paths
 * read them before anything is written. */
static NSArray *gameSettingsLines(void) {
    NSArray *found=settingsFiles();
    if(found.count!=1 || !insideRoot(found[0]))return nil;
    if([[fm attributesOfItemAtPath:found[0] error:nil][NSFileSize] unsignedLongLongValue]>(1ULL<<20))return nil;
    NSString *text=[NSString stringWithContentsOfFile:found[0] encoding:NSUTF8StringEncoding error:nil];
    return [text componentsSeparatedByString:@"\n"];
}
/* The main display, where Overwatch opens, by make, model and serial number: the built-in
 * screen and each monitor keep their own resolution. nil without a display. Identical
 * monitors that report no serial number share one. */
static NSString *mainScreen(void) {
    CGDirectDisplayID display=CGMainDisplayID();
    if(!display || !CGDisplayIsOnline(display))return nil;
    return [NSString stringWithFormat:@"%u-%u-%u",CGDisplayVendorNumber(display),CGDisplayModelNumber(display),CGDisplaySerialNumber(display)];
}
/* Where a display Recall hasn't seen starts, as a new installation does (the app's
 * DisplayResolution.initial): 1080p in its shape, 1920x1200 on a 16:10 screen such as a
 * MacBook's and 1920x1080 on a wider one. */
static void screenDefault(NSInteger *width, NSInteger *height) {
    *width=1920;*height=1200;
    CGDisplayModeRef mode=CGDisplayCopyDisplayMode(CGMainDisplayID());
    if(!mode)return;
    double ratio=(double)CGDisplayModeGetWidth(mode)/MAX(CGDisplayModeGetHeight(mode),(size_t)1);
    CGDisplayModeRelease(mode);
    if(ratio>=1.69)*height=1080;
}
/* Settings › Remember a resolution for each display; on unless turned off. */
static BOOL displayMemory(NSDictionary *s) {return ![s[@"display_memory"] isEqual:@NO];}
/* A resolution chosen in the game since Recall last wrote the game's settings. Recall
 * remembers what it wrote (game_display_*) and the graphics card the game had recorded
 * (game_gpu). A different value in the game's settings now was chosen in the game
 * ("game"), unless the game's record of the card changed too ("game_reset"): Overwatch
 * resets its display settings for a card it takes to be new (on 2026-09-29, 1800x1125
 * at 60 Hz with Render Scale on Automatic), as on its first start. Until Recall has
 * written once and seen a card (a new installation's first game, the first launch after
 * an update from 1.0) there is nothing to compare: nil. */
static NSString *gameChoice(NSDictionary *s, NSInteger *width, NSInteger *height) {
    NSString *seenGPU=s[@"game_gpu"];
    NSInteger wroteWidth=[s[@"game_display_width"] integerValue],wroteHeight=[s[@"game_display_height"] integerValue];
    if(!wroteWidth || !wroteHeight || ![seenGPU isKindOfClass:NSString.class])return nil;
    NSArray *lines=gameSettingsLines();
    if(!lines || !pixelCount(gameSetting(lines,@"[Render.13]",@"FullScreenWidth"),width) ||
       !pixelCount(gameSetting(lines,@"[Render.13]",@"FullScreenHeight"),height))return nil;
    if((*width==wroteWidth && *height==wroteHeight) || !gameResolution(*width,*height))return nil;
    return [gameGPU(lines) isEqual:seenGPU] ? @"game" : @"game_reset";
}
static BOOL rememberedResolution(id value, NSInteger *width, NSInteger *height) {
    if(![value isKindOfClass:NSArray.class] || [value count]!=2)return NO;
    NSInteger w=[value[0] integerValue],h=[value[1] integerValue];
    if(!gameResolution(w,h))return NO;
    *width=w;*height=h;return YES;
}
/* The resolution Overwatch opens at next on the main display: the last one chosen there,
 * in Settings or in Overwatch's Video settings (displays, by mainScreen), or 1080p in its
 * shape on a display Recall hasn't seen. With display memory off, the last one chosen
 * anywhere (display_width/height). A choice made in the game counts for the display the
 * game last opened on (game_display_screen), even if another is the main display now.
 * Before display memory (1.0, earlier 1.1 builds) the one choice belongs to the main
 * display of the next launch. source is "game" when this resolution was just chosen in
 * the game, "game_reset" when the game's own reset was set aside, else nil. With save,
 * a choice made in the game is recorded before the launch writes the game's settings. */
static void nextResolution(NSInteger *width, NSInteger *height, NSString **source, BOOL save) {
    NSMutableDictionary *s=state();
    BOOL memory=displayMemory(s);NSString *screen=mainScreen();
    NSInteger lastWidth,lastHeight,gameWidth=0,gameHeight=0;chosenResolution(&lastWidth,&lastHeight);
    NSMutableDictionary *displays=[s[@"displays"] isKindOfClass:NSDictionary.class] ? [s[@"displays"] mutableCopy] : nil;
    NSString *game=gameChoice(s,&gameWidth,&gameHeight),*where=s[@"game_display_screen"];
    if([game isEqual:@"game"]) {
        lastWidth=gameWidth;lastHeight=gameHeight;
        if(memory && displays && [where isKindOfClass:NSString.class])displays[where]=@[@(gameWidth),@(gameHeight)];
    }
    // An installation that never saved a choice (prepare runs before the app's first
    // display command) starts in this display's shape.
    if(memory && screen && !displays && s[@"display_height"])displays=[@{screen:@[@(lastWidth),@(lastHeight)]} mutableCopy];
    if(!memory || !screen) {*width=lastWidth;*height=lastHeight;}
    else if(!displays || !rememberedResolution(displays[screen],width,height))screenDefault(width,height);
    *source=[game isEqual:@"game"] && (*width!=gameWidth || *height!=gameHeight) ? nil : game;
    if(save && (game || (displays && ![s[@"displays"] isKindOfClass:NSDictionary.class]))) {
        s[@"display_width"]=@(lastWidth);s[@"display_height"]=@(lastHeight);
        if(displays)s[@"displays"]=displays;
        writeJSON(s,join(root,@"state.json"));
    }
}
/* Saves the chosen resolution and writes the game's display settings. The game gets
 * gameWidth x gameHeight: the chosen size, or at launch the largest of the same shape
 * that fits the main display (fittedResolution). */
static void configurePreferences(NSInteger width, NSInteger height, NSInteger gameWidth, NSInteger gameHeight, BOOL restore) {
    if(!gameResolution(width,height) || !gameResolution(gameWidth,gameHeight))fail(@"unsupported_resolution");
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
    // The choice for the main display too, unless display memory is off.
    NSString *screen=mainScreen();
    if(screen && displayMemory(s)) {
        NSMutableDictionary *displays=[s[@"displays"] isKindOfClass:NSDictionary.class] ? [s[@"displays"] mutableCopy] : [NSMutableDictionary dictionary];
        displays[screen]=@[@(width),@(height)];s[@"displays"]=displays;
    }
    // What the game's settings now hold, the card the game had recorded and the display
    // it opens on, for nextResolution: a later difference there was chosen in the game.
    [s removeObjectsForKeys:@[@"game_display_width",@"game_display_height",@"game_gpu",@"game_display_screen"]];
    if(screen)s[@"game_display_screen"]=screen;
    if(path) {
        s[@"candidate_baseline_profile"]=CANDIDATE_PROFILE;
        NSString *written=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if(written) {
            s[@"game_display_width"]=@(gameWidth);s[@"game_display_height"]=@(gameHeight);
            s[@"game_gpu"]=gameGPU([written componentsSeparatedByString:@"\n"]);
        }
    }
    writeJSON(s,join(root,@"state.json"));
    event(@"display_saved",@{@"width":@(width),@"height":@(height),@"pending_first_game":@(!path)});
}
static void configureDisplay(NSInteger width, NSInteger height) {configurePreferences(width,height,width,height,NO);}
/* The game's window must fit inside the main display as Wine sees it (twice its size in
 * points, in Retina mode), or Wine keeps the pointer out of part of it. A larger choice
 * (4K on a MacBook screen, say, after playing on a 4K monitor, or 5120x2160 chosen in
 * the game on an ultrawide one) is lowered for this launch to the largest of Settings'
 * resolutions of the same shape that fits, or the largest that fits at all; the choice
 * stays for the next larger display. */
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
