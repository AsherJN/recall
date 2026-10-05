/* Original project test: Apache-2.0. Read-only Windows/native ABI regression probe. */
#include <windows.h>
#include <winternl.h>
#include <stdio.h>

typedef NTSTATUS (NTAPI *open_directory_fn)(HANDLE *, ACCESS_MASK, OBJECT_ATTRIBUTES *);
/* Deliberately populate the unused upper bytes of BOOLEAN argument slots.
 * Windows callees consume the low byte; the native syscall bridge must too. */
typedef NTSTATUS (NTAPI *query_directory_fn)(HANDLE, void *, ULONG, ULONG, ULONG, ULONG *, ULONG *);

int main(void)
{
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    open_directory_fn open_directory = (open_directory_fn)GetProcAddress(ntdll, "NtOpenDirectoryObject");
    query_directory_fn query_directory = (query_directory_fn)GetProcAddress(ntdll, "NtQueryDirectoryObject");
    WCHAR path[] = L"\\DosDevices";
    UNICODE_STRING name = {(sizeof(path) - sizeof(WCHAR)), sizeof(path), path};
    OBJECT_ATTRIBUTES attr = {0};
    HANDLE handle = NULL;
    ULONG context = 0, length = 0, first_context;
    unsigned char buffer[4096];
    NTSTATUS status;

    attr.Length = sizeof(attr);
    attr.ObjectName = &name;
    attr.Attributes = OBJ_CASE_INSENSITIVE;
    if (!open_directory || !query_directory || open_directory(&handle, 1, &attr)) return 1;
    status = query_directory(handle, buffer, sizeof(buffer), 1, 0, &context, &length);
    if (status || !context) { CloseHandle(handle); return 2; }
    first_context = context;
    status = query_directory(handle, buffer, sizeof(buffer), 0x5a5a0001, 0x5a5a0000, &context, &length);
    if (status || context <= first_context)
    {
        printf("{\"boolean_slot_continuation\":false,\"context_advanced\":false}\n");
        CloseHandle(handle);
        return 3;
    }
    status = query_directory(handle, buffer, sizeof(buffer), 1, 0x5a5a0001, &context, &length);
    CloseHandle(handle);
    if (status || context != first_context) return 4;
    puts("{\"boolean_slot_continuation\":true,\"explicit_restart\":true}");
    return 0;
}
