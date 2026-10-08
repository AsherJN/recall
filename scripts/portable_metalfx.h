/* MetalFX upscaling (1.3, issue #12): off unless the player turns it on in Settings, where they
 * also choose Sharpening (off, low or high). With it on, Overwatch sees an NVIDIA graphics card
 * and offers NVIDIA DLSS in its own Video settings; DXMT's DLSS stand-in runs it on Apple's
 * MetalFX temporal upscaler. A launch with it on:
 * - starts Battle.net, and so the game, with the contract's MetalFX environment: DXMT's NVIDIA
 *   identity (DXMT_ENABLE_NVEXT) and the engine's d3d12, DLSS and NVAPI stand-ins, which the
 *   contract's own environment leaves off;
 * - puts the engine's DLSS stand-in in system32. NVIDIA's loader, part of the game, loads only a
 *   system32\nvngx.dll with a valid signature; Wine's placeholder there has none, the engine's is
 *   signed with Recall's own certificate. The placeholder is kept in metalfx/ for later;
 * - writes the card the game is about to see into the game's own record of it ([GPU.6]):
 *   Overwatch resets its video settings for a card it takes to be new, which a switch would
 *   otherwise do both ways;
 * - adds the sharpening amount to this launch's dxmt.conf (d3d11.metalfxSharpness).
 * With it off, each of those is undone (the placeholder is put back, the Mac's card is written)
 * and a choice of DLSS in the game's settings (HighQualityUpsample "3") is cleared, so the game
 * uses its default; otherwise the launch is the same as before 1.3. */
static NSString *const metalfxNVNGX=@"lib/wine/x86_64-windows/nvngx.dll";
static NSString *systemDLSS(void) {return join(root,@"environment/drive_c/windows/system32/nvngx.dll");}
// The engine's DLSS stand-in by its manifest hash, or nil for an engine without the stand-ins.
static NSString *engineDLSS(NSString *engine) {
    NSDictionary *files=readJSON(join(engine,@"runtime.json"))[@"files"];
    if(![files isKindOfClass:NSDictionary.class] || ![files[@"lib/wine/x86_64-windows/nvapi64.dll"] isKindOfClass:NSDictionary.class])return nil;
    NSDictionary *nvngx=files[metalfxNVNGX];
    return [nvngx isKindOfClass:NSDictionary.class] && matches(nvngx[@"sha256"],@"^[a-f0-9]{64}$") ? nvngx[@"sha256"] : nil;
}
static NSString *regularFileHash(NSString *path) {
    struct stat st;
    return !lstat(path.fileSystemRepresentation,&st) && S_ISREG(st.st_mode) ? hashFile(path) : nil;
}
// Copies a file over target by renaming a copy beside it, so the game never sees half a file.
static BOOL replaceFile(NSString *source, NSString *target) {
    NSString *part=[target stringByAppendingString:@".recall-part"];
    [fm removeItemAtPath:part error:nil];
    if(![fm copyItemAtPath:source toPath:part error:nil])return NO;
    if(rename(part.fileSystemRepresentation,target.fileSystemRepresentation)) {[fm removeItemAtPath:part error:nil];return NO;}
    return YES;
}
/* system32\nvngx.dll: the engine's stand-in with upscaling on; with it off, whatever was there
 * before Recall put the stand-in there. Returns what was (or, without APPLY, would be) done. */
static NSString *configureDLSSFile(NSString *engine, NSString *wanted, BOOL apply) {
    NSString *path=systemDLSS(),*backup=join(root,@"metalfx/nvngx.dll");
    if(![fm fileExistsAtPath:path.stringByDeletingLastPathComponent])return @"none";
    NSString *current=regularFileHash(path),*ours=state()[@"metalfx_nvngx"];
    if(wanted) {
        if([current isEqual:wanted])return @"kept";
        if(!apply)return @"install";
        // A file Recall didn't put there (Wine's placeholder) is kept, to put back later.
        if(current && ![current isEqual:ours]) {mkdirs(backup.stringByDeletingLastPathComponent);if(!replaceFile(path,backup))return @"failed";}
        if(!replaceFile(join(engine,metalfxNVNGX),path) || ![regularFileHash(path) isEqual:wanted])return @"failed";
        NSMutableDictionary *s=state();s[@"metalfx_nvngx"]=wanted;writeJSON(s,join(root,@"state.json"));
        return @"installed";
    }
    BOOL placed=current && [current isEqual:ours];
    if(!placed && !ours)return @"none";
    if(!apply)return placed ? @"restore" : @"none";
    NSString *done=@"none";
    if(placed) {
        if(regularFileHash(backup)) {if(!replaceFile(backup,path))return @"failed";done=@"restored";}
        else {if(![fm removeItemAtPath:path error:nil])return @"failed";done=@"removed";}
    }
    NSMutableDictionary *s=state();[s removeObjectForKey:@"metalfx_nvngx"];writeJSON(s,join(root,@"state.json"));
    return done;
}
/* The card the game will see, as Overwatch records it in [GPU.6] (NSNull: no such line): DXMT's
 * RTX 4090 with upscaling on (dxgi_adapter.cpp: vendor 0x10DE, device 0x2684); else the Mac's GPU,
 * which DXMT names as Metal does, vendor 0x106B and device 0, for which the game writes no device. */
static NSDictionary *gameCard(BOOL metalfx) {
    if(metalfx)return @{@"GPUName":@"NVIDIA GeForce RTX 4090",@"GPUVenderID":@"4318",@"LastUsedGPUVendorID":@"4318",
                        @"GPUDeviceID":@"9860",@"LastUsedGPUDeviceID":@"9860"};
    NSString *name=MTLCreateSystemDefaultDevice().name;
    if(!name.length)return nil;
    return @{@"GPUName":name,@"GPUVenderID":@"4203",@"LastUsedGPUVendorID":@"4203",
             @"GPUDeviceID":NSNull.null,@"LastUsedGPUDeviceID":NSNull.null};
}
// The lines of the one section whose header starts with SECTION: [start, end); NO without one.
static BOOL settingsSection(NSArray *lines, NSString *section, NSInteger *start, NSInteger *end) {
    *start=-1;*end=lines.count;
    for(NSUInteger i=0;i<lines.count;i++) {
        NSString *line=[lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if(*start<0 && [line hasPrefix:section]) *start=i+1;
        else if(*start>=0 && [line hasPrefix:@"["]) {
            if([line hasPrefix:section])return NO;  // two such sections: leave the file alone
            if(*end==(NSInteger)lines.count)*end=i;
        }
    }
    return *start>=0;
}
static NSInteger settingLine(NSArray *lines, NSInteger start, NSInteger end, NSString *key) {
    for(NSInteger i=start;i<end;i++) {
        NSString *line=[lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSRange equals=[line rangeOfString:@"="];
        if(equals.location!=NSNotFound && [[[line substringToIndex:equals.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] isEqual:key])return i;
    }
    return -1;
}
/* The game's settings for this launch: its record of the card ([GPU.6]) names the card it will
 * see, and with upscaling off, a choice of DLSS is cleared. A game that hasn't recorded a card yet
 * (its first start) is left to record its own. Returns the changed keys; writes only with APPLY. */
static NSArray *configureGameCard(BOOL metalfx, BOOL apply) {
    NSString *path=settingsPath();
    NSDictionary *card=gameCard(metalfx);
    if(!path || !card)return @[];
    if([[fm attributesOfItemAtPath:path error:nil][NSFileSize] unsignedLongLongValue]>(1ULL<<20))fail(@"invalid_game_settings");
    NSString *original=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if(!original)fail(@"invalid_game_settings");
    NSString *newline=[original containsString:@"\r\n"]?@"\r\n":@"\n";
    NSMutableArray *lines=[[original componentsSeparatedByString:newline] mutableCopy],*changed=[NSMutableArray array];
    NSInteger start,end;
    if(settingsSection(lines,@"[GPU.",&start,&end)) {
        NSInteger last=start;  // after the section's last setting, before its blank lines
        for(NSInteger i=start;i<end;i++)if([lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length)last=i+1;
        for(NSString *key in [card.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            NSInteger index=settingLine(lines,start,end,key);id value=card[key];
            NSString *line=value==NSNull.null ? nil : [NSString stringWithFormat:@"%@ = \"%@\"",key,value];
            if(index>=0 && line && ![lines[index] isEqual:line]) {lines[index]=line;[changed addObject:key];}
            else if(index>=0 && !line) {[lines removeObjectAtIndex:index];end--;if(last>index)last--;[changed addObject:key];}
            else if(index<0 && line) {[lines insertObject:line atIndex:last++];end++;[changed addObject:key];}
        }
    }
    if(!metalfx && settingsSection(lines,@"[Render.13]",&start,&end)) {
        NSInteger index=settingLine(lines,start,end,@"HighQualityUpsample");
        if(index>=0 && [gameSetting(@[@"[Render.13]",lines[index]],@"[Render.13]",@"HighQualityUpsample") isEqual:@"3"]) {[lines removeObjectAtIndex:index];[changed addObject:@"HighQualityUpsample"];}
    }
    if(!changed.count || !apply)return changed;
    NSString *updated=[lines componentsJoinedByString:newline];
    mkdirs(join(root,@"settings-backup"));
    if(![original writeToFile:join(root,@"settings-backup/before-graphics-card.ini") atomically:YES encoding:NSUTF8StringEncoding error:nil])fail(@"settings_backup_failed");
    if(![updated writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil])fail(@"settings_write_failed");
    // The card Recall saw is now this one: a resolution the game resets for it is still undone
    // (gameChoice), and one the player chooses with it counts.
    NSMutableDictionary *s=state();
    if([s[@"game_gpu"] isKindOfClass:NSString.class]) {s[@"game_gpu"]=gameGPU([updated componentsSeparatedByString:@"\n"]);writeJSON(s,join(root,@"state.json"));}
    return changed;
}
/* Sets up this launch with upscaling ENABLED or not, and SHARPENING (off, low, high); without
 * APPLY it only reports. An engine without the stand-ins launches as with upscaling off. Returns
 * whether the launch has upscaling, and sets AMOUNT to the sharpening amount for dxmt.conf (nil
 * for none). Reports metalfx. */
static BOOL configureMetalFX(NSString *engine, BOOL enabled, NSString *sharpening, BOOL apply, NSString **amount) {
    if(![sharpening isEqual:@"off"] && !candidateMetalFXSharpening()[sharpening])fail(@"invalid_arguments");
    NSString *wanted=engineDLSS(engine);
    BOOL on=enabled && wanted;
    *amount=on ? candidateMetalFXSharpening()[sharpening] : nil;
    // A stand-in that couldn't be put in place only keeps DLSS out of the game's menu; the game
    // still sees the card its record names.
    NSString *file=configureDLSSFile(engine,on ? wanted : nil,apply);
    NSArray *settings=configureGameCard(on,apply);
    NSMutableDictionary *details=[@{@"enabled":@(on),@"available":@(wanted!=nil),@"nvngx":file,@"settings":settings} mutableCopy];
    if(*amount)details[@"sharpness"]=*amount;
    event(@"metalfx",details);
    return on;
}
/* This launch's dxmt.conf with the sharpening amount in the game's section (DXMT reads options
 * from the section of the running program; the profile's own options are kept). */
static NSString *sharpeningProfile(NSString *profile, NSString *amount) {
    if(!amount)return profile;
    return [profile stringByAppendingFormat:@"%@[Overwatch.exe]\nd3d11.metalfxSharpness = %@\n",[profile hasSuffix:@"\n"]?@"":@"\n",amount];
}
