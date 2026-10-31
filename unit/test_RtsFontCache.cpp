/*
 * (C) 2026 see Authors.txt
 *
 * This file is part of MPC-HC.
 *
 * MPC-HC is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * MPC-HC is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#include "stdafx.h"
#include "TestUtil.h"
#include "../../src/Subtitles/RTS.h"
#include "../../src/SubPic/MemSubPic.h"
#include <algorithm>
#include <atomic>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

// The internal subtitle renderer's GDI font use (src/Subtitles/RTS.cpp): one
// HFONT per LOGFONT in RenderingCaches::fontCache (6e1cebc9cd) and
// CMyFont::GetLogFont, which fills the LOGFONT without the GetDC in operator
// <<= (d4f4f70dc7). Everything here builds against the source before those
// commits too, so the two counting tests can be seen failing on it.

using namespace testutil;

namespace
{
    // Points this exe's import table entry for a function at a replacement
    // until destroyed. MFC is linked statically, so its calls use that entry.
    class ImportPatch
    {
        PIMAGE_THUNK_DATA m_slot = nullptr;
        ULONG_PTR m_original = 0;

        void Write(ULONG_PTR value)
        {
            DWORD protect;
            VirtualProtect(m_slot, sizeof(*m_slot), PAGE_READWRITE, &protect);
            m_slot->u1.Function = value;
            VirtualProtect(m_slot, sizeof(*m_slot), protect, &protect);
        }

        void Find(const char* dll, const char* function)
        {
            BYTE* base = reinterpret_cast<BYTE*>(GetModuleHandleW(nullptr));
            auto nt = reinterpret_cast<PIMAGE_NT_HEADERS>(base + reinterpret_cast<PIMAGE_DOS_HEADER>(base)->e_lfanew);
            auto desc = reinterpret_cast<PIMAGE_IMPORT_DESCRIPTOR>(
                            base + nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress);
            for (; desc->Name; desc++) {
                if (_stricmp(reinterpret_cast<char*>(base + desc->Name), dll)) {
                    continue;
                }
                auto names = reinterpret_cast<PIMAGE_THUNK_DATA>(base + desc->OriginalFirstThunk);
                auto slots = reinterpret_cast<PIMAGE_THUNK_DATA>(base + desc->FirstThunk);
                for (; names->u1.AddressOfData; names++, slots++) {
                    if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) {
                        continue;
                    }
                    auto byName = reinterpret_cast<PIMAGE_IMPORT_BY_NAME>(base + names->u1.AddressOfData);
                    if (!strcmp(reinterpret_cast<char*>(byName->Name), function)) {
                        m_slot = slots;
                        return;
                    }
                }
            }
            throw std::runtime_error(std::string(dll) + "!" + function + " is not in the import table");
        }

    public:
        ImportPatch(const char* dll, const char* function, ULONG_PTR replacement)
        {
            Find(dll, function);
            m_original = m_slot->u1.Function;
            Write(replacement);
        }
        ~ImportPatch() { Write(m_original); }
        ImportPatch(const ImportPatch&) = delete;
        ImportPatch& operator=(const ImportPatch&) = delete;

        ULONG_PTR Original() const { return m_original; }
    };

    std::atomic<int> g_createFontCalls, g_getDCCalls;
    decltype(&::CreateFontIndirectW) g_realCreateFont;
    decltype(&::GetDC) g_realGetDC;

    HFONT WINAPI CountingCreateFont(const LOGFONTW* lf)
    {
        g_createFontCalls++;
        return g_realCreateFont(lf);
    }

    HDC WINAPI CountingGetDC(HWND hWnd)
    {
        g_getDCCalls++;
        return g_realGetDC(hWnd);
    }

    struct CallCounts {
        int createFont, getDC;
    };

    template <class Body>
    CallCounts CountCallsDuring(Body body)
    {
        ImportPatch font("gdi32.dll", "CreateFontIndirectW", reinterpret_cast<ULONG_PTR>(&CountingCreateFont));
        ImportPatch dc("user32.dll", "GetDC", reinterpret_cast<ULONG_PTR>(&CountingGetDC));
        g_realCreateFont = reinterpret_cast<decltype(g_realCreateFont)>(font.Original());
        g_realGetDC = reinterpret_cast<decltype(g_realGetDC)>(dc.Original());
        g_createFontCalls = 0;
        g_getDCCalls = 0;
        body();
        return { g_createFontCalls, g_getDCCalls };
    }

    std::string Script(const std::string& styles, const std::string& events)
    {
        return
            "[Script Info]\r\n"
            "ScriptType: v4.00+\r\n"
            "PlayResX: 640\r\n"
            "PlayResY: 360\r\n"
            "ScaledBorderAndShadow: yes\r\n"
            "\r\n"
            "[V4+ Styles]\r\n"
            "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\r\n"
            + styles +
            "\r\n"
            "[Events]\r\n"
            "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r\n"
            + events;
    }

    std::string Style(const char* name, const char* face, int size, int bold, int italic)
    {
        char line[256];
        sprintf_s(line, "Style: %s,%s,%d,&H00FFFFFF,&H000000FF,&H00202020,&H00000000,%d,%d,0,0,100,100,0,0,1,2,0,5,10,10,10,1\r\n",
                  name, face, size, bold, italic);
        return line;
    }

    class ScriptRenderer
    {
        static const int w = 640, h = 360;
        CCritSec m_lock;
        CRenderedTextSubtitle m_rts;
        std::vector<DWORD> m_bits;
        SubPicDesc m_spd;

    public:
        explicit ScriptRenderer(const std::string& script)
            : m_rts(&m_lock)
            , m_bits(size_t(w) * h)
        {
            if (!m_rts.Open(CString(WriteTemp(L"rts_font_cache.ass", script)), DEFAULT_CHARSET, _T("test"))) {
                throw std::runtime_error("the script did not open");
            }
            m_spd.type = MSP_RGB32;
            m_spd.w = w;
            m_spd.h = h;
            m_spd.bpp = 32;
            m_spd.pitch = w * 4;
            m_spd.bits = reinterpret_cast<BYTE*>(m_bits.data());
            m_spd.vidrect = { 0, 0, w, h };
        }

        const std::vector<DWORD>& Frame(double seconds)
        {
            std::fill(m_bits.begin(), m_bits.end(), 0xFF000000u);
            RECT bbox = {};
            m_rts.Render(m_spd, REFERENCE_TIME(seconds * 10000000), 24000.0 / 1001, bbox);
            return m_bits;
        }
    };

    bool HasInk(const std::vector<DWORD>& frame)
    {
        return std::any_of(frame.begin(), frame.end(), [](DWORD px) { return px != 0xFF000000u; });
    }

    const int kFrames = 100;
    const double kFrameSeconds = 1001.0 / 24000;

    std::string RotatingText()
    {
        return Script(Style("Default", "Arial", 32, 0, 0),
                      "Dialogue: 0,0:00:00.00,0:00:10.00,Default,,0,0,0,,{\\pos(320,180)\\t(\\frz350)}one two three four\r\n");
    }

    CallCounts RenderRotatingText()
    {
        ScriptRenderer renderer(RotatingText());
        std::vector<DWORD> first;
        std::vector<DWORD> last;
        CallCounts counts = CountCallsDuring([&] {
            first = renderer.Frame(kFrameSeconds / 2);
            for (int n = 1; n < kFrames; n++) {
                last = renderer.Frame(kFrameSeconds * n + kFrameSeconds / 2);
            }
        });
        if (!HasInk(first) || first == last) {
            throw std::runtime_error("the rotating text did not animate, so its rendering proves nothing");
        }
        return counts;
    }

    struct StyleCase {
        const char* name;
        std::vector<DWORD> pixels;
    };

    // One style per second, each differing from Base in a single LOGFONT field,
    // all through one renderer so they share its caches.
    std::string OneFieldStyles()
    {
        const char* const names[] = { "Base", "Bold", "Italic", "Size", "Face" };
        std::string styles = Style("Base", "Arial", 32, 0, 0)
                             + Style("Bold", "Arial", 32, -1, 0)
                             + Style("Italic", "Arial", 32, 0, -1)
                             + Style("Size", "Arial", 36, 0, 0)
                             + Style("Face", "Times New Roman", 32, 0, 0);
        std::string events;
        for (int i = 0; i < int(_countof(names)); i++) {
            char line[256];
            sprintf_s(line, "Dialogue: 0,0:00:%02d.00,0:00:%02d.00,%s,,0,0,0,,{\\pos(320,180)}Quick font test\r\n", i, i + 1, names[i]);
            events += line;
        }
        return Script(styles, events);
    }

    template <class Font, class = void>
    struct HasGetLogFont : std::false_type {};

    template <class Font>
    struct HasGetLogFont<Font, std::void_t<decltype(Font::GetLogFont(std::declval<const STSStyle&>(), std::declval<LOGFONT&>()))>>
        : std::true_type {};

    template <class Font>
    void CallGetLogFont(const STSStyle& style, LOGFONT& lf)
    {
        if constexpr (HasGetLogFont<Font>::value) {
            Font::GetLogFont(style, lf);
        }
    }

    LOGFONT ConstructorLogFont(const STSStyle& style)
    {
        LOGFONT lf;
        ZeroMemory(&lf, sizeof(lf));
        lf <<= style;
        lf.lfHeight = (LONG)(style.fontSize + 0.5);
        lf.lfOutPrecision = OUT_TT_PRECIS;
        lf.lfClipPrecision = CLIP_DEFAULT_PRECIS;
        lf.lfQuality = ANTIALIASED_QUALITY;
        lf.lfPitchAndFamily = DEFAULT_PITCH | FF_DONTCARE;
        if (lf.lfCharSet == 0) {
            lf.lfCharSet = DEFAULT_CHARSET;
        }
        return lf;
    }
}

TEST(RtsFontCache, ImportPatchSeesMfcAndDirectCalls)
{
    LOGFONT lf = {};
    lf.lfHeight = 20;
    wcscpy_s(lf.lfFaceName, L"Arial");
    CallCounts counts = CountCallsDuring([&] {
        CFont font;
        EXPECT_TRUE(font.CreateFontIndirect(&lf));
        HDC dc = ::GetDC(nullptr);
        EXPECT_NE(dc, nullptr);
        ReleaseDC(nullptr, dc);
    });
    EXPECT_EQ(counts.createFont, 1);
    EXPECT_EQ(counts.getDC, 1);
}

TEST(RtsFontCache, RenderingReusesOneFontAcrossFrames)
{
    const int calls = RenderRotatingText().createFont;
    RecordProperty("createFontCalls", calls);
    EXPECT_GE(calls, 1) << "no CreateFontIndirectW was counted, so the count is not seeing the renderer";
    EXPECT_LE(calls, 3) << "CreateFontIndirectW ran " << calls << " times over " << kFrames << " frames of one style";
}

TEST(RtsFontCache, RenderingDoesNotCallGetDC)
{
    const int calls = RenderRotatingText().getDC;
    RecordProperty("getDCCalls", calls);
    EXPECT_EQ(calls, 0) << "GetDC ran " << calls << " times over " << kFrames << " frames of one style";
}

TEST(RtsFontCache, StylesDifferingInOneFieldRenderDifferently)
{
    ScriptRenderer renderer(OneFieldStyles());
    std::vector<StyleCase> cases = { { "Base" }, { "Bold" }, { "Italic" }, { "Size" }, { "Face" } };
    for (size_t i = 0; i < cases.size(); i++) {
        cases[i].pixels = renderer.Frame(i + 0.5);
        EXPECT_TRUE(HasInk(cases[i].pixels)) << cases[i].name << " drew nothing";
    }
    for (size_t a = 0; a < cases.size(); a++) {
        for (size_t b = a + 1; b < cases.size(); b++) {
            EXPECT_TRUE(cases[a].pixels != cases[b].pixels) << cases[a].name << " and " << cases[b].name << " rendered the same pixels";
        }
    }
}

TEST(RtsFontCache, RenderingAFrameAgainGivesTheSamePixels)
{
    const std::string script = OneFieldStyles();
    ScriptRenderer renderer(script);
    const std::vector<DWORD> first = renderer.Frame(0.5);
    ASSERT_TRUE(HasInk(first));
    renderer.Frame(1.5);
    EXPECT_TRUE(first == renderer.Frame(0.5)) << "the same frame changed when rendered from the caches";

    ScriptRenderer fresh(script);
    EXPECT_TRUE(first == fresh.Frame(0.5)) << "a fresh renderer drew the frame differently";
}

TEST(RtsFontCache, GetLogFontMatchesTheOperatorAndFixedFields)
{
    if (!HasGetLogFont<CMyFont>::value) {
        GTEST_SKIP() << "this source has no CMyFont::GetLogFont";
    }

    std::vector<STSStyle> styles(8);
    styles[0].fontName = L"Arial";
    styles[0].fontSize = 39.4;
    styles[1].fontName = L"Arial";
    styles[1].fontSize = 39.5;
    styles[2].fontName = L"Times New Roman";
    styles[2].fontWeight = FW_BOLD;
    styles[2].fItalic = TRUE;
    styles[3].fontName = L"Tahoma";
    styles[3].fUnderline = TRUE;
    styles[3].fStrikeOut = TRUE;
    styles[4].fontName = L"A font name that is longer than LF_FACESIZE can hold";
    styles[5].fontName = L"MS Gothic";
    styles[5].charSet = SHIFTJIS_CHARSET;
    styles[6].fontName = L"Arial";
    styles[6].charSet = ANSI_CHARSET;
    styles[7].fontName = L"";

    for (size_t i = 0; i < styles.size(); i++) {
        SCOPED_TRACE(mpctest::ToUtf8(styles[i].fontName));
        const LOGFONT expected = ConstructorLogFont(styles[i]);
        LOGFONT actual;
        memset(&actual, 0xCD, sizeof(actual));
        CallGetLogFont<CMyFont>(styles[i], actual);

        EXPECT_EQ(actual.lfHeight, expected.lfHeight);
        EXPECT_EQ(actual.lfWidth, expected.lfWidth);
        EXPECT_EQ(actual.lfEscapement, expected.lfEscapement);
        EXPECT_EQ(actual.lfOrientation, expected.lfOrientation);
        EXPECT_EQ(actual.lfWeight, expected.lfWeight);
        EXPECT_EQ(actual.lfItalic, expected.lfItalic);
        EXPECT_EQ(actual.lfUnderline, expected.lfUnderline);
        EXPECT_EQ(actual.lfStrikeOut, expected.lfStrikeOut);
        EXPECT_EQ(actual.lfCharSet, expected.lfCharSet);
        EXPECT_EQ(actual.lfOutPrecision, expected.lfOutPrecision);
        EXPECT_EQ(actual.lfClipPrecision, expected.lfClipPrecision);
        EXPECT_EQ(actual.lfQuality, expected.lfQuality);
        EXPECT_EQ(actual.lfPitchAndFamily, expected.lfPitchAndFamily);
        EXPECT_STREQ(actual.lfFaceName, expected.lfFaceName);
        EXPECT_EQ(memcmp(&actual, &expected, sizeof(LOGFONT)), 0) << "CFontKey compares these bytes";
    }

    LOGFONT truncated;
    CallGetLogFont<CMyFont>(styles[4], truncated);
    EXPECT_EQ(wcslen(truncated.lfFaceName), size_t(LF_FACESIZE - 1));
}
