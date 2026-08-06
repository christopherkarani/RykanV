#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <sddl.h>

// Replace inherited permissions with an explicit DACL granting full access
// only to the file owner. The temp file is renamed only after this succeeds.
int ryk_set_owner_only_acl(const unsigned short *path) {
    PSECURITY_DESCRIPTOR descriptor = NULL;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:P(A;;FA;;;OW)",
            SDDL_REVISION_1,
            &descriptor,
            NULL)) {
        return 0;
    }

    const BOOL ok = SetFileSecurityW(
        (LPCWSTR)path,
        DACL_SECURITY_INFORMATION,
        descriptor);
    LocalFree(descriptor);
    return ok ? 1 : 0;
}
#else

int ryk_set_owner_only_acl(const unsigned short *path) {
    (void)path;
    return 1;
}

#endif
