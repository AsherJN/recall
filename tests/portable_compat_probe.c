/* What Settings › Advanced changes, as a Windows program sees it (run by run_compat_probe.py):
 *   proxy          WinHTTP's proxy settings: automatic detection on or off
 *   chain FILE     the chain Windows builds for a DER certificate: its length and root
 *   screen         StretchBlt and BitBlt from the screen into a white bitmap
 * Each prints one JSON line. Reads only; changes nothing. */
#include <windows.h>
#include <winhttp.h>
#include <wincrypt.h>
#include <stdio.h>
#include <string.h>

static int proxy(void)
{
    WINHTTP_CURRENT_USER_IE_PROXY_CONFIG config;
    memset(&config, 0, sizeof(config));
    if (!WinHttpGetIEProxyConfigForCurrentUser(&config))
    {
        printf("{\"error\":%lu}\n", GetLastError());
        return 1;
    }
    printf("{\"auto_detect\":%d,\"proxy\":%d,\"auto_config_url\":%d}\n", config.fAutoDetect ? 1 : 0,
           config.lpszProxy != NULL, config.lpszAutoConfigUrl != NULL);
    return 0;
}

static int chain(const char *path)
{
    static BYTE data[65536];
    FILE *file = fopen(path, "rb");
    size_t size = file ? fread(data, 1, sizeof(data), file) : 0;
    PCCERT_CONTEXT certificate, root;
    PCCERT_CHAIN_CONTEXT context;
    CERT_CHAIN_PARA parameters;
    PCERT_SIMPLE_CHAIN simple;
    BYTE hash[20];
    DWORD length = sizeof(hash), i;
    char name[256], hex[41];

    if (file) fclose(file);
    if (!size || !(certificate = CertCreateCertificateContext(X509_ASN_ENCODING, data, (DWORD)size)))
    {
        printf("{\"error\":\"certificate\"}\n");
        return 1;
    }
    memset(&parameters, 0, sizeof(parameters));
    parameters.cbSize = sizeof(parameters);
    if (!CertGetCertificateChain(NULL, certificate, NULL, NULL, &parameters, 0, NULL, &context))
    {
        printf("{\"error\":%lu}\n", GetLastError());
        return 1;
    }
    simple = context->rgpChain[0];
    root = simple->rgpElement[simple->cElement - 1]->pCertContext;
    CertGetCertificateContextProperty(root, CERT_SHA1_HASH_PROP_ID, hash, &length);
    for (i = 0; i < 20; i++) sprintf(hex + i * 2, "%02X", hash[i]);
    CertGetNameStringA(root, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, NULL, name, sizeof(name));
    printf("{\"elements\":%lu,\"root\":\"%s\",\"root_name\":\"%s\",\"trust_errors\":%lu}\n",
           simple->cElement, hex, name, context->TrustStatus.dwErrorStatus);
    CertFreeCertificateChain(context);
    CertFreeCertificateContext(certificate);
    return 0;
}

static int screen(void)
{
    HDC display = GetDC(NULL), memory = CreateCompatibleDC(display);
    BITMAPINFO info;
    DWORD *bits = NULL, error, stretched_pixel;
    HBITMAP bitmap;
    BOOL stretched, copied;
    int i;

    memset(&info, 0, sizeof(info));
    info.bmiHeader.biSize = sizeof(info.bmiHeader);
    info.bmiHeader.biWidth = 64;
    info.bmiHeader.biHeight = -64;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    bitmap = CreateDIBSection(memory, &info, DIB_RGB_COLORS, (void **)&bits, NULL, 0);
    if (!display || !memory || !bitmap)
    {
        printf("{\"error\":\"setup\"}\n");
        return 1;
    }
    SelectObject(memory, bitmap);
    for (i = 0; i < 64 * 64; i++) bits[i] = 0x00ffffff;
    SetLastError(0);
    stretched = StretchBlt(memory, 0, 0, 64, 64, display, 0, 0, 128, 128, SRCCOPY);
    error = GetLastError();
    stretched_pixel = bits[64 * 32 + 32];
    for (i = 0; i < 64 * 64; i++) bits[i] = 0x00ffffff;
    copied = BitBlt(memory, 0, 0, 64, 64, display, 10, 10, SRCCOPY);
    printf("{\"stretchblt\":%d,\"bitblt\":%d,\"stretchblt_pixel\":\"%08lx\",\"bitblt_pixel\":\"%08lx\",\"error\":%lu}\n",
           stretched ? 1 : 0, copied ? 1 : 0, stretched_pixel, bits[64 * 32 + 32], error);
    DeleteDC(memory);
    DeleteObject(bitmap);
    ReleaseDC(NULL, display);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc == 2 && !strcmp(argv[1], "proxy")) return proxy();
    if (argc == 3 && !strcmp(argv[1], "chain")) return chain(argv[2]);
    if (argc == 2 && !strcmp(argv[1], "screen")) return screen();
    return 2;
}
