/* Read-only desktop geometry check. Run in an idle owned Wine environment,
 * passing the expected Windows width/height for the current Retina display. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    if(argc != 3) return 2;
    int width=GetSystemMetrics(SM_CXSCREEN),height=GetSystemMetrics(SM_CYSCREEN);
    printf("{\"screen\":[%d,%d]}\n",width,height);
    return width!=atoi(argv[1]) || height!=atoi(argv[2]);
}
