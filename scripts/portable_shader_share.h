/* Recall-owned portable recipe exchange. Never transfers GPU binary archives. */
static NSString *shareDigest(NSData *data) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,bytes);
    NSMutableString *s=[NSMutableString string];for(unsigned i=0;i<sizeof(bytes);i++)[s appendFormat:@"%02x",bytes[i]];return s;
}
static void shareDirectory(NSString *path) {
    struct stat st;if(lstat(path.fileSystemRepresentation,&st) || !S_ISDIR(st.st_mode))fail(@"shader_share_invalid");
    if(![[path stringByResolvingSymlinksInPath] isEqual:path])fail(@"shader_share_invalid");
}
static NSData *shareRead(NSString *path, NSUInteger limit) {
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK);struct stat st;
    if(fd<0)fail(@"shader_share_invalid");
    if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_size<=0||(uint64_t)st.st_size>limit){close(fd);fail(@"shader_share_invalid");}
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)st.st_size];NSUInteger offset=0;
    while(offset<data.length){ssize_t n=read(fd,(char *)data.mutableBytes+offset,data.length-offset);if(n<=0){close(fd);fail(@"shader_share_invalid");}offset+=(NSUInteger)n;}
    close(fd);return data;
}
static NSDictionary *shareJSON(NSData *data) {
    id value=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if(![value isKindOfClass:NSDictionary.class])fail(@"shader_share_invalid");return value;
}
static NSDictionary *shareCompatibility(void) {
    NSDictionary *env=candidateEnvironment();
    return @{@"runtime":state()[@"active_runtime"] ?: @"",@"namespace":env[@"DXMT_PIPELINE_CACHE_NAMESPACE"],
        @"os":NSProcessInfo.processInfo.operatingSystemVersionString};
}
static NSString *shareNamespace(void) {
#ifdef RECALL_SHADER_SHARE_FIXTURE
    return join(root,@"cache/pipelines/fixture-device");
#endif
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();if(!device)fail(@"shader_share_no_device");
    NSString *identity=[NSString stringWithFormat:@"dxmt-render-cache-v1|%@|%@|%llu|%@",candidateEnvironment()[@"DXMT_PIPELINE_CACHE_NAMESPACE"],
        NSProcessInfo.processInfo.operatingSystemVersionString,(unsigned long long)device.registryID,device.name];
    return join(join(root,@"cache/pipelines"),shareDigest([identity dataUsingEncoding:NSUTF8StringEncoding]));
}
static NSSet *shareDependencies(NSDictionary *record, NSString *key) {
    NSDictionary *recipe=record[@"recipe"];NSNumber *cost=record[@"cost_us"];
    if(![recipe isKindOfClass:NSDictionary.class]||![cost isKindOfClass:NSNumber.class]||!isfinite(cost.doubleValue)||cost.doubleValue<0||cost.doubleValue>60000000)fail(@"shader_share_invalid");
    if(![recipe[@"schema"] isEqual:@1])fail(@"shader_share_invalid");
    NSData *encoded=[NSJSONSerialization dataWithJSONObject:recipe options:NSJSONWritingSortedKeys error:nil];
    if(!encoded||encoded.length>65536||![shareDigest(encoded) isEqual:key])fail(@"shader_share_invalid");
    NSMutableSet *dependencies=[NSMutableSet set];
    for(NSString *stage in @[@"vertex",@"fragment"]) {
        id function=recipe[stage];if([stage isEqual:@"fragment"]&&function==NSNull.null)continue;
        if(![function isKindOfClass:NSDictionary.class]||!matches(function[@"library"],@"^[a-f0-9]{64}$"))fail(@"shader_share_invalid");
        [dependencies addObject:function[@"library"]];
    }
    return dependencies;
}
static NSDictionary *shareInventory(NSString *directory) {
    shareDirectory(directory);NSMutableDictionary *files=[NSMutableDictionary dictionary];NSMutableSet *needed=[NSMutableSet set];
    NSString *recipes=join(directory,@"recipes"),*libraries=join(directory,@"libraries");shareDirectory(recipes);shareDirectory(libraries);
    NSArray *names=[fm contentsOfDirectoryAtPath:recipes error:nil];if(names.count>32768)fail(@"shader_share_limit");
    uint64_t total=0;
    for(NSString *name in names) {
        if(!matches(name,@"^[a-f0-9]{64}[.]json$"))fail(@"shader_share_invalid");
        NSData *bytes=shareRead(join(recipes,name),131072);[needed unionSet:shareDependencies(shareJSON(bytes),name.stringByDeletingPathExtension)];
        files[join(@"recipes",name)]=@{@"sha256":shareDigest(bytes),@"bytes":@(bytes.length)};total+=bytes.length;
        if(total>2ull*1024*1024*1024)fail(@"shader_share_limit");
    }
    if(needed.count>65536)fail(@"shader_share_limit");
    for(NSString *key in needed) {
        NSString *name=[key stringByAppendingString:@".air"];NSData *bytes=shareRead(join(libraries,name),8*1024*1024);
        if(![shareDigest(bytes) isEqual:key])fail(@"shader_share_invalid");
        files[join(@"libraries",name)]=@{@"sha256":key,@"bytes":@(bytes.length)};total+=bytes.length;
        if(total>2ull*1024*1024*1024)fail(@"shader_share_limit");
    }
    return files;
}
static void shareMerge(NSString *source, NSString *destination, NSDictionary *files, NSUInteger *added, NSUInteger *kept) {
    // Validate all conflicts BEFORE publishing any file. Existing records always win.
    for(NSString *relative in files) {
        NSString *target=join(destination,relative);if(![fm fileExistsAtPath:target])continue;
        NSData *old=shareRead(target,[relative hasPrefix:@"recipes/"]?131072:8*1024*1024);
        if([relative hasPrefix:@"recipes/"]) {
            NSDictionary *a=shareJSON(old),*b=shareJSON(shareRead(join(source,relative),131072));
            shareDependencies(a,relative.lastPathComponent.stringByDeletingPathExtension);
            if(![a[@"recipe"] isEqual:b[@"recipe"]])fail(@"shader_share_conflict");
        } else if(![shareDigest(old) isEqual:files[relative][@"sha256"]])fail(@"shader_share_conflict");
    }
    event(@"shader_share_progress",@{@"completed":@0,@"total":@(files.count)});
    for(NSString *group in @[@"libraries",@"recipes"])for(NSString *relative in files) {
        if(![relative hasPrefix:[group stringByAppendingString:@"/"]])continue;
        NSString *target=join(destination,relative);if([fm fileExistsAtPath:target]){(*kept)++;event(@"shader_share_progress",@{@"completed":@(*added+*kept),@"total":@(files.count)});continue;}
        NSData *bytes=shareRead(join(source,relative),[group isEqual:@"recipes"]?131072:8*1024*1024);
        if(![shareDigest(bytes) isEqual:files[relative][@"sha256"]])fail(@"shader_share_invalid");
        if(![bytes writeToFile:target options:NSDataWritingWithoutOverwriting error:nil])fail(@"shader_share_write_failed");(*added)++;
        if((*added+*kept)%32==0 || *added+*kept==files.count)event(@"shader_share_progress",@{@"completed":@(*added+*kept),@"total":@(files.count)});
    }
}
static void shaderShare(BOOL importing, NSString *requested) {
    if(![requested isAbsolutePath])fail(@"shader_share_invalid");
    NSString *folder=requested.stringByStandardizingPath;shareDirectory(folder);
#ifndef RECALL_SHADER_SHARE_FIXTURE
    if(sessionProcesses().count)fail(@"close_game_before_maintenance");
    if(!stopMonitor())fail(@"shader_preparation_running");
#endif
    NSString *local=shareNamespace();
    if([folder isEqual:root]||[folder hasPrefix:[root stringByAppendingString:@"/"]]||[root hasPrefix:[folder stringByAppendingString:@"/"]])fail(@"shader_share_invalid");
    NSString *manifestPath=join(folder,@"recall-shaders.json");NSDictionary *compatibility=shareCompatibility();
    if(![compatibility[@"runtime"] length])fail(@"runtime_not_installed");
    NSUInteger added=0,kept=0;
    if(importing) {
        NSDictionary *manifest=shareJSON(shareRead(manifestPath,32*1024*1024));
        if(![manifest[@"schema"] isEqual:@1]||![manifest[@"compatibility"] isEqual:compatibility])fail(@"shader_share_incompatible");
        NSDictionary *files=shareInventory(folder);if(![files isEqual:manifest[@"files"]])fail(@"shader_share_invalid");
        mkdirs(local);mkdirs(join(local,@"recipes"));mkdirs(join(local,@"libraries"));
        shareDirectory(local);shareDirectory(join(local,@"recipes"));shareDirectory(join(local,@"libraries"));
        NSDictionary *existing=shareInventory(local);
        NSMutableSet *combined=[NSMutableSet setWithArray:existing.allKeys];[combined addObjectsFromArray:files.allKeys];
        NSUInteger recipes=0,libraries=0;uint64_t bytes=0;
        for(NSString *name in combined){if([name hasPrefix:@"recipes/"])recipes++;else libraries++;bytes+=[(files[name] ?: existing[name])[@"bytes"] unsignedLongLongValue];}
        if(recipes>32768||libraries>65536||bytes>2ull*1024*1024*1024)fail(@"shader_share_limit");space(bytes+256*1024*1024);
        shareMerge(folder,local,files,&added,&kept);
    } else {
        NSDictionary *files=shareInventory(local);if(!files.count)fail(@"shader_share_empty");
        if([fm fileExistsAtPath:manifestPath])fail(@"shader_share_export_not_empty");
        if([fm contentsOfDirectoryAtPath:folder error:nil].count)fail(@"shader_share_export_not_empty");
        mkdirs(join(folder,@"recipes"));mkdirs(join(folder,@"libraries"));
        shareMerge(local,folder,files,&added,&kept);
        writeJSON(@{@"schema":@1,@"compatibility":compatibility,@"files":files},manifestPath);
    }
    event(importing?@"shaders_imported":@"shaders_exported",@{@"added":@(added),@"kept":@(kept)});
}
