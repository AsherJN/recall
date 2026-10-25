/* Native Phase 2 setup worker. Original project contributions: Apache-2.0.
 * Foundation/libarchive/CommonCrypto are supplied by macOS; no player Python.
 * The future app supplies a reviewed archive URL/hash/version, never arbitrary
 * downloaded executable instructions. JSON events are deliberately account-free.
 */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/IOKitLib.h>
#import <Metal/Metal.h>
#include <CommonCrypto/CommonDigest.h>
#include <archive.h>
#include <archive_entry.h>
#include <sys/file.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <fcntl.h>
#include <errno.h>
#include <libproc.h>
#include <signal.h>
#include <unistd.h>
#include "candidate_contract.generated.h"

static NSFileManager *fm;
static NSString *root;
static int lockFD = -1;
static BOOL monitorMode;
// The program Overwatch runs as (gameProgram), which a session's monitor passes on to preparation
// after the match (watch --game-app): the engine's game app, or Wine's own loader without Game Mode.
static NSString *monitorGameApp;
// A monitor started by prepare-shaders (watch --prepare-now 1) prepares before it watches.
static BOOL monitorPrepareNow;
// The Battle.net start a launch's monitor watches (watch --session), whose record it adds to (portable_logs.h).
static NSString *monitorSession;
static BOOL ownedPreparation;
static volatile sig_atomic_t childPID;
static volatile sig_atomic_t cancelRequested;
static void cancelled(int sig) { cancelRequested=sig; if (childPID > 0) kill(childPID, SIGTERM); }
static void fail(NSString *code) { @throw [NSException exceptionWithName:@"SetupError" reason:code userInfo:nil]; }
static NSString *join(NSString *a, NSString *b) { return [a stringByAppendingPathComponent:b]; }
static void event(NSString *stage, NSDictionary *details) {
    NSMutableDictionary *value = [@{@"stage":stage} mutableCopy];
    [value addEntriesFromDictionary:details ?: @{}];
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout);
}
static void mkdirs(NSString *path) {
    if (![fm createDirectoryAtPath:path withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions:@0700} error:nil]) fail(@"directory_creation_failed");
}
static void writeJSON(id object, NSString *path) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:nil]) fail(@"state_write_failed");
}
static NSDictionary *readJSON(NSString *path) {
    if([[fm attributesOfItemAtPath:path error:nil][NSFileSize] unsignedLongLongValue]>(8ULL<<20))fail(@"manifest_size_limit");
    NSData *data = [NSData dataWithContentsOfFile:path];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![value isKindOfClass:NSDictionary.class]) fail(@"invalid_manifest");
    return value;
}
static BOOL matches(NSString *s, NSString *pattern) {
    if (!s) return NO;
    NSRange range = [s rangeOfString:pattern options:NSRegularExpressionSearch];
    return range.location == 0 && range.length == s.length;
}
static BOOL safePath(NSString *s) {
    if (!s.length || [s hasPrefix:@"/"] || [s containsString:@"\\"] || [s containsString:@"\n"] ||
        [s containsString:@"\r"] || [s containsString:@"\t"]) return NO;
    for (NSString *part in [s componentsSeparatedByString:@"/"])
        if (!part.length || [part isEqual:@"."] || [part isEqual:@".."]) return NO;
    return YES;
}
static NSString *hashFile(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) fail(@"file_read_failed");
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode)) { close(fd); fail(@"file_not_regular"); }
    CC_SHA256_CTX context; CC_SHA256_Init(&context);
    unsigned char buffer[1024*128], digest[CC_SHA256_DIGEST_LENGTH]; ssize_t count;
    while ((count = read(fd, buffer, sizeof(buffer))) > 0) CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    close(fd); if (count < 0) fail(@"file_read_failed");
    CC_SHA256_Final(digest, &context);
    NSMutableString *result = [NSMutableString string];
    for (unsigned int i=0; i<sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}
static uint64_t freeBytes(void) {
    return [[fm attributesOfFileSystemForPath:root error:nil][NSFileSystemFreeSize] unsignedLongLongValue];
}
static void space(uint64_t needed) { if (freeBytes() < needed) fail(@"insufficient_disk_space"); }
static void supportedVolume(NSString *path) {
    // Wine needs POSIX symlinks and Windows games expect case-insensitive
    // names: only APFS or Mac OS Extended, never case-sensitive or read-only.
    struct statfs fs;
    if (statfs(path.fileSystemRepresentation,&fs)) fail(@"install_location_unavailable");
    if (strcmp(fs.f_fstypename,"apfs") && strcmp(fs.f_fstypename,"hfs")) fail(@"unsupported_volume_format");
    if (fs.f_flags & MNT_RDONLY) fail(@"read_only_volume");
    if (pathconf(path.fileSystemRepresentation,_PC_CASE_SENSITIVE) == 1) fail(@"case_sensitive_volume");
}
static void ownRoot(NSString *requested) {
    root = [[requested stringByStandardizingPath] stringByResolvingSymlinksInPath];
    if (![root isAbsolutePath] || [root isEqual:@"/"] || [root isEqual:NSHomeDirectory()]) fail(@"unsafe_install_directory");
    // Only the data folder itself is ever created. A disconnected external
    // drive must not turn into a stray folder on the internal disk.
    NSString *parent = [root stringByDeletingLastPathComponent];
    BOOL parentIsDirectory = NO;
    if (![fm fileExistsAtPath:root] && !([fm fileExistsAtPath:parent isDirectory:&parentIsDirectory] && parentIsDirectory))
        fail(@"install_location_unavailable");
    // An unclean eject can leave an empty /Volumes/<name> folder: require a mount.
    NSArray *parts = root.pathComponents;
    if (parts.count > 3 && [parts[1] isEqual:@"Volumes"] && ![fm fileExistsAtPath:root]) {
        NSString *volume = [NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0,3)]];
        struct statfs mounted;
        if (statfs(volume.fileSystemRepresentation,&mounted) || strcmp(mounted.f_mntonname,volume.fileSystemRepresentation)) fail(@"install_location_unavailable");
    }
    NSString *marker = join(root,@".overwatch-2-mac-owner");
    if ([fm fileExistsAtPath:root] && ![fm fileExistsAtPath:marker] &&
        [fm contentsOfDirectoryAtPath:root error:nil].count) fail(@"directory_not_owned_by_app");
    // New locations only: an existing installation is never re-judged.
    if (![fm fileExistsAtPath:marker]) supportedVolume([fm fileExistsAtPath:root] ? root : parent);
    mkdirs(root);
    struct stat st;
    if (lstat(root.fileSystemRepresentation,&st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid()) fail(@"directory_not_owned_by_user");
    if (chmod(root.fileSystemRepresentation,0700)) fail(@"private_directory_permissions_failed");
    int markerFD = open(marker.fileSystemRepresentation,O_RDWR|O_CREAT|O_NOFOLLOW,0600);
    if (markerFD < 0) fail(@"invalid_ownership_marker");
    char bytes[32] = {0}; ssize_t n=read(markerFD,bytes,sizeof(bytes));
    if (n==0) { if(write(markerFD,"ow2-native-setup-v1\n",20)!=20) {close(markerFD);fail(@"ownership_write_failed");} }
    else if(n!=20 || memcmp(bytes,"ow2-native-setup-v1\n",20)) {close(markerFD);fail(@"invalid_ownership_marker");}
    close(markerFD);
    lockFD=open(join(root,@"setup.lock").fileSystemRepresentation,O_CREAT|O_RDWR|O_NOFOLLOW,0600);
    if(lockFD<0)fail(@"setup_lock_failed");
    // A launch's new monitor briefly owns this lock before handing off to its own.
    // Wait here, BEFORE dispatch: retrying a whole launch after it started could
    // open another client. Keep app operations bounded and cancellation responsive.
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+(monitorMode ? 180.0 : 5.0);
    BOOL announced=NO;
    while(YES) {
        if(cancelRequested)fail(@"cancelled");
        if(flock(lockFD,LOCK_EX|LOCK_NB)==0)break;
        if(errno!=EWOULDBLOCK && errno!=EAGAIN && errno!=EINTR)fail(@"setup_lock_failed");
        if(NSProcessInfo.processInfo.systemUptime>=deadline)fail(@"setup_already_running");
        if(!announced) {event(@"waiting_for_setup",nil);announced=YES;}
        [NSThread sleepForTimeInterval:0.05];
    }
    if(cancelRequested)fail(@"cancelled");
    for (NSString *directory in @[@"runtimes",@"downloads",@"logs",@"home",@"tmp",@"cache"])
        mkdirs(join(root,directory));
}
static NSMutableDictionary *state(void) {
    NSString *p=join(root,@"state.json");
    return [fm fileExistsAtPath:p] ? [readJSON(p) mutableCopy] : [@{@"schema":@1,@"stage":@"not_installed"} mutableCopy];
}
static void saveStage(NSString *stage) {
    NSMutableDictionary *s=state();s[@"stage"]=stage;writeJSON(s,join(root,@"state.json"));event(stage,nil);
}
static NSString *runtime(void) {
    NSString *version=state()[@"active_runtime"];
    if(!matches(version,@"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) fail(@"runtime_not_installed");
    NSString *p=join(join(root,@"runtimes"),version);
    if (![fm fileExistsAtPath:join(p,@"runtime.json")]) fail(@"runtime_missing");
    return p;
}
static NSMutableDictionary *wineEnv(NSString *engine) {
    // Keep Wine's Windows profile and shell-folder symlinks inside this new
    // environment. Never borrow the developer's HOME, account state or caches.
    // The contract's CX_HACK_FILESYSTEM_TYPE (CrossOver's GetVolumeInformationW hack) drops
    // FILE_PERSISTENT_ACLS: Wine rebuilds ACLs from Unix modes, so Battle.net's folder check
    // failed on every start and marked Overwatch not playable (2123) until an update ran (REC-6).
    NSMutableDictionary *env=[candidateEnvironment() mutableCopy];
    [env addEntriesFromDictionary:@{@"PATH":@"/usr/bin:/bin:/usr/sbin:/sbin",@"HOME":join(root,@"home"),@"USER":@"player",
        @"TMPDIR":join(root,@"tmp"),@"WINEPREFIX":join(root,@"environment"),@"WINEARCH":@"win64",
        @"WINESERVER":join(engine,@"bin/wineserver"),@"WINELOADER":join(engine,@"bin/wine"),
        @"WINEDEBUG":@"-all",
        @"CX_APPLEGPTK_LIBD3DSHARED_PATH":join(engine,@"lib/external/libd3dshared.dylib"),
        @"DXMT_SHADER_CACHE_PATH":join(root,@"cache/shaders"),@"DXMT_LOG_LEVEL":@"error",@"DXMT_LOG_PATH":@"none",
        @"DXMT_CONFIG_FILE":[@"Z:" stringByAppendingString:[([fm fileExistsAtPath:join(root,@"dxmt.conf")]?join(root,@"dxmt.conf"):join(engine,@"config/dxmt.conf")) stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]],
        @"DXMT_PIPELINE_CACHE_PATH":join(root,@"cache/pipelines")}];
    return env;
}
static NSTask *task(NSString *executable, NSArray *args, NSDictionary *env, NSString *logname) {
    NSTask *p=[NSTask new];p.executableURL=[NSURL fileURLWithPath:executable];p.arguments=args;
    if(env)p.environment=env;
    p.currentDirectoryURL=[NSURL fileURLWithPath:root];
    NSString *log=join(join(root,@"logs"),logname);
    if(![fm fileExistsAtPath:log]) [fm createFileAtPath:log contents:nil attributes:@{NSFilePosixPermissions:@0600}];
    NSFileHandle *out=[NSFileHandle fileHandleForWritingAtPath:log];[out truncateFileAtOffset:0];
    p.standardOutput=out;p.standardError=out;
    if(![p launchAndReturnError:nil]) fail(@"process_launch_failed");
    return p;
}
// tick, if any, runs while the task does and once after it exits.
static int waitTaskTicking(NSTask *p, double seconds, void (^tick)(void)) {
    childPID=p.processIdentifier;
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while(p.running && deadline.timeIntervalSinceNow>0 && !cancelRequested) {[NSThread sleepForTimeInterval:0.05];if(tick)tick();}
    if(p.running) {
        kill(p.processIdentifier,SIGTERM);
        NSDate *grace=[NSDate dateWithTimeIntervalSinceNow:2];
        while(p.running && grace.timeIntervalSinceNow>0) [NSThread sleepForTimeInterval:0.05];
        if(p.running)kill(p.processIdentifier,SIGKILL);
        [p waitUntilExit];childPID=0;if(cancelRequested)fail(@"cancelled");return 124;
    }
    [p waitUntilExit];childPID=0;if(tick)tick();if(cancelRequested)fail(@"cancelled");return p.terminationStatus;
}
static int waitTask(NSTask *p, double seconds) { return waitTaskTicking(p,seconds,nil); }
static BOOL busy(NSString *engine) {
    if(![fm fileExistsAtPath:join(root,@"environment")]) return NO;
    NSTask *p=task(join(engine,@"bin/wineserver"),@[@"-w"],wineEnv(engine),@"server-check.log");
    // A newly signed x86_64 server may need first-launch Rosetta translation.
    // A subsecond deadline falsely classified that startup as a running game.
    int result=waitTask(p,5);
    if(result!=0 && result!=124)fail(@"server_check_failed");
    return result==124;
}
#include "portable_logs.h"
#include "portable_session.h"
#include "portable_retina.h"
#include "portable_preferences.h"
#include "portable_voice.h"
#include "portable_network.h"
#include "portable_region.h"
#include "portable_korea.h"
#include "portable_metalfx.h"
#include "portable_diagnostics.h"
// Tests build the worker with a probe that fails, as on a Mac without Rosetta.
#ifndef ROSETTA_PROBE
#define ROSETTA_PROBE @"/usr/bin/arch"
#endif
// Battle.net, Overwatch and Wine are Intel programs. Upgrading to macOS 27 doesn't keep
// Rosetta (issue #15), so launches check too, before anything starts Wine.
static void requireRosetta(void) {
    if(waitTask(task(ROSETTA_PROBE,@[@"-x86_64",@"/usr/bin/true"],nil,@"rosetta-check.log"),10))fail(@"rosetta_required");
}
static void preflight(void) {
    int silicon=0;size_t size=sizeof(silicon);
    sysctlbyname("hw.optional.arm64",&silicon,&size,NULL,0);
    if(!silicon)fail(@"apple_silicon_required");
    // Overwatch needs Rosetta's fixes in macOS 26.5; on older macOS it hangs before its window opens.
    if(![NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){26,5,0}])fail(@"macos_26_5_required");
    requireRosetta();
    event(@"preflight_ok",@{@"free_bytes":@(freeBytes()),@"runtime_headroom_bytes":@(6ULL<<30)});
}
static NSString *download(NSString *url, NSString *expected) {
    if(!matches(expected,@"^[a-f0-9]{64}$"))fail(@"invalid_download_hash");
    NSURL *u=[NSURL URLWithString:url];
    if(![u.scheme isEqual:@"https"] || !u.host.length || u.user || u.password)fail(@"https_download_required");
    NSString *dest=join(join(root,@"downloads"),expected);
    if([fm fileExistsAtPath:dest]) {
        if(![hashFile(dest) isEqual:expected])fail(@"cached_download_hash_mismatch");return dest;
    }
    space(3ULL<<30);
    NSString *part=[dest stringByAppendingString:@".part"];
    struct stat st;
    if(!lstat(part.fileSystemRepresentation,&st) && !S_ISREG(st.st_mode))fail(@"unsafe_partial_download");
    event(@"downloading",nil);
    NSArray *args=@[@"--fail",@"--location",@"--proto",@"=https",@"--proto-redir",@"=https",
        @"--retry",@"2",@"--connect-timeout",@"20",@"--max-time",@"1800",@"--max-filesize",@"4294967296",
        @"--continue-at",@"-",@"--output",part,url];
    int code=waitTask(task(@"/usr/bin/curl",args,nil,@"download.log"),1810);
    if(code==33 || code==36) {
        [fm removeItemAtPath:part error:nil];
        code=waitTask(task(@"/usr/bin/curl",args,nil,@"download.log"),1810);
    }
    if(code)fail(@"download_interrupted_retry_to_resume");
    if(![hashFile(part) isEqual:expected]) { [fm removeItemAtPath:part error:nil];fail(@"download_hash_mismatch"); }
    if(![fm moveItemAtPath:part toPath:dest error:nil])fail(@"download_commit_failed");
    event(@"download_verified",nil);return dest;
}
static void extract(NSString *archivePath, NSString *destination) {
    struct archive *a=archive_read_new();archive_read_support_filter_gzip(a);archive_read_support_format_tar(a);
    if(archive_read_open_filename(a,archivePath.fileSystemRepresentation,131072)!=ARCHIVE_OK)fail(@"archive_open_failed");
    NSMutableSet *seen=[NSMutableSet set];NSMutableArray *links=[NSMutableArray array];
    struct archive_entry *entry;uint64_t total=0;int result;
    @try {
        while((result=archive_read_next_header(a,&entry))==ARCHIVE_OK) {
            if(cancelRequested)fail(@"cancelled");
            NSString *name=[NSString stringWithUTF8String:archive_entry_pathname(entry)];
            if([name hasSuffix:@"/"])name=[name substringToIndex:name.length-1];
            if(!safePath(name) || [seen containsObject:name.lowercaseString] || seen.count>20000)fail(@"unsafe_archive_path");
            [seen addObject:name.lowercaseString];
            if(archive_entry_hardlink(entry))fail(@"archive_hardlink_rejected");
            mode_t type=archive_entry_filetype(entry);NSString *dest=join(destination,name);
            if(type==AE_IFLNK) {
                const char *raw=archive_entry_symlink(entry);NSString *link=raw?[NSString stringWithUTF8String:raw]:nil;
                if(!link.length || [link hasPrefix:@"/"] || [link containsString:@"\\"])fail(@"unsafe_archive_symlink");
                NSString *resolved=[[name.stringByDeletingLastPathComponent stringByAppendingPathComponent:link] stringByStandardizingPath];
                if(!safePath(resolved))fail(@"archive_symlink_escapes_runtime");
                [links addObject:@[dest,link]];continue;
            }
            if(type!=AE_IFREG && type!=AE_IFDIR)fail(@"archive_special_file_rejected");
            mkdirs(dest.stringByDeletingLastPathComponent);
            if(type==AE_IFDIR) {mkdirs(dest);continue;}
            la_int64_t length=archive_entry_size(entry);
            if(length<0 || length>(2LL<<30) || total+(uint64_t)length>(8ULL<<30))fail(@"archive_size_limit");
            total+=(uint64_t)length;
            int fd=open(dest.fileSystemRepresentation,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,
                        archive_entry_perm(entry)&0111 ? 0755:0644);
            if(fd<0)fail(@"archive_file_creation_failed");
            char buffer[131072];la_ssize_t n;uint64_t wrote=0;
            while((n=archive_read_data(a,buffer,sizeof(buffer)))>0) {
                ssize_t offset=0;
                while(offset<n) {ssize_t count=write(fd,buffer+offset,(size_t)(n-offset));if(count<=0){close(fd);fail(@"archive_write_failed");}offset+=count;}
                wrote+=(uint64_t)n;
            }
            close(fd);if(n<0 || wrote!=(uint64_t)length)fail(@"archive_truncated");
        }
        if(result!=ARCHIVE_EOF)fail(@"archive_corrupt");
        // No symlink can be traversed during extraction: create all of them last.
        for(NSArray *link in links) {
            NSString *parent=[link[0] stringByDeletingLastPathComponent];
            NSString *relative=[parent substringFromIndex:destination.length];
            NSString *cursor=destination;
            for(NSString *part in [relative componentsSeparatedByString:@"/"]) {
                if(!part.length)continue;cursor=join(cursor,part);struct stat st;
                if(!lstat(cursor.fileSystemRepresentation,&st) && !S_ISDIR(st.st_mode))fail(@"archive_symlink_parent_rejected");
                mkdirs(cursor);
            }
            if(symlink([link[1] fileSystemRepresentation],[link[0] fileSystemRepresentation]))fail(@"archive_symlink_failed");
        }
        for(NSArray *link in links) {
            NSString *resolved=[link[0] stringByResolvingSymlinksInPath];
            if(![resolved hasPrefix:[destination stringByAppendingString:@"/"]])fail(@"archive_symlink_escapes_runtime");
        }
    } @finally {archive_read_free(a);}
}
static void verifyRuntime(NSString *engine, NSString *version) {
    NSDictionary *manifest=readJSON(join(engine,@"runtime.json"));
    if(![manifest[@"version"] isEqual:version] || ![manifest[@"files"] isKindOfClass:NSDictionary.class])fail(@"runtime_identity_mismatch");
    NSDictionary *files=manifest[@"files"];
    for(NSString *name in files) {
        if(cancelRequested)fail(@"cancelled");
        if(!safePath(name))fail(@"unsafe_manifest_path");
        NSDictionary *spec=files[name];NSString *p=join(engine,name);struct stat st;
        if(lstat(p.fileSystemRepresentation,&st))fail(@"runtime_file_missing");
        if(spec[@"symlink"]) {
            if(!S_ISLNK(st.st_mode) || ![[fm destinationOfSymbolicLinkAtPath:p error:nil] isEqual:spec[@"symlink"]])fail(@"runtime_link_mismatch");
        } else if(!S_ISREG(st.st_mode) || ![hashFile(p) isEqual:spec[@"sha256"]])fail(@"runtime_file_hash_mismatch");
    }
    NSDirectoryEnumerator *enumerator=[fm enumeratorAtPath:engine];NSString *name;
    while((name=[enumerator nextObject])) {
        struct stat st;if(lstat(join(engine,name).fileSystemRepresentation,&st))fail(@"runtime_file_missing");
        // Finder writes .DS_Store into any folder a user opens; nothing loads it.
        if(S_ISREG(st.st_mode) && [name.lastPathComponent isEqual:@".DS_Store"])continue;
        if(!S_ISDIR(st.st_mode) && ![name isEqual:@"runtime.json"] && !files[name])fail(@"runtime_unlisted_file");
    }
    for(NSString *required in @[@"bin/wine",@"bin/wineserver",@"config/dxmt.conf",@"lib/external/libd3dshared.dylib",
                              @"lib/wine/x86_64-unix/winemetal.so",@"lib/wine/x86_64-unix/winemac.so"])
        if(!files[required])fail(@"runtime_required_component_missing");
    for(NSString *architecture in @[@"x86_64-windows",@"i386-windows"])
        for(NSString *module in @[@"winemac.drv",@"mountmgr.sys",@"nsiproxy.sys",@"kernel32.dll",@"ntdll.dll"])
            if(!files[join(join(@"lib/wine",architecture),module)])fail(@"runtime_required_component_missing");
}
// Each update leaves the runtime it replaced (~0.7 GB). Keep the active and the
// previous one; older runtimes this worker installed are removed.
static void pruneRuntimes(NSString *active, NSString *previous) {
    NSString *directory=join(root,@"runtimes");
    for(NSString *name in [fm contentsOfDirectoryAtPath:directory error:nil]) {
        if([name isEqual:active] || [name isEqual:previous] || !matches(name,@"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"))continue;
        NSString *path=join(directory,name);struct stat st;
        if(lstat(path.fileSystemRepresentation,&st) || !S_ISDIR(st.st_mode) || ![fm fileExistsAtPath:join(path,@"runtime.json")])continue;
        [fm removeItemAtPath:path error:nil];
    }
}
static void installRuntime(NSString *archivePath, NSString *expected, NSString *version, BOOL repair) {
    if(!matches(version,@"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$") || !matches(expected,@"^[a-f0-9]{64}$"))fail(@"invalid_runtime_identity");
    if(state()[@"active_runtime"] && busy(runtime()))fail(@"close_game_before_maintenance");
    if(![hashFile(archivePath) isEqual:expected])fail(@"archive_hash_mismatch");
    space(6ULL<<30);
    NSString *target=join(join(root,@"runtimes"),version),*stage=join(root,@"incoming-runtime");
    saveStage(@"installing_runtime");
    if([fm fileExistsAtPath:target] && !repair)verifyRuntime(target,version);
    else {
        // Repair extracts a fresh copy from the app's archive and swaps it in;
        // the replaced copy is removed only after the new one verified.
        if([fm fileExistsAtPath:stage] && ![fm removeItemAtPath:stage error:nil])fail(@"staging_cleanup_failed");
        mkdirs(stage);extract(archivePath,stage);verifyRuntime(stage,version);
        NSString *replaced=join(root,@"replaced-runtime");
        if([fm fileExistsAtPath:replaced] && ![fm removeItemAtPath:replaced error:nil])fail(@"staging_cleanup_failed");
        if([fm fileExistsAtPath:target] && ![fm moveItemAtPath:target toPath:replaced error:nil])fail(@"runtime_commit_failed");
        if(![fm moveItemAtPath:stage toPath:target error:nil])fail(@"runtime_commit_failed");
        [fm removeItemAtPath:replaced error:nil];
    }
    NSMutableDictionary *s=state();NSString *previous=s[@"active_runtime"];
    if(previous && ![previous isEqual:version])s[@"previous_runtime"]=previous;
    if(repair)[s removeObjectForKey:@"prepared_runtime"];
    s[@"active_runtime"]=version;s[@"stage"]=@"runtime_ready";writeJSON(s,join(root,@"state.json"));
    pruneRuntimes(version,s[@"previous_runtime"]);
    event(@"runtime_ready",@{@"version":version});
}
static void prepare(void) {
    preflight();NSString *engine=runtime();verifyRuntime(engine,state()[@"active_runtime"]);
    if(busy(engine))fail(@"close_game_before_setup");space(3ULL<<30);
    NSString *prefix=join(root,@"environment");
    NSString *marker=join(root,@"environment-owned.json");
    if([fm fileExistsAtPath:prefix] && ![fm fileExistsAtPath:marker])fail(@"existing_environment_not_owned");
    if(![fm fileExistsAtPath:marker])writeJSON(@{@"schema":@1,@"runtime":state()[@"active_runtime"]},marker);
    saveStage(@"preparing_environment");ownedPreparation=YES;
    // Update registry/drivers without running installed clients' login startup
    // entries. Battle.net must be opened by launchClient with its CEF options.
    if(waitTask(task(join(engine,@"bin/wine"),@[@"wineboot.exe",@"-u",@"-r"],wineEnv(engine),@"wineboot.log"),180))fail(@"environment_initialization_failed");
    if(waitTask(task(join(engine,@"bin/wineserver"),@[@"-w"],wineEnv(engine),@"wineboot-wait.log"),60))fail(@"environment_initialization_busy");
    if(![fm fileExistsAtPath:join(prefix,@"system.reg")])fail(@"environment_registry_missing");
    configureRetina();
    // The player's network and Korean account choices (portable_network.h, portable_korea.h),
    // the fonts for Chinese or Korean (portable_region.h) and Overwatch's left Option key
    // (portable_network.h), before Battle.net's installer first goes online. The Korean
    // certificate is required when chosen: stop here if it cannot be installed.
    configureProxy(engine,proxyDetectionChosen());
    configureOptionKey(engine);
    if(koreanSupportChosen() && !configureKoreanCertificate(engine,YES,YES))fail(@"korean_support_failed");
    if(cjkFontsChosen())configureFonts(engine,YES);
    if(!registrySaved(engine,60))fail(@"environment_initialization_busy");
    // An update keeps a resolution chosen in the game since the last launch.
    NSInteger width,height;NSString *source;nextResolution(&width,&height,&source,YES);
    configureDisplay(width,height,[source isEqual:@"game_reset"] ? DisplayModeRemembered : DisplayModeKept);
    NSMutableDictionary *s=state();s[@"prepared_runtime"]=s[@"active_runtime"];writeJSON(s,join(root,@"state.json"));
    saveStage(@"environment_ready");ownedPreparation=NO;
}
static NSMutableDictionary *battleNetSize(NSMutableDictionary *env, NSString *installer);
static void installClient(NSString *installer, NSString *expected) {
    requireRosetta();
    NSString *engine=runtime();if(busy(engine))fail(@"close_game_before_setup");
    if(![fm fileExistsAtPath:join(root,@"environment/system.reg")])fail(@"prepare_environment_first");
    if(!matches(expected,@"^[a-f0-9]{64}$") || ![hashFile(installer) isEqual:expected])fail(@"client_installer_hash_mismatch");
    // The installer's update Agent is what stalled at 45% (portable_network.h). The installer
    // shows the chosen language from its first window, fonts included (portable_region.h).
    configureProxy(engine,proxyDetectionChosen());
    if(cjkFontsChosen())configureFonts(engine,YES);
    saveStage(@"installing_battlenet");
    NSTask *p=task(join(engine,@"bin/wine"),@[installer,[@"--lang=" stringByAppendingString:battleNetLanguage()]],battleNetSize(wineEnv(engine),installer),@"battlenet-installer.log");
    event(@"battlenet_installer_open",@{@"pid":@(p.processIdentifier)});
}
static NSString *helperPath(NSString *name) {
    return join([NSProcessInfo.processInfo.arguments[0] stringByDeletingLastPathComponent],name);
}
/* Preparing the archive of learned pipelines takes minutes, so it happens after a match:
 * the session's monitor (watch) stays until the game has closed and runs ow2-pipeline
 * --after-session; a launch only keeps what was learned. Meanwhile the monitor's pid is
 * in cache/after-session.pid, and a launch stops it first. The helper stops its tool and
 * keeps the cache it had; the next session's monitor prepares again. Since 1.4 every learned
 * pipeline is prepared, in batches published one at a time, so a first preparation can run
 * long: it has hours, and what a stopped one finished stays. */
static NSString *afterSessionPath(void) { return join(root,@"cache/after-session.pid"); }
// A session's monitor names itself here while it runs (from 1.4).
static NSString *monitorPath(void) { return join(root,@"cache/monitor.pid"); }
// The pid a file names, if it is one of this app's workers (not a pid since reused).
static pid_t setupProcess(NSString *file) {
    pid_t pid=[[NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil] intValue];
    char path[PROC_PIDPATHINFO_MAXSIZE];
    return pid>0 && pid!=getpid() && proc_pidpath(pid,path,sizeof(path))>0 && [@(path) hasSuffix:@"/ow2-setup"] ? pid : 0;
}
static void stopAfterSession(void) {
    int fd=open(join(root,@"launch-monitor.lock").fileSystemRepresentation,O_CREAT|O_RDWR|O_NOFOLLOW,0600);
    if(fd<0)return;
    // A monitor holds this lock for as long as it runs.
    pid_t pid=[[NSString stringWithContentsOfFile:afterSessionPath() encoding:NSUTF8StringEncoding error:nil] intValue];
    if(flock(fd,LOCK_EX|LOCK_NB)==0 || pid<=0 || pid==getpid()) {close(fd);return;}
    kill(pid,SIGTERM);
    for(int i=0;i<600 && flock(fd,LOCK_EX|LOCK_NB);i++)[NSThread sleepForTimeInterval:0.05];
    close(fd);
}
/* prepare-shaders: a monitor waiting for a match is ended; the one prepare-shaders starts
 * prepares now, then watches the session in its place. One already preparing is left to
 * finish (NO). A monitor from before 1.4 names no pid; it ends two minutes after Battle.net
 * closes, and the new one waits that long for its lock (watchClient). */
static BOOL stopMonitor(void) {
    int fd=open(join(root,@"launch-monitor.lock").fileSystemRepresentation,O_CREAT|O_RDWR|O_NOFOLLOW,0600);
    if(fd<0)return YES;
    if(flock(fd,LOCK_EX|LOCK_NB)==0) {close(fd);return YES;}
    if(setupProcess(afterSessionPath())) {close(fd);return NO;}
    pid_t pid=setupProcess(monitorPath());
    if(pid>0)kill(pid,SIGTERM);
    for(int i=0;i<600 && pid>0 && flock(fd,LOCK_EX|LOCK_NB);i++)[NSThread sleepForTimeInterval:0.05];
    close(fd);return YES;
}
// The program Overwatch runs as: the engine's game app with Game Mode, Wine's own loader
// without (Settings › Graphics, REC-51). macOS keeps compiled shaders for each separately.
static NSString *gameProgram(NSString *engine, BOOL gameMode) {
    NSString *gameApp=join(engine,@"lib/wine/game-mode/Overwatch.app");
    if(gameMode && [fm fileExistsAtPath:join(gameApp,@"Contents/Info.plist")])return gameApp;
    NSString *loader=join(engine,@"lib/wine/x86_64-unix/wine");
    return [fm isExecutableFileAtPath:loader] ? loader : nil;
}
// The session's monitor, told which program Overwatch runs as (gameProgram): preparation after
// the match also warms that program's own shader cache with every learned pipeline. A launch's
// monitor also gets the Battle.net start whose record it keeps (portable_logs.h).
static NSArray *watchArguments(NSString *engine, BOOL gameMode, NSString *session) {
    NSString *program=gameProgram(engine,gameMode);
    NSArray *arguments=program ? @[@"watch",@"--root",root,@"--game-app",program] : @[@"watch",@"--root",root];
    return validSessionName(session) ? [arguments arrayByAddingObjectsFromArray:@[@"--session",session]] : arguments;
}
static void prepareAfterSession(void) {
    NSString *pipeline=helperPath(@"ow2-pipeline");
    if(![fm isExecutableFileAtPath:pipeline])return;
    [fm createDirectoryAtPath:join(root,@"cache") withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSString stringWithFormat:@"%d",getpid()] writeToFile:afterSessionPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    BOOL (^gameRunning)(void)=^BOOL{ for(NSDictionary *p in sessionProcesses())if([p[@"kind"] isEqual:@"game"])return YES;return NO; };
    NSDate *checked=[NSDate distantPast];
    // The game holds the cache's write lock until its process ends: 75 means try again.
    for(int attempt=0;attempt<8 && !cancelRequested;) {
        if(-checked.timeIntervalSinceNow<10) {[NSThread sleepForTimeInterval:0.25];continue;}
        checked=[NSDate date];
        if(gameRunning())continue;
        recordGameEnded(monitorSession);
        NSTask *p=task(pipeline,monitorGameApp ? @[@"--after-session",root,monitorGameApp] : @[@"--after-session",root],nil,@"pipeline-after-session.log");
        childPID=p.processIdentifier;
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:4*3600];
        while(p.running && !cancelRequested && deadline.timeIntervalSinceNow>0) {
            [NSThread sleepForTimeInterval:0.25];
            // A game started from Battle.net meanwhile must find the cache free.
            if(-checked.timeIntervalSinceNow>=5) {checked=[NSDate date];if(gameRunning())break;}
        }
        if(p.running) {
            kill(p.processIdentifier,SIGTERM);
            NSDate *grace=[NSDate dateWithTimeIntervalSinceNow:20];
            while(p.running && grace.timeIntervalSinceNow>0)[NSThread sleepForTimeInterval:0.05];
            if(p.running)kill(p.processIdentifier,SIGKILL);
        }
        [p waitUntilExit];childPID=0;
        event(@"pipeline_after_session",@{@"code":@(p.terminationStatus)});
        if(p.terminationStatus!=75)break;
        attempt++;
    }
    [fm removeItemAtPath:afterSessionPath() error:nil];
    [fm removeItemAtPath:join(root,@"cache/shader-update") error:nil];
}
static void closeClient(NSString *gameRunning);
// Ends whatever is left of the Wine session (the update Agent, Wine's own services).
static void endSession(NSString *engine) {
    waitTask(task(join(engine,@"bin/wineserver"),@[@"-k"],wineEnv(engine),@"session-end.log"),15);
    if(waitTask(task(join(engine,@"bin/wineserver"),@[@"-w"],wineEnv(engine),@"session-end-wait.log"),15))fail(@"client_close_failed");
}
/* Battle.net (Qt around Chromium) lays itself out for the DPI Windows reports. Wine's
 * Retina mode (configureRetina) is one switch for every display: while the main display
 * keeps the mode it had when the session started, which a Recall session always does
 * (displays changing restart it), each Windows pixel is half a point on every display, a
 * 1x monitor included (Wine sees a 2560x1440 monitor as 5120x2880). At Windows' 96 DPI
 * Battle.net came out half size everywhere. Windows' answer is 200% (192 DPI), but Wine
 * keeps one DPI for every program in a session, Overwatch included. The engine's
 * WINE_APP_DPI (patches/wine-win32u-display-log.patch) gives a DPI to the programs it
 * names only: Battle.net's, at 192, so on any display Battle.net has its Windows size in
 * points. Overwatch, which Battle.net starts with this environment, is not named and sees
 * 96 as before; Wine's shared record of the displays keeps 96 (tests/run_dpi_probe.py).
 * Setup names the installer too, by its file name. launch --battlenet-scale 1 keeps
 * Windows' size. A session without Retina mode (a main display that isn't Retina,
 * portable_retina.h) has a Windows pixel a point already: Battle.net keeps Windows' 96. */
static NSMutableDictionary *battleNetSize(NSMutableDictionary *env, NSString *installer) {
    if(wineScale()==1)return env;
    NSMutableArray *names=[@[@"Battle.net.exe",@"Battle.net Launcher.exe",@"BlizzardError.exe"] mutableCopy];
    if(installer)[names addObject:installer.lastPathComponent];
    env[@"WINE_APP_DPI"]=[@"192:" stringByAppendingString:[names componentsJoinedByString:@";"]];
    return env;
}
/* Apple's Metal Performance HUD (Settings, launch --metal-hud 1) reaches Overwatch the
 * same way: Battle.net starts the game with its own environment. MTL_HUD_ELEMENTS lists
 * the HUD's default panel ("gamemode" is undocumented) plus the shader compiler, which
 * shows the game compiling shaders, the cause of a first match's stutters. Battle.net
 * draws on the CPU (SwiftShader), so it has no Metal layer for the HUD.
 * macOS Game Mode: the contract's WINE_GAME_MODE makes Wine start Overwatch from the
 * engine's game app (lib/wine/game-mode/Overwatch.app). launch --game-mode 0 leaves it out,
 * so the game starts from Wine's own loader, as before 1.1; the app passes it when its Game Mode
 * switch is off (Settings › Graphics, off by default from 1.6; REC-51).
 * Korean account support (Settings › Advanced, portable_korea.h) reaches the game the same
 * way: WINEMAC_SCREEN_READBACK=1 has Wine's Mac driver answer screen reads with a black
 * image, so the anti-cheat's screenshots no longer crash the game.
 * So does MetalFX upscaling (Settings, launch --metalfx 1; portable_metalfx.h): the contract's
 * MetalFX environment.
 * And the mouse (Settings › General › Mouse, launch --mouse; REC-52, REC-57). Standard keeps the
 * contract's input variant ("precise", 1.5's). Classic sets the window driver's "classic", 1.4's
 * clicks and timing with 1.5's stand-in. High-precision sets WINEMAC_RAW_SOURCE=hid: the driver
 * reads the mouse's own reports through IOHID instead of GCMouse, with Recall's Input Monitoring
 * permission; without it the driver keeps GCMouse.
 * With Standard and High-precision, launch --mouse-rate (Mouse › Advanced; REC-63) sets the most
 * deliveries a second: the driver's WINEMAC_MOUSELOOK_RAW_INTERVAL_US, 0 for every report (the
 * default, and anything unknown) or a million over 2000, 1000, 500 or 250. Classic leaves the
 * driver's own 1 ms, its 1.4 timing. */
static NSString *mouseInput=@"standard",*mouseRate=@"all";
static NSString *mouseIntervalMicroseconds(void) {
    return [mouseRate isEqual:@"all"] ? @"0" : [NSString stringWithFormat:@"%d",1000000/mouseRate.intValue];
}
static NSMutableDictionary *clientEnvironment(NSMutableDictionary *env, BOOL sized, BOOL hud, BOOL gameMode, BOOL metalfx) {
    if(sized)battleNetSize(env,nil);
    if(metalfx)[env addEntriesFromDictionary:candidateMetalFXEnvironment()];
    if([mouseInput isEqual:@"classic"])env[@"WINEMAC_INPUT_VARIANT"]=@"classic";
    else {
        if([mouseInput isEqual:@"high-precision"])env[@"WINEMAC_RAW_SOURCE"]=@"hid";
        env[@"WINEMAC_MOUSELOOK_RAW_INTERVAL_US"]=mouseIntervalMicroseconds();
    }
    if(koreanSupportChosen())env[@"WINEMAC_SCREEN_READBACK"]=@"1";
    if(!gameMode)[env removeObjectForKey:@"WINE_GAME_MODE"];
    if(hud)[env addEntriesFromDictionary:@{@"MTL_HUD_ENABLED":@"1",@"MTL_HUD_DISABLE_MENU_BAR":@"1",
        @"MTL_HUD_ELEMENTS":@"device,rosetta,layersize,memory,gamemode,fps,gputime,frameinterval,frameintervalgraph,shaders"}];
    return env;
}
/* The pipeline helper prints progress lines ({"graphics":phase,...}) among its log
 * lines. While it runs they become graphics events for the launcher's "Preparing
 * graphics" details. Only known fields pass, bounded; the rest stays in the log. */
static NSDictionary *graphicsProgress(NSData *line) {
    NSDictionary *value=[NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
    if(![value isKindOfClass:NSDictionary.class] || ![value[@"graphics"] isKindOfClass:NSString.class])return nil;
    NSString *phase=value[@"graphics"];
    if(![@[@"kept",@"learned",@"warming",@"checking",@"preparing",@"pipelines",@"verifying",@"done"] containsObject:phase])return nil;
    NSMutableDictionary *result=[@{@"phase":phase} mutableCopy];
    for(NSString *key in @[@"folders",@"added",@"learned",@"ready",@"target",@"warmed"]) {
        NSNumber *number=value[key];
        if([number isKindOfClass:NSNumber.class] && number.longLongValue>=0 && number.longLongValue<=1000000)result[key]=@(number.longLongValue);
    }
    NSArray *items=value[@"items"];
    if([phase isEqual:@"pipelines"] && [items isKindOfClass:NSArray.class]) {
        NSMutableArray *kept=[NSMutableArray array];
        for(NSArray *item in [items subarrayWithRange:NSMakeRange(0,MIN(items.count,(NSUInteger)400))]) {
            if(![item isKindOfClass:NSArray.class] || item.count!=3 || ![item[0] isKindOfClass:NSString.class] || !matches(item[0],@"^[0-9a-f]{12}$")
               || ![item[1] isKindOfClass:NSNumber.class] || ![item[2] isKindOfClass:NSNumber.class])continue;
            double ms=[item[1] doubleValue];
            if(ms>=0 && ms<=600000)[kept addObject:@[item[0],@(ms),@([item[2] boolValue])]];
        }
        result[@"items"]=kept;
    }
    return result;
}
static void (^graphicsFeed(NSString *log))(void) {
    __block unsigned long long offset=0;NSMutableData *pending=[NSMutableData data];
    return ^{
        NSFileHandle *in=[NSFileHandle fileHandleForReadingAtPath:log];if(!in)return;
        [in seekToFileOffset:offset];NSData *data=[in readDataToEndOfFile];[in closeFile];
        offset+=data.length;[pending appendData:data];
        for(;;) {
            NSRange end=[pending rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0,pending.length)];
            if(end.location==NSNotFound) {if(pending.length>(1<<20))[pending setLength:0];break;}
            NSData *line=[pending subdataWithRange:NSMakeRange(0,end.location)];
            [pending replaceBytesInRange:NSMakeRange(0,end.location+1) withBytes:NULL length:0];
            NSDictionary *value=line.length && ((const char *)line.bytes)[0]=='{' ? graphicsProgress(line) : nil;
            if(value)event(@"graphics",value);
        }
    };
}
/* Settings › Graphics › Shader memory: how much of the shader pack Overwatch loads when it
 * starts. pipeline_cache.c reads cache/pipelines/load.json as the game starts: "all", "first"
 * (the first part only: the slowest pipelines, as earlier versions loaded) or a number of MiB.
 * All of it on every Mac unless the player chose less (the owner's call, 2026-10-14: players
 * on 8 GB Macs play at low settings and can lower it themselves). */
static BOOL validShaderMemory(id value) {
    return [value isKindOfClass:NSString.class] && ([value isEqual:@"all"] || [value isEqual:@"first"] || matches(value,@"^[1-9][0-9]{0,6}$"));
}
static NSString *shaderMemoryChoice(void) {
    NSString *saved=state()[@"shader_memory"];
    return validShaderMemory(saved) ? saved : @"all";
}
static void applyShaderMemory(void) {
    NSString *choice=shaderMemoryChoice(),*folder=join(root,@"cache/pipelines");
    mkdirs(folder);
    id limit=[choice isEqual:@"all"] || [choice isEqual:@"first"] ? choice : @(choice.longLongValue);
    writeJSON(@{@"schema":@1,@"limit":limit},join(folder,@"load.json"));
}
/* Settings › Graphics › Clear Shader Cache (from @dagadtwok's pull request, #37): everything
 * Recall keeps of Overwatch's shaders, so each one builds again from scratch: DXMT's translated
 * shaders (cache/shaders), the learned and prepared pipelines (cache/pipelines) with the helper's
 * records of them, and macOS's own compiled-shader cache for the engine's game app, which the
 * helper warms for Game Mode. Battle.net and Overwatch must be closed: the game holds the caches
 * while it runs, and a Battle.net left open would start it on half of them. A preparation after
 * a match writes the same archives, so it blocks this too; a monitor only waiting is ended. The
 * Shader memory choice is kept, and load.json is written again for the next launch. */
static NSString *gameAppShaderCache(void) {
    if(!state()[@"active_runtime"])return nil;
    NSDictionary *info=[NSDictionary dictionaryWithContentsOfFile:join(runtime(),@"lib/wine/game-mode/Overwatch.app/Contents/Info.plist")];
    NSString *identifier=info[@"CFBundleIdentifier"];
    char caches[PATH_MAX];
    // Only the engine's own game app: never another app's cache, nor macOS's shared one.
    if(![identifier isKindOfClass:NSString.class] || !matches(identifier,@"^org\\.overwatch2mac\\.[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*$") ||
       !confstr(_CS_DARWIN_USER_CACHE_DIR,caches,sizeof(caches)))return nil;
    return join(@(caches),identifier);
}
static void deleteShaders(void) {
    if(sessionProcesses().count)fail(@"close_game_before_maintenance");
    if(!stopMonitor())fail(@"shader_preparation_running");
    // Moved aside first, so each cache is whole or gone even if removing it stops partway.
    NSString *cache=join(root,@"cache"),*aside=join(root,@"tmp/cleared-shaders");
    [fm removeItemAtPath:aside error:nil];mkdirs(aside);
    for(NSString *name in @[@"pipelines",@"shaders"]) {
        NSString *path=join(cache,name);
        if(([fm fileExistsAtPath:path] || [fm destinationOfSymbolicLinkAtPath:path error:nil]) &&
           ![fm moveItemAtPath:path toPath:join(aside,name) error:nil])fail(@"shader_delete_failed");
    }
    for(NSString *name in @[@"pack.json",@"prepared.json",@"preparing.json",@"warmed.json",@"shader-update"])
        [fm removeItemAtPath:join(cache,name) error:nil];
    NSString *metal=gameAppShaderCache();
    if(metal && [fm fileExistsAtPath:metal] && ![fm removeItemAtPath:metal error:nil])fail(@"shader_delete_failed");
    [fm removeItemAtPath:aside error:nil];
    applyShaderMemory();
    event(@"shaders_deleted",nil);
}
static void launchClient(BOOL diagnostic, BOOL play, BOOL sized, BOOL hud, BOOL gameMode, BOOL metalfx, NSString *sharpening,
                         NSString *logging, NSString *loggingCustom) {
    // A logging setting Wine wouldn't understand stops the launch before anything starts.
    NSDictionary *logs=loggingEnvironment(logging,loggingCustom);
    requireRosetta();
    NSString *engine=runtime();if(![fm fileExistsAtPath:clientPath()])fail(@"battlenet_not_installed");
    // Before anything else: an Overwatch started from a Battle.net already open reads it too.
    applyShaderMemory();
    NSArray *existing=sessionProcesses();
    if(diagnostic && existing.count)fail(@"close_game_before_maintenance");
    // Battle.net's own command for starting Overwatch ("Pro"). A running client
    // receives it from a second launch, which hands it over and exits.
    NSArray *client=@[clientPath(),@"--disable-gpu-compositing",@"--from-launcher",@"--in-process-gpu",@"--use-gl=angle",@"--use-angle=swiftshader"];
    if(play)client=[client arrayByAddingObject:@"--exec=launch Pro"];
    // A game must start in a Wine session that began with the displays as they are now
    // (displaySignature). Battle.net open from before a display change is closed and
    // opened again; a running game is left alone.
    NSString *displays=displaySignature(),*sessionDisplays=state()[@"session_displays"];
    BOOL displaysChanged=displays && ![displays isEqual:sessionDisplays];
    BOOL game=NO;for(NSDictionary *p in existing)game|=[p[@"kind"] isEqual:@"game"];
    if(existing.count && !game && sessionDisplays && displaysChanged) {
        event(@"displays_changed",nil);closeClient(@"close_game_before_maintenance");existing=@[];
    }
    if(focusSession(existing)) {
        if(play && !game && koreanSupportChosen() && !configureKoreanCertificate(engine,YES,YES))fail(@"korean_support_failed");
        // Overwatch reads its default microphone when it starts; one already running keeps its own.
        if(!game)configureVoiceMicrophone(engine,nil,YES,NO);
        // Battle.net already open carries its own environment; this hands over the command only.
        if(play && !game)task(join(engine,@"bin/wine"),client,clientEnvironment(wineEnv(engine),sized,hud,gameMode,NO),@"battlenet-play.log");
        if(!game)task(NSProcessInfo.processInfo.arguments[0],watchArguments(engine,gameMode,state()[@"log_session"]),nil,[NSString stringWithFormat:@"client-monitor-%d.log",getpid()]);
        return;
    }
    // The update Agent can legitimately outlive the client. It must not
    // block relaunch; game/client membership above is the launch boundary.
    // A session it keeps alive from before a display change is ended, though, as is one
    // started with the other Retina setting (configureRetina changes it between sessions).
    if(displaysChanged || retinaChangeNeeded())endSession(engine);
    // A legacy installation needs one fully idle session to restore Retina.
    configureRetina();
    NSInteger width,height;NSString *source;nextResolution(&width,&height,&source,YES);
    if([source isEqual:@"game"])event(@"display_from_game",@{@"width":@(width),@"height":@(height)});
    else if([source isEqual:@"game_reset"])event(@"display_restored",@{@"width":@(width),@"height":@(height)});
    NSInteger gameWidth=width,gameHeight=height;fittedResolution(&gameWidth,&gameHeight);
    // Overwatch resetting its display settings for a card it took to be new is not the
    // player's choice of display mode either (configurePreferences).
    configurePreferences(width,height,gameWidth,gameHeight,NO,[source isEqual:@"game_reset"] ? DisplayModeRemembered : DisplayModeKept);
    // After the resolution: a card switch must not read as the game resetting it (gameChoice).
    NSString *sharpness=nil;metalfx=configureMetalFX(engine,metalfx,sharpening,YES,&sharpness);
    if(gameWidth!=width || gameHeight!=height)
        event(@"display_fitted",@{@"width":@(gameWidth),@"height":@(gameHeight),@"chosen_width":@(width),@"chosen_height":@(height)});
    NSString *config=[NSString stringWithContentsOfFile:join(engine,@"config/dxmt.conf") encoding:NSUTF8StringEncoding error:nil];
    if(!config)fail(@"runtime_missing");
    config=sharpeningProfile(canvasProfile(config,gameWidth,gameHeight),sharpness);
    if(![config writeToFile:join(root,@"dxmt.conf") atomically:YES encoding:NSUTF8StringEncoding error:nil])fail(@"settings_write_failed");
    NSString *pipeline=helperPath(@"ow2-pipeline");
    stopAfterSession();
    if([fm isExecutableFileAtPath:pipeline]) {
        event(@"preparing_pipelines",nil);
        // The game runs as the engine's game app with Game Mode and as Wine's own loader without;
        // each keeps its own compiled-shader cache, which the helper warms when it is new to this Mac.
        NSString *program=gameProgram(engine,gameMode);
        NSArray *arguments=program ? @[root,program] : @[root];
        int code=waitTaskTicking(task(pipeline,arguments,nil,@"pipeline-preparation.log"),600,graphicsFeed(join(join(root,@"logs"),@"pipeline-preparation.log")));
        if(code==75)fail(@"pipeline_cache_busy");
        if(code)event(@"pipeline_preparation_skipped",nil);
    }
    if(focusSession(sessionProcesses()))return;
    // Setup applies these; a launch puts back any that went missing (the registry tool runs
    // only then). The voice step below waits for Wine's server, as Battle.net needs.
    configureProxy(engine,proxyDetectionChosen());
    configureOptionKey(engine);
    if(koreanSupportChosen() && !configureKoreanCertificate(engine,YES,YES))fail(@"korean_support_failed");
    if(cjkFontsChosen())configureFonts(engine,YES);
    configureVoiceMicrophone(engine,nil,YES,YES);
    if(displays) {NSMutableDictionary *s=state();s[@"session_displays"]=displays;writeJSON(s,join(root,@"state.json"));}
    NSMutableDictionary *env=clientEnvironment(diagnostic?diagnosticEnvironment(engine):wineEnv(engine),sized,hud,gameMode,metalfx);
    [env addEntriesFromDictionary:logs];
    NSArray *chosen=loggingChoice(logging);
    NSMutableDictionary *record=[@{@"logging":loggingName(chosen),@"winedebug":env[@"WINEDEBUG"],@"dxmt_log_level":env[@"DXMT_LOG_LEVEL"],
        @"runtime":state()[@"active_runtime"],@"region":state()[@"battlenet_region"] ?: @"global",@"korean_support":@(koreanSupportChosen()),
        @"game_mode":@(gameMode),@"metalfx":@(metalfx),@"metal_hud":@(hud),@"mouse_input":mouseInput,
        @"mouse_rate":[mouseInput isEqual:@"classic"] ? @"classic" : mouseRate} mutableCopy];
    if([chosen containsObject:@"custom"])record[@"logging_custom"]=loggingCustom;
    NSString *session=startSessionLog(record);
    // Mouse (REC-51): the window driver writes its report beside the session's record, one file per
    // process (input-<pid>.jsonl).
    if([chosen containsObject:@"mouse"])env[@"WINEMAC_INPUT_STATS"]=join(join(sessionsFolder(),session),@"input");
    NSTask *p=task(join(engine,@"bin/wine"),client,env,[NSString stringWithFormat:@"sessions/%@/battlenet.log",session]);
    saveStage(@"battlenet_started");event(@"battlenet_open",@{@"pid":@(p.processIdentifier),@"session":session});
    task(NSProcessInfo.processInfo.arguments[0],watchArguments(engine,gameMode,session),nil,[NSString stringWithFormat:@"client-monitor-%d.log",getpid()]);
}

/* Settings › Advanced. Battle.net and Overwatch carry both settings from when they start,
 * so both must be closed. The registry changes first; then the choice is saved for setup
 * and launches to keep. Without APPLY nothing changes: what would is reported. */
static void advancedSetting(NSString *name, BOOL on, BOOL apply) {
    BOOL korean=[name isEqual:@"korean_support"];
    if(!apply) {
        if(korean)configureKoreanCertificate(nil,on,NO);else configureProxy(nil,on);
        return;
    }
    // Before setup has made the Windows environment, the choice waits for prepare.
    if([fm fileExistsAtPath:join(root,@"environment/system.reg")]) {
        NSString *engine=runtime();
        if(sessionProcesses().count)fail(@"close_game_before_maintenance");
        if(!(korean ? configureKoreanCertificate(engine,on,NO) : configureProxy(engine,on)))fail(@"setting_change_failed");
        registrySaved(engine,6);
    }
    NSMutableDictionary *s=state();s[name]=@(on);writeJSON(s,join(root,@"state.json"));
    event(@"setting_saved",@{@"name":name,@"enabled":@(on)});
}
// Refuses while Overwatch itself runs (failing with gameRunning). An owned
// Battle.net client is closed the way the launch monitor closes it (SIGTERM,
// then wineserver -k).
static void closeClient(NSString *gameRunning) {
    if(!(matches(state()[@"active_runtime"],@"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$") && [fm fileExistsAtPath:join(join(join(root,@"runtimes"),state()[@"active_runtime"]),@"runtime.json")]))return;
    NSString *engine=runtime();BOOL closed=NO;
    for(int attempt=0;attempt<20 && !closed;attempt++) {
        if(membershipCache)[membershipCache removeAllObjects];
        NSArray *rows=sessionProcesses();NSMutableArray *clients=[NSMutableArray array];
        for(NSDictionary *p in rows) {if([p[@"kind"] isEqual:@"game"])fail(gameRunning);[clients addObject:p];}
        if(!clients.count) {closed=YES;break;}
        if(attempt==0) {event(@"closing_client",nil);for(NSDictionary *p in clients)kill([p[@"pid"] intValue],SIGTERM);}
        else if(attempt==10)waitTask(task(join(engine,@"bin/wineserver"),@[@"-k"],wineEnv(engine),@"client-stop.log"),15);
        [NSThread sleepForTimeInterval:1];
    }
    if(!closed)fail(@"client_close_failed");
}
static void uninstall(void) {
    // Everything this app created lives under the owned root: the Wine
    // environment holding Battle.net and Overwatch, runtimes, downloads, logs
    // and caches. ownRoot already refused any directory without the marker.
    closeClient(@"close_game_before_uninstall");
    stopAfterSession();
    // Move, never delete: the folder is recoverable from the Trash with Put
    // Back. On the same volume this is a rename even for a full game install.
    NSURL *trashed=nil;NSError *error=nil;
    if(![fm trashItemAtURL:[NSURL fileURLWithPath:root] resultingItemURL:&trashed error:&error])fail(@"uninstall_move_failed");
    event(@"uninstalled",@{@"trashed":trashed.path ?: @""});
}
static void discardUnused(void) {
    // Switching install location before anything was installed: remove only
    // the empty scaffold ownRoot made (plus setup check logs). Anything else,
    // including any installation state, keeps the folder untouched.
    if([fm fileExistsAtPath:join(root,@"state.json")])fail(@"location_in_use");
    NSSet *scaffold=[NSSet setWithArray:@[@".overwatch-2-mac-owner",@"setup.lock",@".DS_Store",@"runtimes",@"downloads",@"logs",@"home",@"tmp",@"cache"]];
    for(NSString *name in [fm contentsOfDirectoryAtPath:root error:nil]) {
        if(![scaffold containsObject:name])fail(@"location_in_use");
        struct stat st;if(lstat(join(root,name).fileSystemRepresentation,&st))fail(@"location_in_use");
        if(!S_ISDIR(st.st_mode))continue;
        for(NSString *child in [fm contentsOfDirectoryAtPath:join(root,name) error:nil])
            if(!([name isEqual:@"logs"] && [child hasSuffix:@".log"]) && ![child isEqual:@".DS_Store"])fail(@"location_in_use");
    }
    close(lockFD);lockFD=-1;
    if(![fm removeItemAtPath:root error:nil])fail(@"location_cleanup_failed");
    event(@"location_released",nil);
}
int main(int argc, const char *argv[]) { @autoreleasepool {
    fm=NSFileManager.defaultManager;signal(SIGTERM,cancelled);signal(SIGINT,cancelled);
    @try {
        if(argc<2)fail(@"command_required");NSString *command=@(argv[1]);NSMutableDictionary *options=[NSMutableDictionary dictionary];
        for(int i=2;i<argc;i+=2) {if(i+1>=argc || strncmp(argv[i],"--",2))fail(@"invalid_arguments");options[@(argv[i]+2)]=@(argv[i+1]);}
        NSString *defaultRoot=join([fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject.path,@"Overwatch2Mac");
        monitorMode=[command isEqual:@"watch"];
        ownRoot(options[@"root"] ?: defaultRoot);
        // Only the program Overwatch runs as (gameProgram) inside an installed engine of this data folder.
        NSString *gameApp=[options[@"game-app"] stringByStandardizingPath];
        if(monitorMode && gameApp && [gameApp hasPrefix:[join(root,@"runtimes") stringByAppendingString:@"/"]] &&
           (([gameApp hasSuffix:@"/lib/wine/game-mode/Overwatch.app"] && [fm fileExistsAtPath:join(gameApp,@"Contents/Info.plist")]) ||
            ([gameApp hasSuffix:@"/lib/wine/x86_64-unix/wine"] && [fm isExecutableFileAtPath:gameApp])))monitorGameApp=gameApp;
        monitorPrepareNow=monitorMode && [options[@"prepare-now"] isEqual:@"1"];
        if(monitorMode && validSessionName(options[@"session"]))monitorSession=options[@"session"];
        if([@[@"classic",@"high-precision"] containsObject:options[@"mouse"] ?: @""])mouseInput=options[@"mouse"];
        if([@[@"2000",@"1000",@"500",@"250"] containsObject:options[@"mouse-rate"] ?: @""])mouseRate=options[@"mouse-rate"];
        if([command isEqual:@"preflight"])preflight();
        else if([command isEqual:@"status"]) {
            // The resolution Overwatch opens at next on the main display.
            NSInteger width,height;NSString *source;nextResolution(&width,&height,&source,NO);
            NSMutableDictionary *next=[@{@"width":@(width),@"height":@(height),@"from_game":@([source isEqual:@"game"]),@"per_display":@(displayMemory(state()))} mutableCopy];
            if(mainScreen())next[@"screen"]=mainScreen();
            // Where Battle.net is, relative to the data folder (the app shows its icon).
            NSString *client=clientPath();
            event(@"status",@{@"state":state(),@"display_next":next,@"battlenet_installed":@([fm fileExistsAtPath:client]),
                @"battlenet_path":[client substringFromIndex:root.length+1],@"game_installed":@([fm fileExistsAtPath:join(gameFolder(),@"Overwatch.exe")]),
                @"nexon_build":@(nexonBuild()),@"neac_build":@(neacBuild()),@"free_bytes":@(freeBytes())});
        }
        // Setup's Choose your Battle.net: --region global|cn, --language enUS|zhCN|koKR (portable_region.h).
        else if([command isEqual:@"battlenet"])chooseBattleNet(options[@"region"],options[@"language"]);
        // Support and tests: the fonts setup and launches add for Chinese and Korean; --apply 0 only reports.
        else if([command isEqual:@"fonts"])configureFonts([options[@"apply"] isEqual:@"0"] ? nil : runtime(),cjkFontsChosen());
        // Support and tests: Overwatch's left Option key as Alt, which setup and launches set.
        else if([command isEqual:@"keyboard"])configureOptionKey([options[@"apply"] isEqual:@"0"] ? nil : runtime());
        else if([command isEqual:@"onboarded"]) { NSMutableDictionary *s=state();s[@"onboarding_complete"]=@YES;writeJSON(s,join(root,@"state.json"));event(@"onboarding_complete",nil); }
        else if([command isEqual:@"session"])event(@"session",@{@"processes":sessionProcesses()});
        else if([command isEqual:@"watch"])watchClient();
        else if([command isEqual:@"display"]) {
            // 0.1.x apps sent only a height (1080 or 1200, 1920 wide).
            NSString *width=options[@"width"] ?: @"1920",*height=options[@"height"] ?: @"";
            if(!matches(width,@"^[0-9]{3,5}$") || !matches(height,@"^[0-9]{3,5}$") ||
               !supportedResolution(width.integerValue,height.integerValue))fail(@"unsupported_resolution");
            // A resolution chosen in Settings is a window's size too; --reset 1 (Reset Display
            // Settings) puts Overwatch back in Fullscreen.
            configureDisplay(width.integerValue,height.integerValue,[options[@"reset"] isEqual:@"1"] ? DisplayModeReset : DisplayModeResized);
        }
        else if([command isEqual:@"display-memory"]) {
            // Settings › Remember a resolution for each display.
            NSString *enabled=options[@"enabled"];
            if(![enabled isEqual:@"0"] && ![enabled isEqual:@"1"])fail(@"invalid_arguments");
            NSMutableDictionary *s=state();s[@"display_memory"]=@([enabled isEqual:@"1"]);writeJSON(s,join(root,@"state.json"));
            event(@"display_memory",@{@"enabled":@([enabled isEqual:@"1"])});
        }
        else if([command isEqual:@"repair-retina"])configureRetina();
        // Settings › Graphics › Shader memory: --limit all|first|<MiB>. Overwatch reads it when it
        // next starts, so it can change while Battle.net or the game is open.
        else if([command isEqual:@"shader-memory"]) {
            if(!validShaderMemory(options[@"limit"]))fail(@"invalid_arguments");
            NSMutableDictionary *s=state();s[@"shader_memory"]=options[@"limit"];writeJSON(s,join(root,@"state.json"));
            applyShaderMemory();event(@"shader_memory",@{@"limit":options[@"limit"]});
        }
        // The one-time shader cache update offered after updating to 1.4: what the monitor does
        // after a match, now, in a monitor of its own that a launch stops like any other (keeping
        // what it finished) and that then watches the session. --game-mode 0 as for launch.
        else if([command isEqual:@"prepare-shaders"]) {
            NSString *engine=runtime();
            for(NSDictionary *p in sessionProcesses())if([p[@"kind"] isEqual:@"game"])fail(@"close_game_before_maintenance");
            if(!stopMonitor()) {event(@"shader_preparation_running",nil);}
            else {
                NSArray *arguments=[watchArguments(engine,![options[@"game-mode"] isEqual:@"0"],nil) arrayByAddingObjectsFromArray:@[@"--prepare-now",@"1"]];
                task(NSProcessInfo.processInfo.arguments[0],arguments,nil,[NSString stringWithFormat:@"client-monitor-%d.log",getpid()]);
                event(@"shader_preparation_started",nil);
            }
        }
        // Settings › Graphics › Clear Shader Cache: every shader Recall keeps, to build again as
        // Overwatch uses them. Battle.net and Overwatch must be closed, and a preparation left to finish.
        else if([command isEqual:@"delete-shaders"])deleteShaders();
        // Support and tests: the microphone launch points Wine at (portable_voice.h). --uid names one
        // instead of asking Core Audio ("none": macOS's default); --apply 0 only reports.
        else if([command isEqual:@"voice-microphone"]) {
            BOOL apply=![options[@"apply"] isEqual:@"0"];
            configureVoiceMicrophone(apply ? runtime() : nil,options[@"uid"],apply,NO);
        }
        // Settings › Advanced: --proxy-detect 0|1 (automatic proxy detection) and --enabled 0|1
        // (Korean account support). --apply 0 only reports what would change (support and tests).
        else if([command isEqual:@"network"] || [command isEqual:@"korean-support"]) {
            BOOL korean=[command isEqual:@"korean-support"];
            NSString *value=options[korean ? @"enabled" : @"proxy-detect"];
            if(![value isEqual:@"0"] && ![value isEqual:@"1"])fail(@"invalid_arguments");
            advancedSetting(korean ? @"korean_support" : @"proxy_auto_detect",[value isEqual:@"1"],![options[@"apply"] isEqual:@"0"]);
        }
        else if([command isEqual:@"restore-candidate"]) {
            configureRetina();
            // The qualified baseline's resolution unless the player has chosen one.
            NSInteger width,height;NSString *source;
            if(state()[@"display_height"])nextResolution(&width,&height,&source,YES);else chosenResolution(&width,&height);
            configurePreferences(width,height,width,height,YES,DisplayModeReset);
        }
        else if([command isEqual:@"download"])event(@"download_complete",@{@"file":[download(options[@"url"],options[@"sha256"]) lastPathComponent]});
        else if([command isEqual:@"install-runtime"])installRuntime(options[@"archive"] ?: download(options[@"url"],options[@"sha256"]),options[@"sha256"],options[@"version"],[options[@"repair"] isEqual:@"1"]);
        else if([command isEqual:@"verify"]) {verifyRuntime(runtime(),state()[@"active_runtime"]);event(@"runtime_verified",nil);}
        else if([command isEqual:@"prepare"])prepare();
        else if([command isEqual:@"install-battlenet"])installClient(options[@"installer"] ?: download(options[@"url"],options[@"sha256"]),options[@"sha256"]);
        // --battlenet-scale 1 keeps Battle.net at Windows' size; otherwise it has the main display's (battleNetSize).
        // --metal-hud 1 shows Apple's Metal Performance HUD over Overwatch (Settings); off by default.
        // --game-mode 0 starts Overwatch without macOS Game Mode (the app's switch, off by default from 1.6); on otherwise.
        // --metalfx 1 offers DLSS on MetalFX, with --sharpening off|low|high (Settings); off by default.
        // --logging off, or any of crashes,graphics,battlenet,mouse,custom joined with commas, with
        // --logging-custom <WINEDEBUG text> for custom (Settings › Advanced); off by default.
        // --mouse standard|classic|high-precision chooses how the game gets the mouse (Settings › General); standard by default.
        else if([command isEqual:@"launch"])launchClient(NO,[options[@"play"] isEqual:@"1"],![options[@"battlenet-scale"] isEqual:@"1"],[options[@"metal-hud"] isEqual:@"1"],![options[@"game-mode"] isEqual:@"0"],[options[@"metalfx"] isEqual:@"1"],options[@"sharpening"] ?: @"off",options[@"logging"] ?: @"off",options[@"logging-custom"]);
        else if([command isEqual:@"diagnostic-launch"])launchClient(YES,NO,![options[@"battlenet-scale"] isEqual:@"1"],[options[@"metal-hud"] isEqual:@"1"],![options[@"game-mode"] isEqual:@"0"],[options[@"metalfx"] isEqual:@"1"],options[@"sharpening"] ?: @"off",options[@"logging"] ?: @"off",options[@"logging-custom"]);
        // Support and tests: what launch --logging (and --logging-custom) gives Wine and the graphics layer,
        // and whether it turns on the mouse report.
        else if([command isEqual:@"logging"])event(@"logging",@{@"setting":loggingName(loggingChoice(options[@"setting"])),
            @"environment":loggingEnvironment(options[@"setting"] ?: @"off",options[@"custom"]),@"mouse_report":@(loggingMouse(options[@"setting"]))});
        // Support and tests: each Battle.net start's logs (logs/sessions), oldest first. --prune 1 removes
        // the oldest while the logs would take more room than the disk has left, as each launch does.
        else if([command isEqual:@"session-logs"]) {
            if([options[@"prune"] isEqual:@"1"])pruneSessionLogs();
            event(@"session_logs",@{@"sessions":sessionLogNames()});
        }
        // Support and tests: what a launch with --enabled 0|1 (and --sharpening) sets up for MetalFX
        // upscaling (portable_metalfx.h); --apply 0 only reports.
        else if([command isEqual:@"metalfx"]) {
            BOOL apply=![options[@"apply"] isEqual:@"0"];
            if(![options[@"enabled"] isEqual:@"0"] && ![options[@"enabled"] isEqual:@"1"])fail(@"invalid_arguments");
            if(apply && sessionProcesses().count)fail(@"close_game_before_maintenance");
            NSString *amount=nil;configureMetalFX(runtime(),[options[@"enabled"] isEqual:@"1"],options[@"sharpening"] ?: @"off",apply,&amount);
        }
        else if([command isEqual:@"close-client"]) {closeClient(@"close_game_before_update");event(@"client_closed",nil);}
        else if([command isEqual:@"parity-report"])event(@"parity_report",parityReport(runtime(),wineEnv(runtime())));
        else if([command isEqual:@"uninstall"])uninstall();
        else if([command isEqual:@"discard-unused"])discardUnused();
        else if([command isEqual:@"stop"]) {NSString *engine=runtime();int code=waitTask(task(join(engine,@"bin/wineserver"),@[@"-k"],wineEnv(engine),@"stop.log"),15);if(code!=0 && code!=1)fail(@"stop_failed");event(@"environment_stopped",nil);}
        else fail(@"unknown_command");
        if(lockFD>=0)close(lockFD);return 0;
    } @catch(NSException *exception) {
        if(cancelRequested && ownedPreparation) {
            // There was no client/game when this preparation began. Stop only
            // the helper processes it started in this owned environment.
            cancelRequested=0;
            @try { NSString *engine=runtime();waitTask(task(join(engine,@"bin/wineserver"),@[@"-k"],wineEnv(engine),@"cancel-prepare.log"),15);waitTask(task(join(engine,@"bin/wineserver"),@[@"-w"],wineEnv(engine),@"cancel-wait.log"),15); } @catch(NSException *ignored) { (void)ignored; }
        }
        event(@"error",@{@"code":[exception.name isEqual:@"SetupError"]?exception.reason:@"unexpected_setup_error"});
        if(lockFD>=0)close(lockFD);return 1;
    }
}}
