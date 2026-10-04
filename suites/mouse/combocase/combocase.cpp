// combocase.cpp - minimal case for clsid2/mpc-hc issue #4276, with no MPC-HC code in it.
//
// Four CBS_DROPDOWNLIST comboboxes with the same items, on comctl32 v6:
//   101 native          untouched; comctl32 paints it.
//   102 custom          full WM_PAINT that draws the face from GetWindowText, the way the
//                       themed CMPCThemeComboBox::OnPaint does.
//   105 native+inval    comctl32 paints it, but it is invalidated whenever the pointer
//                       enters or leaves it, the way CMPCThemeComboBox::checkHover does
//                       in every theme (and the erase is suppressed, as MPC-HC does).
//   106 custom+inval    102 and 105 together, which is the modern theme.
// The lines on the right show what each combo really has selected (CB_GETCURSEL),
// refreshed 20 times a second, so the face can be compared against the truth.
//
// To try it: open a combo, sweep the pointer over an item straight away, then click the
// combo again (or elsewhere) to close it without picking.

#define UNICODE
#define _UNICODE
#include <windows.h>
#include <windowsx.h>
#include <commctrl.h>
#include <stdio.h>
#include <initializer_list>

#pragma comment(lib, "comctl32.lib")
#pragma comment(linker, "/manifestdependency:\"type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")

enum { IDC_NATIVE = 101, IDC_CUSTOM = 102, IDC_STATUS = 103, IDC_NATIVE_INVAL = 105, IDC_CUSTOM_INVAL = 106 };
enum { F_CUSTOM_PAINT = 1, F_INVALIDATE_ON_LEAVE = 2 };

static const wchar_t* kItems[] = {
    L"Blue Highway", L"Bodoni MT", L"Bodoni MT Black", L"Bodoni MT Condensed",
    L"Bodoni MT Poster Compressed", L"Book Antiqua", L"Bookman Old Style", L"Bookshelf Symbol 7",
    L"Bradley Hand ITC", L"Bree Serif Regular", L"Britannic Bold", L"Broadway",
    L"Brooklyn Kid", L"Brush Script MT Italic", L"Calibri", L"Calibri Light",
};

static const struct { int id; const wchar_t* name; DWORD flags; } kCombos[] = {
    { IDC_NATIVE, L"native", 0 },
    { IDC_CUSTOM, L"custom", F_CUSTOM_PAINT },
    { IDC_NATIVE_INVAL, L"native+inval", F_INVALIDATE_ON_LEAVE },
    { IDC_CUSTOM_INVAL, L"custom+inval", F_CUSTOM_PAINT | F_INVALIDATE_ON_LEAVE },
};

static HFONT g_font;
static int g_selChange[_countof(kCombos)];

static bool IsHover(HWND h) { return GetPropW(h, L"hover") != nullptr; }
static void SetHover(HWND h, bool hover)
{
    if (hover) {
        SetPropW(h, L"hover", (HANDLE)1);
    } else {
        RemovePropW(h, L"hover");
    }
}

static void PaintCustom(HWND h)
{
    // Mirrors the no-edit branch of CMPCThemeComboBox::OnPaint: the whole face is redrawn
    // on every WM_PAINT, and the text is whatever GetWindowText returns at that moment.
    PAINTSTRUCT ps;
    HDC dc = BeginPaint(h, &ps);
    RECT r;
    GetClientRect(h, &r);
    wchar_t text[256] = L"";
    GetWindowTextW(h, text, 256);

    COMBOBOXINFO info = { sizeof(info) };
    GetComboBoxInfo(h, &info);
    bool listVisible = info.hwndList && IsWindowVisible(info.hwndList);

    COLORREF bk = RGB(45, 45, 45);
    if (listVisible || info.stateButton == STATE_SYSTEM_PRESSED) {
        bk = RGB(95, 95, 95);
    } else if (IsHover(h)) {
        bk = RGB(70, 70, 70);
    }
    HBRUSH fill = CreateSolidBrush(bk);
    FillRect(dc, &r, fill);
    DeleteObject(fill);

    HGDIOBJ oldFont = SelectObject(dc, g_font);
    SetBkColor(dc, bk);
    SetTextColor(dc, RGB(255, 255, 255));
    RECT rt = r;
    rt.right = info.rcItem.right;
    InflateRect(&rt, -3, -3);
    DrawTextW(dc, text, -1, &rt, DT_VCENTER | DT_LEFT | DT_SINGLELINE | DT_NOPREFIX);
    RECT ra = info.rcButton;
    DrawTextW(dc, L"v", 1, &ra, DT_VCENTER | DT_CENTER | DT_SINGLELINE);
    SelectObject(dc, oldFont);

    HBRUSH frame = CreateSolidBrush(RGB(130, 130, 130));
    FrameRect(dc, &r, frame);
    DeleteObject(frame);
    EndPaint(h, &ps);
}

static LRESULT CALLBACK ComboProc(HWND h, UINT m, WPARAM w, LPARAM l, UINT_PTR id, DWORD_PTR flags)
{
    switch (m) {
    case WM_ERASEBKGND:
        return 1;   // CMPCThemeComboBox::OnEraseBkgnd returns TRUE in every theme
    case WM_PAINT:
        if (flags & F_CUSTOM_PAINT) {
            PaintCustom(h);
            return 0;
        }
        break;
    case WM_MOUSEMOVE: {
        POINT p = { GET_X_LPARAM(l), GET_Y_LPARAM(l) };
        RECT r;
        GetClientRect(h, &r);
        bool hover = !!PtInRect(&r, p);
        if (hover != IsHover(h)) {
            SetHover(h, hover);
            InvalidateRect(h, nullptr, TRUE);
        }
        break;
    }
    case WM_MOUSELEAVE:
        // comctl32 arms leave tracking for its own hot state, so this arrives without
        // us asking. CMPCThemeComboBox::OnMouseLeave answers it with checkHover, which
        // invalidates the whole combo.
        if ((flags & F_INVALIDATE_ON_LEAVE) && IsHover(h)) {
            SetHover(h, false);
            InvalidateRect(h, nullptr, TRUE);
        }
        break;
    case CB_SETCURSEL: {
        LRESULT ret = DefSubclassProc(h, m, w, l);
        RedrawWindow(h, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW | RDW_ERASE);
        return ret;
    }
    case WM_NCDESTROY:
        RemovePropW(h, L"hover");
        RemoveWindowSubclass(h, ComboProc, id);
        break;
    }
    return DefSubclassProc(h, m, w, l);
}

static LRESULT CALLBACK MainProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    switch (m) {
    case WM_CREATE: {
        HDC screen = GetDC(nullptr);
        int dpi = GetDeviceCaps(screen, LOGPIXELSX);
        ReleaseDC(nullptr, screen);
        auto S = [dpi](int v) { return MulDiv(v, dpi, 96); };

        NONCLIENTMETRICSW ncm = { sizeof(ncm) };
        SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0);
        g_font = CreateFontIndirectW(&ncm.lfMessageFont);

        auto Make = [&](const wchar_t* cls, const wchar_t* text, DWORD style, int x, int y, int cx, int cy, int id) {
            HWND child = CreateWindowExW(0, cls, text, WS_CHILD | WS_VISIBLE | style,
                                         S(x), S(y), S(cx), S(cy), h, (HMENU)(INT_PTR)id, nullptr, nullptr);
            SendMessageW(child, WM_SETFONT, (WPARAM)g_font, TRUE);
            return child;
        };
        int y = 12;
        for (auto& c : kCombos) {
            wchar_t label[64];
            swprintf_s(label, L"%s:", c.name);
            Make(L"STATIC", label, SS_LEFT, 12, y + 4, 86, 20, -1);
            HWND combo = Make(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, 100, y, 220, 400, c.id);
            for (auto item : kItems) {
                SendMessageW(combo, CB_ADDSTRING, 0, (LPARAM)item);
            }
            SendMessageW(combo, CB_SETCURSEL, 4, 0);
            if (c.flags) {
                SetWindowSubclass(combo, ComboProc, 1, c.flags);
            }
            y += 40;
        }
        Make(L"STATIC", L"", SS_LEFT, 336, 12, 420, 170, IDC_STATUS);
        SetTimer(h, 1, 50, nullptr);
        return 0;
    }
    case WM_COMMAND:
        if (HIWORD(w) == CBN_SELCHANGE) {
            for (int i = 0; i < _countof(kCombos); i++) {
                if (LOWORD(w) == kCombos[i].id) {
                    g_selChange[i]++;
                }
            }
        }
        break;
    case WM_TIMER: {
        wchar_t now[1200] = L"", was[1200];
        for (int i = 0; i < _countof(kCombos); i++) {
            HWND combo = GetDlgItem(h, kCombos[i].id);
            int sel = (int)SendMessageW(combo, CB_GETCURSEL, 0, 0);
            wchar_t item[128] = L"(none)", line[300];
            if (sel >= 0) {
                SendMessageW(combo, CB_GETLBTEXT, sel, (LPARAM)item);
            }
            swprintf_s(line, L"%s: selected = %d \"%s\", CBN_SELCHANGE = %d\r\n\r\n", kCombos[i].name, sel, item, g_selChange[i]);
            wcscat_s(now, line);
        }
        GetDlgItemTextW(h, IDC_STATUS, was, 1200);
        if (wcscmp(now, was) != 0) {
            SetDlgItemTextW(h, IDC_STATUS, now);
        }
        return 0;
    }
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int show)
{
    SetProcessDPIAware();
    INITCOMMONCONTROLSEX icc = { sizeof(icc), ICC_STANDARD_CLASSES };
    InitCommonControlsEx(&icc);

    WNDCLASSW wc = {};
    wc.lpfnWndProc = MainProc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    wc.lpszClassName = L"ComboCase";
    RegisterClassW(&wc);

    HDC screen = GetDC(nullptr);
    int dpi = GetDeviceCaps(screen, LOGPIXELSX);
    ReleaseDC(nullptr, screen);
    HWND main = CreateWindowExW(0, L"ComboCase", L"Combo hover case (issue 4276)", WS_OVERLAPPEDWINDOW,
                                CW_USEDEFAULT, CW_USEDEFAULT, MulDiv(780, dpi, 96), MulDiv(460, dpi, 96),
                                nullptr, nullptr, inst, nullptr);
    ShowWindow(main, show);

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        if (!IsDialogMessageW(main, &msg)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    return 0;
}
