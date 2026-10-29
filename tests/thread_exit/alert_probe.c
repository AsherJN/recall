/* Recall #40/#50: a thread that made an alertable wait exits while the process has many files
 * open, as Overwatch's workers do once its game archives are open. Under msync, Wine closed the
 * thread's alert index at exit as if it were a descriptor, so one of the files closed behind
 * Wine's back; the next read of it failed (error 1 when a pipe took the number, error 6 when
 * nothing did) or returned another file's data.
 *
 *   alert_probe.exe FILE [THREADS]
 *
 * Starts THREADS workers whose alertable wait takes their alert index, opens FILE FILES times
 * and reads each handle once (Wine caches its descriptor), lets the workers exit, starts as many
 * plain threads (their pipes take freed numbers), then reads every handle again and compares the
 * data. Prints one JSON line. */
#include <windows.h>
#include <stdio.h>
#include <string.h>

#define FILES 1000

static HANDLE files[FILES], start, event;
static unsigned char first[FILES][4096];

static DWORD WINAPI worker( void *arg )
{
    WaitForSingleObjectEx( start, INFINITE, TRUE );
    return 0;
}

static DWORD WINAPI plain( void *arg )
{
    Sleep( 50 );
    return 0;
}

static BOOL read_page( HANDLE handle, unsigned char *buffer, DWORD *error )
{
    OVERLAPPED ov = {0};
    DWORD done = 0;
    BOOL ok;

    /* One event for every read: each new one would take an msync index. */
    ResetEvent( event );
    ov.Offset = 4096;
    ov.hEvent = event;
    ok = ReadFile( handle, buffer, 4096, NULL, &ov );
    if (!ok && GetLastError() == ERROR_IO_PENDING) ok = GetOverlappedResult( handle, &ov, &done, TRUE );
    else if (ok) GetOverlappedResult( handle, &ov, &done, FALSE );
    *error = ok ? 0 : GetLastError();
    return ok && done == 4096;
}

int main( int argc, char **argv )
{
    int count = argc > 2 ? atoi( argv[2] ) : 60, i, failed = 0, wrong = 0, errors[8] = {0}, codes[8] = {0}, kinds = 0;
    HANDLE threads[256];
    unsigned char buffer[4096];
    DWORD error;

    if (argc < 2 || count < 1 || count > 256)
    {
        fprintf( stderr, "usage: alert_probe.exe FILE [THREADS (1-256)]\n" );
        return 2;
    }
    start = CreateEventA( NULL, TRUE, FALSE, NULL );
    event = CreateEventA( NULL, TRUE, FALSE, NULL );
    for (i = 0; i < count; i++) threads[i] = CreateThread( NULL, 0, worker, NULL, 0, NULL );
    Sleep( 300 );
    for (i = 0; i < FILES; i++)
    {
        files[i] = CreateFileA( argv[1], GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL );
        if (files[i] == INVALID_HANDLE_VALUE || !read_page( files[i], first[i], &error ))
        {
            printf( "{\"error\":\"setup\",\"file\":%d,\"code\":%lu}\n", i, (unsigned long)GetLastError() );
            return 2;
        }
    }
    SetEvent( start );
    for (i = 0; i < count; i++) { WaitForSingleObject( threads[i], INFINITE ); CloseHandle( threads[i] ); }
    Sleep( 200 );
    for (i = 0; i < count; i++) threads[i] = CreateThread( NULL, 0, plain, NULL, 0, NULL );
    Sleep( 20 );
    for (i = 0; i < FILES; i++)
    {
        if (!read_page( files[i], buffer, &error ))
        {
            int k;
            failed++;
            for (k = 0; k < kinds && codes[k] != (int)error; k++) ;
            if (k == kinds && kinds < 8) codes[kinds++] = error;
            if (k < 8) errors[k]++;
        }
        else if (memcmp( buffer, first[i], sizeof(buffer) )) wrong++;
    }
    for (i = 0; i < count; i++) { WaitForSingleObject( threads[i], INFINITE ); CloseHandle( threads[i] ); }
    printf( "{\"files\":%d,\"threads\":%d,\"failed\":%d,\"wrong_data\":%d,\"errors\":{", FILES, count, failed, wrong );
    for (i = 0; i < kinds; i++) printf( "%s\"%d\":%d", i ? "," : "", codes[i], errors[i] );
    printf( "}}\n" );
    return 0;
}
