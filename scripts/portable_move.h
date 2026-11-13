/* move (REC-82): the whole data folder (Battle.net, Overwatch, learned shaders, settings and
 * the engine) to another drive or folder, with no download. Settings › General › Move… runs it.
 *
 * The folder names its own place nowhere that a launch reads: Wine's C: drive is a relative
 * link, and the worker hands Wine and the graphics layer the folder at every launch (wineEnv).
 * So a move is a copy of the files as they are.
 *
 * The installation in use stays untouched and in use until the copy is whole, checked and on
 * the destination drive itself:
 *   1. What can be refused is refused first, the room it needs included, before anything closes.
 *   2. Battle.net is closed (Overwatch itself must be quit first), a monitor or shader
 *      preparation is ended, and the Wine session with it: nothing may write while files copy.
 *   3. On the same volume the folder is renamed, which takes no time and no room.
 *   4. Otherwise everything is copied into "<destination>.moving" beside the destination. Links
 *      are recreated byte for byte, never followed (Wine's z: drive is a link to /). The
 *      ownership marker is left out, so a part copy is never taken for an installation.
 *   5. The volume is synced, and every file is read back and compared with the original.
 *   6. The copy gets the marker, the volume is synced, the copy gets its final name, and the
 *      volume is synced again: a drive unplugged the moment the app says "Moved" holds the
 *      installation under its final name.
 *   7. move_committed, and only then does the original go to the Trash: moved, never deleted,
 *      as uninstall does.
 * A drive unplugged, a full disk or a copy that differs ends the move with the original as it
 * was; the part copy stays, and the next move to the same place goes on from it (a file already
 * whole there is not copied again, and is still compared). Cancel removes the part copy, as
 * --discard 1 does for a move the player gives up on; that one needs no data folder, so it
 * works with the installation's own drive unplugged (main runs it before ownRoot).
 *
 * Events: move_progress {phase: copying|checking, bytes, total}, move_committed {to},
 * moved {to, copied, and trashed or kept}, move_discarded. move_problem {file, errno} names the
 * file a failure stopped at, relative to the folder, for support. */
#include <copyfile.h>
#include <fts.h>
#include <IOKit/pwr_mgt/IOPMLib.h>

static const char *const moveMarker=".overwatch-2-mac-owner";
// A part copy this worker made, and so may add to or remove.
static const char *const moveTag=".overwatch-2-mac-move";
static uint64_t moveTotal,moveDone,moveFileBase;
static NSTimeInterval moveReported;
static NSString *movePhase=@"copying";
static void moveProgress(BOOL now) {
    NSTimeInterval uptime=NSProcessInfo.processInfo.systemUptime;
    if(!now && uptime-moveReported<0.25)return;
    moveReported=uptime;
    event(@"move_progress",@{@"phase":movePhase,@"bytes":@(MIN(moveDone,moveTotal)),@"total":@(moveTotal)});
}
static NSString *movePath(const char *path) { return [fm stringWithFileSystemRepresentation:path length:strlen(path)] ?: @""; }
/* Why a move stopped, from what is still there: a drive that went away says so itself, whatever
 * the error the file gave. THERE is a folder on the destination that the move needs. */
static void moveStopped(const char *relative, int code, NSString *there) {
    if(cancelRequested)fail(@"cancelled");
    event(@"move_problem",@{@"file":movePath(relative),@"errno":@(code)});
    struct stat st;
    if(stat(there.fileSystemRepresentation,&st))fail(@"move_destination_disconnected");
    if(stat(root.fileSystemRepresentation,&st))fail(@"install_location_unavailable");
    if(code==ENOSPC || code==EDQUOT)fail(@"move_destination_full");
    if(code==EACCES || code==EPERM || code==EROFS)fail(@"move_destination_not_writable");
    fail(@"move_copy_failed");
}
/* Every entry under TOP, links not followed and other volumes not entered. VISIT gets the
 * entry and its path relative to TOP; it may skip a folder with fts_set. */
static void moveWalk(NSString *top, NSString *there, void (^visit)(FTS *walk, FTSENT *entry, const char *relative)) {
    char *paths[]={(char *)top.fileSystemRepresentation,NULL};
    size_t skip=strlen(paths[0])+1;
    FTS *walk=fts_open(paths,FTS_PHYSICAL|FTS_NOCHDIR|FTS_XDEV,NULL);
    if(!walk)moveStopped("",errno,there);
    @try {
        while(YES) {
            errno=0;
            FTSENT *entry=fts_read(walk);
            if(!entry) {if(errno)moveStopped("",errno,there);break;}
            if(cancelRequested)fail(@"cancelled");
            const char *relative=entry->fts_level ? entry->fts_path+skip : "";
            if(entry->fts_info==FTS_DNR || entry->fts_info==FTS_ERR || entry->fts_info==FTS_NS)moveStopped(relative,entry->fts_errno,there);
            if(entry->fts_level==0)continue;
            @autoreleasepool { visit(walk,entry,relative); }
        }
    } @finally { fts_close(walk); }
}
// A link's target as its bytes are: a name never passes through a string, which could rewrite it.
static NSData *moveLink(const char *path) {
    char target[PATH_MAX];ssize_t length=readlink(path,target,sizeof(target)-1);
    if(length<0)return nil;
    target[length]=0;return [NSData dataWithBytes:target length:(NSUInteger)length+1];
}
// A file an earlier, interrupted move already copied whole. It is still compared afterwards.
static BOOL moveAlreadyCopied(const struct stat *source, const char *copy) {
    struct stat st;
    return !lstat(copy,&st) && S_ISREG(st.st_mode) && st.st_size==source->st_size && st.st_mtimespec.tv_sec==source->st_mtimespec.tv_sec;
}
static int moveCopyStatus(int what, int stage, copyfile_state_t state, const char *source, const char *copy, void *context) {
    (void)source;(void)copy;(void)context;
    if(cancelRequested)return COPYFILE_QUIT;
    if(what==COPYFILE_COPY_DATA && stage==COPYFILE_PROGRESS) {
        off_t copied=0;
        if(!copyfile_state_get(state,COPYFILE_STATE_COPIED,&copied)) {moveDone=moveFileBase+(uint64_t)copied;moveProgress(NO);}
    }
    return COPYFILE_CONTINUE;
}
// Whatever is at PATH inside a part copy goes; NO if it is still there.
static BOOL moveRemove(const char *path) {
    struct stat st;
    if(lstat(path,&st))return errno==ENOENT;
    lchflags(path,0);
    if(S_ISDIR(st.st_mode))[fm removeItemAtPath:movePath(path) error:nil];else unlink(path);
    return lstat(path,&st) && errno==ENOENT;
}
// The room a file takes on another volume: its length, or more where the blocks say so.
static uint64_t moveRoom(const struct stat *st) { return MAX((uint64_t)st->st_size,(uint64_t)st->st_blocks*512); }
static uint64_t moveFree(NSString *folder) {
    struct statfs fs;
    uint64_t free=statfs(folder.fileSystemRepresentation,&fs) ? 0 : (uint64_t)fs.f_bavail*fs.f_bsize;
    // Finder's "available", which counts what macOS clears on demand.
    NSNumber *available=nil;
    if([[NSURL fileURLWithPath:folder] getResourceValue:&available forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil] && available.unsignedLongLongValue>free)
        free=available.unsignedLongLongValue;
    return free;
}
/* Everything written to FOLDER's volume so far is on the drive itself, not in macOS's memory or
 * the drive's write cache. fsync on one file would leave the others, and a rename, behind. */
static void moveSync(NSString *folder) {
    int fd=open(folder.fileSystemRepresentation,O_RDONLY);
    int code=fd<0 || fsync_volume_np(fd,SYNC_VOLUME_FULLSYNC|SYNC_VOLUME_WAIT) ? errno : 0;
    if(fd>=0)close(fd);
    if(code)moveStopped("",code,folder);
}
static BOOL moveSameBytes(const char *original, const char *copy, char *first, char *second, size_t size) {
    int a=open(original,O_RDONLY|O_NOFOLLOW),b=open(copy,O_RDONLY|O_NOFOLLOW);
    BOOL same=a>=0 && b>=0;
    // Not through macOS's file cache. The volume was synced first (moveSync), so what was written
    // has reached the drive; a file as large as the game's is then read from the drive again.
    if(same) {fcntl(a,F_NOCACHE,1);fcntl(b,F_NOCACHE,1);}
    uint64_t base=moveDone;
    while(same) {
        if(cancelRequested) {close(a);close(b);fail(@"cancelled");}
        ssize_t got=0,other=0;
        while((size_t)got<size) {ssize_t n=read(a,first+got,size-(size_t)got);if(n<0) {same=NO;break;} if(!n)break;got+=n;}
        while(same && (size_t)other<size) {ssize_t n=read(b,second+other,size-(size_t)other);if(n<0) {same=NO;break;} if(!n)break;other+=n;}
        if(!same || got!=other || memcmp(first,second,(size_t)got)) {same=NO;break;}
        if(!got)break;
        moveDone+=(uint64_t)got;moveProgress(NO);
    }
    if(a>=0)close(a);
    if(b>=0)close(b);
    if(same)moveDone=base;
    return same;
}
// Where the folder goes: its parent with links resolved, as ownRoot resolves the folder itself.
static NSString *moveDestination(NSString *requested) {
    if(!requested.length || ![requested isAbsolutePath])fail(@"invalid_arguments");
    NSString *standard=[requested stringByStandardizingPath];
    NSString *destination=join([[standard stringByDeletingLastPathComponent] stringByResolvingSymlinksInPath],standard.lastPathComponent);
    if([destination isEqual:@"/"] || [destination isEqual:NSHomeDirectory()] || !standard.lastPathComponent.length)fail(@"unsafe_install_directory");
    return destination;
}
// Only a part copy with this worker's tag: a folder that merely has the name is someone else's.
static void moveDiscard(NSString *requested) {
    NSString *staging=[moveDestination(requested) stringByAppendingString:@".moving"];
    if([fm fileExistsAtPath:join(staging,@(moveTag))] && ![fm removeItemAtPath:staging error:nil])fail(@"move_discard_failed");
    event(@"move_discarded",nil);
}
static void moveInstallation(NSString *requested) {
    NSString *destination=moveDestination(requested),*parent=[destination stringByDeletingLastPathComponent];
    NSString *staging=[destination stringByAppendingString:@".moving"];
    if([destination isEqual:root])fail(@"move_same_location");
    if([destination hasPrefix:[root stringByAppendingString:@"/"]])fail(@"move_destination_inside_source");
    // The destination's drive must be there: never a stray folder where an unplugged drive was.
    BOOL directory=NO;
    if(!([fm fileExistsAtPath:parent isDirectory:&directory] && directory))fail(@"move_destination_unavailable");
    NSArray *parts=destination.pathComponents;
    if(parts.count>3 && [parts[1] isEqual:@"Volumes"]) {
        NSString *volume=[NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0,3)]];
        struct statfs mounted;
        if(statfs(volume.fileSystemRepresentation,&mounted) || strcmp(mounted.f_mntonname,volume.fileSystemRepresentation))fail(@"move_destination_unavailable");
    }
    // Only a folder that isn't there yet, or an empty one: nothing of the player's is replaced,
    // and another installation is never merged into.
    struct stat there;
    if(!lstat(destination.fileSystemRepresentation,&there)) {
        if(!S_ISDIR(there.st_mode))fail(@"move_destination_in_use");
        for(NSString *name in [fm contentsOfDirectoryAtPath:destination error:nil])
            if(![name isEqual:@".DS_Store"])fail(@"move_destination_in_use");
    }
    // A part copy from an earlier move has this worker's tag. A folder of that name with anything
    // else in it is someone else's; an empty one is a move that stopped before its tag was written.
    BOOL resuming=!lstat(staging.fileSystemRepresentation,&there);
    if(resuming && !S_ISDIR(there.st_mode))fail(@"move_destination_in_use");
    if(resuming && ![fm fileExistsAtPath:join(staging,@(moveTag))]) {
        for(NSString *name in [fm contentsOfDirectoryAtPath:staging error:nil])
            if(![name isEqual:@".DS_Store"])fail(@"move_destination_in_use");
        [fm removeItemAtPath:join(staging,@".DS_Store") error:nil];
        if(rmdir(staging.fileSystemRepresentation))fail(@"move_destination_in_use");
        resuming=NO;
    }
    supportedVolume(parent);
    struct stat from,to;
    if(lstat(root.fileSystemRepresentation,&from) || stat(parent.fileSystemRepresentation,&to))fail(@"move_destination_unavailable");
    BOOL sameVolume=from.st_dev==to.st_dev;
    char *source=strdup(root.fileSystemRepresentation),*target=strdup(staging.fileSystemRepresentation);
    char *(^copyPath)(const char *)=^char *(const char *relative) {
        static char path[PATH_MAX*2];
        snprintf(path,sizeof(path),"%s/%s",target,relative);return path;
    };
    // Left out: the marker, so a part copy is never taken for an installation; a tag an earlier
    // move left in the installation; and Finder's notes about a folder's window, which Finder may
    // write while the copy runs.
    BOOL (^leftOut)(FTSENT *, const char *)=^BOOL(FTSENT *entry, const char *relative) {
        return (entry->fts_level==1 && (!strcmp(relative,moveMarker) || !strcmp(relative,moveTag))) || !strcmp(entry->fts_name,".DS_Store");
    };
    // What there is to copy, and the room it needs beyond what a part copy already holds.
    uint64_t (^measure)(void)=^uint64_t {
        __block uint64_t needed=0;
        moveTotal=0;
        moveWalk(root,parent,^(FTS *walk, FTSENT *entry, const char *relative) {
            (void)walk;
            if(entry->fts_info!=FTS_F || leftOut(entry,relative))return;
            moveTotal+=(uint64_t)entry->fts_statp->st_size;
            if(!(resuming && moveAlreadyCopied(entry->fts_statp,copyPath(relative))))needed+=moveRoom(entry->fts_statp);
        });
        return needed;
    };
    // Refused when it can't fit, with a little over for the volume's own bookkeeping, before
    // Battle.net is closed for nothing. A drive that fills while files copy stops the move the
    // same way (moveStopped).
    void (^room)(void)=^{
        uint64_t needed=measure();
        if(moveFree(parent)<needed+needed/50+(8ULL<<20))fail(@"move_destination_full");
    };
    IOPMAssertionID awake=kIOPMNullAssertionID;
    BOOL copying=NO;
    @try {
        if(!sameVolume)room();
        // Nothing may write while files copy: Battle.net (never a running Overwatch), the monitor
        // or a shader preparation, and the Wine session, which Battle.net's update Agent can keep alive.
        closeClient(@"close_game_before_move");
        stopInstallerWatch();
        stopMonitor();stopAfterSession();
        int monitor=open(join(root,@"launch-monitor.lock").fileSystemRepresentation,O_CREAT|O_RDWR|O_NOFOLLOW,0600);
        if(monitor>=0) {
            BOOL ended=flock(monitor,LOCK_EX|LOCK_NB)==0;
            close(monitor);
            if(!ended)fail(@"shader_preparation_running");
        }
        if(matches(state()[@"active_runtime"],@"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$") && [fm fileExistsAtPath:join(join(join(root,@"runtimes"),state()[@"active_runtime"]),@"runtime.json")] &&
           [fm fileExistsAtPath:join(root,@"environment")]) {
            NSString *engine=runtime();
            waitTask(task(join(engine,@"bin/wineserver"),@[@"-k"],wineEnv(engine),@"move-stop.log"),15);
            if(busy(engine))fail(@"close_game_before_move");
        }
        NSDate *started=[NSDate date];
        // The same volume: a rename, whatever the folder holds.
        if(sameVolume) {
            [fm removeItemAtPath:join(destination,@".DS_Store") error:nil];
            if(!rename(source,destination.fileSystemRepresentation)) {
                event(@"move_committed",@{@"to":destination});
                event(@"moved",@{@"to":destination,@"copied":@NO});
                return;
            }
            if(errno!=EXDEV)moveStopped("",errno,parent);
            room();
        }
        // The Mac stays awake: a sleeping Mac lets go of an external drive.
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep,kIOPMAssertionLevelOn,CFSTR("Moving Overwatch and Battle.net to another drive"),&awake);
        // Tests only: milliseconds to wait after each file, so a move can be interrupted part way.
        useconds_t pause=(useconds_t)MAX(0,[NSProcessInfo.processInfo.environment[@"OW2_SETUP_TEST_MOVE_PAUSE"] integerValue])*1000;
        void (^copyEntry)(FTSENT *, const char *)=^(FTSENT *entry, const char *relative) {
            const char *copy=copyPath(relative);
            struct stat st;
            switch(entry->fts_info) {
            case FTS_D:
                // A real folder: never through a link an earlier part copy has in its place.
                if(!lstat(copy,&st) && S_ISDIR(st.st_mode))break;
                if(!moveRemove(copy) || mkdir(copy,0700))moveStopped(relative,errno,staging);
                break;
            case FTS_DP:
                // A folder's own dates, flags and attributes, once what it holds is in place.
                if(copyfile(entry->fts_path,copy,NULL,COPYFILE_METADATA|COPYFILE_NOFOLLOW))moveStopped(relative,errno,staging);
                break;
            case FTS_SL: case FTS_SLNONE: {
                // Recreated as it reads, never followed: Wine's z: drive is a link to /.
                NSData *link=moveLink(entry->fts_path);
                if(!link)moveStopped(relative,errno,staging);
                if([moveLink(copy) isEqual:link])break;
                if(!moveRemove(copy) || symlink(link.bytes,copy))moveStopped(relative,errno,staging);
                break;
            }
            case FTS_F: {
                uint64_t size=(uint64_t)entry->fts_statp->st_size;
                if(!moveAlreadyCopied(entry->fts_statp,copy)) {
                    if(!moveRemove(copy))moveStopped(relative,errno,staging);
                    copyfile_state_t progress=copyfile_state_alloc();
                    copyfile_state_set(progress,COPYFILE_STATE_STATUS_CB,moveCopyStatus);
                    moveFileBase=moveDone;
                    int result=copyfile(entry->fts_path,copy,progress,COPYFILE_ALL|COPYFILE_NOFOLLOW|COPYFILE_EXCL|COPYFILE_DATA_SPARSE),code=errno;
                    copyfile_state_free(progress);
                    if(result)moveStopped(relative,code,staging);
                    moveDone=moveFileBase;
                    if(pause)usleep(pause);
                }
                moveDone+=size;moveProgress(NO);
                break;
            }
            default: break;   // Sockets and the like hold nothing to keep.
            }
        };
        size_t chunk=1<<20;
        NSMutableData *first=[NSMutableData dataWithLength:chunk],*second=[NSMutableData dataWithLength:chunk];
        // The copy of an entry is there and, for a file, has the original's bytes.
        BOOL (^sameEntry)(FTSENT *, const char *)=^BOOL(FTSENT *entry, const char *relative) {
            const char *copy=copyPath(relative);
            struct stat st;
            switch(entry->fts_info) {
            case FTS_D: return !lstat(copy,&st) && S_ISDIR(st.st_mode);
            case FTS_SL: case FTS_SLNONE: {NSData *link=moveLink(entry->fts_path);return link && [moveLink(copy) isEqual:link];}
            case FTS_F: return !lstat(copy,&st) && S_ISREG(st.st_mode) && st.st_size==entry->fts_statp->st_size &&
                               moveSameBytes(entry->fts_path,copy,first.mutableBytes,second.mutableBytes,chunk);
            default: return YES;
            }
        };
        if(!resuming) {
            if(mkdir(target,0700))moveStopped("",errno,parent);
            if(![@"ow2-move-v1\n" writeToFile:join(staging,@(moveTag)) atomically:YES encoding:NSUTF8StringEncoding error:nil])moveStopped("",errno ?: EIO,parent);
        } else {
            // A part copy from an earlier move. It is no installation until this one finishes; what
            // the installation no longer has goes, and so does anything that changed between a
            // folder and a file. Only an entry the installation really lacks: a drive that went
            // away answers differently, and stops the move with the part copy as it is.
            if(!moveRemove(join(staging,@(moveMarker)).fileSystemRepresentation))moveStopped(moveMarker,errno,staging);
            moveWalk(staging,staging,^(FTS *walk, FTSENT *entry, const char *relative) {
                if(entry->fts_level==1 && !strcmp(relative,moveTag))return;
                char original[PATH_MAX*2];snprintf(original,sizeof(original),"%s/%s",source,relative);
                struct stat st;BOOL missing=NO;
                if(lstat(original,&st)) {
                    if(errno!=ENOENT && errno!=ENOTDIR)moveStopped(relative,errno,staging);
                    if(stat(source,&st))fail(@"install_location_unavailable");
                    missing=YES;
                }
                BOOL folder=entry->fts_info==FTS_D || entry->fts_info==FTS_DP;
                if(!missing && folder==(BOOL)S_ISDIR(st.st_mode))return;
                if(entry->fts_info==FTS_DP)return;
                if(entry->fts_info==FTS_D)fts_set(walk,entry,FTS_SKIP);
                if(!moveRemove(entry->fts_path))moveStopped(relative,errno ?: EIO,staging);
            });
        }
        // Again, now that nothing writes to the installation: these are the bytes to copy.
        room();
        copying=YES;movePhase=@"copying";moveDone=0;moveProgress(YES);
        moveWalk(root,staging,^(FTS *walk, FTSENT *entry, const char *relative) {
            (void)walk;
            if(!leftOut(entry,relative))copyEntry(entry,relative);
        });
        moveProgress(YES);
        // Checked: every folder, link and file is there, and every file's bytes are the
        // original's, read after the volume was synced. One that differs is copied once more (a
        // file something wrote to while the copy ran); if it still differs, nothing is switched.
        moveSync(staging);
        movePhase=@"checking";moveDone=0;moveProgress(YES);
        moveWalk(root,staging,^(FTS *walk, FTSENT *entry, const char *relative) {
            (void)walk;
            if(leftOut(entry,relative))return;
            uint64_t checked=moveDone;
            BOOL same=sameEntry(entry,relative);
            if(!same) {
                event(@"move_problem",@{@"file":movePath(relative),@"errno":@0});
                struct stat gone;
                if(stat(target,&gone))fail(@"move_destination_disconnected");
                if(stat(source,&gone))fail(@"install_location_unavailable");
                if(entry->fts_info==FTS_F)moveRemove(copyPath(relative));
                copyEntry(entry,relative);
                moveDone=checked;
                same=sameEntry(entry,relative);
                if(!same && entry->fts_info==FTS_F)moveRemove(copyPath(relative));
                if(!same)fail(@"move_verification_failed");
            }
            moveDone=checked;
            if(entry->fts_info==FTS_F) {moveDone+=(uint64_t)entry->fts_statp->st_size;moveProgress(NO);}
        });
        moveProgress(YES);
        // The marker last. Synced with everything copied, so the part copy is whole on the drive
        // before it gets its final name; then the name, and the tag off; then synced again, so the
        // drive holds the installation under that name before the original goes anywhere.
        if(copyfile(join(root,@(moveMarker)).fileSystemRepresentation,join(staging,@(moveMarker)).fileSystemRepresentation,NULL,COPYFILE_ALL|COPYFILE_NOFOLLOW))moveStopped(moveMarker,errno,staging);
        chmod(target,0700);
        moveSync(staging);
        [fm removeItemAtPath:join(destination,@".DS_Store") error:nil];
        if(rename(target,destination.fileSystemRepresentation))moveStopped("",errno,staging);
        [fm removeItemAtPath:join(destination,@(moveTag)) error:nil];
        moveSync(destination);
        // From here the copy is the installation: the app keeps the new place before the original
        // leaves. It goes to the Trash, recoverable with Put Back; if macOS refuses, it stays
        // where it is and the app says so.
        event(@"move_committed",@{@"to":destination});
        NSURL *trashed=nil;
        BOOL removed=[fm trashItemAtURL:[NSURL fileURLWithPath:root] resultingItemURL:&trashed error:nil];
        NSMutableDictionary *result=[@{@"to":destination,@"copied":@YES,@"bytes":@(moveTotal),@"seconds":@((NSInteger)-started.timeIntervalSinceNow)} mutableCopy];
        if(removed)result[@"trashed"]=trashed.path ?: @"";else result[@"kept"]=root;
        event(@"moved",result);
    } @catch(NSException *exception) {
        // Cancel is the player's choice not to move: the part copy goes, as does one that never
        // got a file (no room for it). After anything else it stays for the next try.
        if((cancelRequested || !(copying || resuming)) && [fm fileExistsAtPath:join(staging,@(moveTag))])[fm removeItemAtPath:staging error:nil];
        @throw;
    } @finally {
        if(awake!=kIOPMNullAssertionID)IOPMAssertionRelease(awake);
        free(source);free(target);
    }
}
