/* Local UI verification aid. Requires an explicit PID and targets only that app.
 * No arguments, environment, account data or unrelated window titles are read. */
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#include <unistd.h>
int main(int argc,char **argv) {@autoreleasepool {
    if(argc<3)return 2;
    pid_t pid=atoi(argv[1]);if(pid<=0)return 2;
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if(!app || app.terminated)return 3;
    NSString *action=@(argv[2]);
    if([action isEqualToString:@"windows"]) {
        NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
        NSMutableArray *result=[NSMutableArray array];
        for(NSDictionary *w in windows)if([w[(id)kCGWindowOwnerPID] intValue]==pid)
            [result addObject:@{@"pid":@(pid),@"window":w[(id)kCGWindowNumber],@"bounds":w[(id)kCGWindowBounds],
              @"onscreen":w[(id)kCGWindowIsOnscreen]?:@NO,@"layer":w[(id)kCGWindowLayer]}];
        NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        fwrite(data.bytes,1,data.length,stdout);puts("");return 0;
    }
    if(!AXIsProcessTrusted()){fputs("Accessibility control unavailable\n",stderr);return 4;}
    [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    for(unsigned i=0;i<20 && NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=pid;i++)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
    if(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=pid)return 5;
    if([action isEqualToString:@"key"] && argc==4) {
        CGKeyCode key=atoi(argv[3]);
        for(unsigned down=1;;down=0){CGEventRef e=CGEventCreateKeyboardEvent(NULL,key,down);CGEventPostToPid(pid,e);CFRelease(e);if(!down)break;usleep(30000);}
    } else if([action isEqualToString:@"click"] && argc==5) {
        CGPoint p=CGPointMake(atof(argv[3]),atof(argv[4]));
        CGEventRef move=CGEventCreateMouseEvent(NULL,kCGEventMouseMoved,p,kCGMouseButtonLeft);CGEventPostToPid(pid,move);CFRelease(move);usleep(80000);
        for(unsigned down=1;;down=0){CGEventRef e=CGEventCreateMouseEvent(NULL,down?kCGEventLeftMouseDown:kCGEventLeftMouseUp,p,kCGMouseButtonLeft);CGEventPostToPid(pid,e);CFRelease(e);if(!down)break;usleep(40000);}
    } else return 2;
    return 0;
}}
