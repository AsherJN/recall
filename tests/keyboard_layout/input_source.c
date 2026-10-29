/* The Mac side of tests/keyboard_layout/run.py: reads and changes the selected input source.
 *
 *   input_source current            prints the selected keyboard input source's ID
 *   input_source enabled ID         prints 1 if ID is enabled, else 0
 *   input_source enable|disable|select ID
 *
 * Exits 1 when ID is not installed or macOS refuses the change. */
#include <Carbon/Carbon.h>
#include <stdio.h>
#include <string.h>

static TISInputSourceRef find( const char *id )
{
    CFStringRef name = CFStringCreateWithCString( NULL, id, kCFStringEncodingUTF8 );
    const void *keys[] = { kTISPropertyInputSourceID }, *values[] = { name };
    CFDictionaryRef filter = CFDictionaryCreate( NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                                                 &kCFTypeDictionaryValueCallBacks );
    CFArrayRef list = TISCreateInputSourceList( filter, true );
    TISInputSourceRef source = NULL;

    if (list && CFArrayGetCount( list ))
        source = (TISInputSourceRef)CFRetain( CFArrayGetValueAtIndex( list, 0 ) );
    if (list) CFRelease( list );
    CFRelease( filter );
    CFRelease( name );
    return source;
}

int main( int argc, char **argv )
{
    TISInputSourceRef source;
    char text[256];
    OSStatus status;

    if (argc == 2 && !strcmp( argv[1], "current" ))
    {
        source = TISCopyCurrentKeyboardInputSource();
        if (!source || !CFStringGetCString( TISGetInputSourceProperty( source, kTISPropertyInputSourceID ), text,
                                            sizeof(text), kCFStringEncodingUTF8 ))
            return 1;
        puts( text );
        return 0;
    }
    if (argc != 3 || !(source = find( argv[2] ))) return 1;
    if (!strcmp( argv[1], "enabled" ))
    {
        puts( CFBooleanGetValue( TISGetInputSourceProperty( source, kTISPropertyInputSourceIsEnabled ) ) ? "1" : "0" );
        return 0;
    }
    if (!strcmp( argv[1], "enable" )) status = TISEnableInputSource( source );
    else if (!strcmp( argv[1], "disable" )) status = TISDisableInputSource( source );
    else if (!strcmp( argv[1], "select" )) status = TISSelectInputSource( source );
    else return 1;
    return status == noErr ? 0 : 1;
}
