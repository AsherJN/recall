/* Chinese and Korean text in Recall's Windows environment (portable_region.h): what GDI and
 * DirectWrite draw for them. Prints one JSON object per line (run_font_probe.py).
 * - GDI: the face a request gets, and whether 中 and 한 draw as real glyphs (through the font
 *   itself or Wine's font links) rather than the box a private-use character draws as.
 * - DirectWrite: which system families exist, and the family its system font fallback picks
 *   for Chinese and Korean text in each locale. */
#define COBJMACROS
#define CINTERFACE
#include <windows.h>
#include <initguid.h>
#include <dwrite_2.h>
#include <stdio.h>
#include <string.h>

#define W 128
#define H 64
static HDC dc;
static void *bits;

static void utf8(const WCHAR *text, char *out, int size) { WideCharToMultiByte(CP_UTF8, 0, text, -1, out, size, NULL, NULL); }

static void draw(HFONT font, const WCHAR *text, unsigned char *copy) {
    RECT r = {0, 0, W, H};
    FillRect(dc, &r, GetStockObject(WHITE_BRUSH));
    HGDIOBJ old = SelectObject(dc, font);
    TextOutW(dc, 4, 4, text, lstrlenW(text));
    SelectObject(dc, old);
    GdiFlush();
    memcpy(copy, bits, W * H * 4);
}
static void gdi(const WCHAR *face) {
    static unsigned char han[W * H * 4], other[W * H * 4], hangul[W * H * 4], box[W * H * 4];
    HFONT font = CreateFontW(-32, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, ANTIALIASED_QUALITY, 0, face);
    HGDIOBJ old = SelectObject(dc, font);
    WCHAR actual[LF_FACESIZE] = {0};
    GetTextFaceW(dc, LF_FACESIZE, actual);
    SelectObject(dc, old);
    draw(font, L"\x4e2d", han);       /* 中 */
    draw(font, L"\x6587", other);     /* 文 */
    draw(font, L"\xd55c", hangul);    /* 한 */
    draw(font, L"\xe000", box);       /* private use: never in a font */
    char requested[256], got[256];
    utf8(face, requested, sizeof requested);
    utf8(actual, got, sizeof got);
    printf("{\"gdi\":\"%s\",\"face\":\"%s\",\"han\":%s,\"hangul\":%s}\n", requested, got,
           memcmp(han, box, sizeof han) && memcmp(han, other, sizeof han) ? "true" : "false",
           memcmp(hangul, box, sizeof hangul) ? "true" : "false");
    DeleteObject(font);
}

/* An IDWriteTextAnalysisSource over one string in one locale, for MapCharacters. */
typedef struct { IDWriteTextAnalysisSource iface; const WCHAR *text; UINT32 length; const WCHAR *locale; } Source;
static HRESULT STDMETHODCALLTYPE query(IDWriteTextAnalysisSource *s, REFIID iid, void **out) { (void)iid; *out = s; return S_OK; }
static ULONG STDMETHODCALLTYPE count(IDWriteTextAnalysisSource *s) { (void)s; return 1; }
static HRESULT STDMETHODCALLTYPE at(IDWriteTextAnalysisSource *s, UINT32 p, const WCHAR **text, UINT32 *n) {
    Source *x = (Source *)s;
    if (p >= x->length) { *text = NULL; *n = 0; } else { *text = x->text + p; *n = x->length - p; }
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE before(IDWriteTextAnalysisSource *s, UINT32 p, const WCHAR **text, UINT32 *n) {
    Source *x = (Source *)s;
    if (!p || p > x->length) { *text = NULL; *n = 0; } else { *text = x->text; *n = p; }
    return S_OK;
}
static DWRITE_READING_DIRECTION STDMETHODCALLTYPE direction(IDWriteTextAnalysisSource *s) { (void)s; return DWRITE_READING_DIRECTION_LEFT_TO_RIGHT; }
static HRESULT STDMETHODCALLTYPE locale(IDWriteTextAnalysisSource *s, UINT32 p, UINT32 *n, const WCHAR **name) {
    Source *x = (Source *)s; *n = x->length - p; *name = x->locale; return S_OK;
}
static HRESULT STDMETHODCALLTYPE numbers(IDWriteTextAnalysisSource *s, UINT32 p, UINT32 *n, IDWriteNumberSubstitution **out) {
    (void)s; (void)p; *n = 0; *out = NULL; return S_OK;
}
static IDWriteTextAnalysisSourceVtbl source_vtbl = { query, count, count, at, before, direction, locale, numbers };

static void family_name(IDWriteFont *font, char *out, int size) {
    IDWriteFontFamily *family;
    IDWriteLocalizedStrings *names;
    UINT32 index = 0;
    BOOL exists = FALSE;
    WCHAR name[128] = L"?";
    if (SUCCEEDED(IDWriteFont_GetFontFamily(font, &family))) {
        if (SUCCEEDED(IDWriteFontFamily_GetFamilyNames(family, &names))) {
            IDWriteLocalizedStrings_FindLocaleName(names, L"en-us", &index, &exists);
            IDWriteLocalizedStrings_GetString(names, exists ? index : 0, name, 128);
            IDWriteLocalizedStrings_Release(names);
        }
        IDWriteFontFamily_Release(family);
    }
    utf8(name, out, size);
}
static void fallback(IDWriteFontFallback *system, const char *script, const WCHAR *text, const WCHAR *in) {
    Source source = {{&source_vtbl}, text, (UINT32)lstrlenW(text), in};
    UINT32 mapped = 0;
    IDWriteFont *font = NULL;
    FLOAT scale = 0;
    char family[256] = "", where[32];
    IDWriteFontFallback_MapCharacters(system, &source.iface, 0, source.length, NULL, L"Segoe UI", DWRITE_FONT_WEIGHT_NORMAL,
                                      DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, &mapped, &font, &scale);
    if (font) { family_name(font, family, sizeof family); IDWriteFont_Release(font); }
    utf8(in, where, sizeof where);
    printf("{\"fallback\":\"%s\",\"locale\":\"%s\",\"family\":\"%s\"}\n", script, where, family);
}

int main(void) {
    BITMAPINFO info = {{sizeof(BITMAPINFOHEADER), W, -H, 1, 32, BI_RGB, 0, 0, 0, 0, 0}, {{0, 0, 0, 0}}};
    dc = CreateCompatibleDC(NULL);
    SelectObject(dc, CreateDIBSection(dc, &info, DIB_RGB_COLORS, &bits, NULL, 0));
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, RGB(0, 0, 0));
    const WCHAR *faces[] = {L"Tahoma", L"Segoe UI", L"Microsoft YaHei", L"Microsoft YaHei UI", L"SimSun", L"Malgun Gothic"};
    for (unsigned i = 0; i < sizeof faces / sizeof *faces; i++) gdi(faces[i]);

    IDWriteFactory2 *factory;
    IDWriteFontCollection *collection;
    IDWriteFontFallback *system;
    if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory2, (IUnknown **)&factory))) return 1;
    IDWriteFactory_GetSystemFontCollection((IDWriteFactory *)factory, &collection, FALSE);
    const WCHAR *families[] = {L"Microsoft YaHei", L"Malgun Gothic", L"Noto Sans CJK SC", L"Noto Sans CJK JP", L"Noto Sans CJK KR"};
    for (unsigned i = 0; i < sizeof families / sizeof *families; i++) {
        UINT32 index = 0;
        BOOL exists = FALSE;
        char name[256];
        IDWriteFontCollection_FindFamilyName(collection, families[i], &index, &exists);
        utf8(families[i], name, sizeof name);
        printf("{\"family\":\"%s\",\"exists\":%s}\n", name, exists ? "true" : "false");
    }
    if (FAILED(IDWriteFactory2_GetSystemFontFallback(factory, &system))) return 1;
    fallback(system, "han", L"\x4e2d\x6587\x7b80\x4f53\x6d4b\x8bd5", L"zh-CN");   /* 中文简体测试 */
    fallback(system, "han", L"\x4e2d\x6587\x7b80\x4f53\x6d4b\x8bd5", L"en-US");
    fallback(system, "hangul", L"\xd55c\xad6d\xc5b4", L"ko-KR");                  /* 한국어 */
    fallback(system, "hangul", L"\xd55c\xad6d\xc5b4", L"en-US");
    return 0;
}
