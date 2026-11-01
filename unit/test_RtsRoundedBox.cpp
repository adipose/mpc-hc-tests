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
#include <set>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

// The rounded opaque box of the player's default subtitle style (#4361,
// CSubtitleBG in src/Subtitles/RTS.cpp), rendered through the same calls
// CMainFrame::ApplySubtitleRenderingParameters makes.
//
// Everything builds against a source without the option too, where SetRounded
// does nothing and the tests skip. With MPCTEST_ROUNDEDBOX_DUMP set to a folder,
// RoundedBox.DumpFrames writes every case as a .bmp and one "name hash" line to
// frames.txt, so the option-off lines can be compared with an unpatched build.

using namespace testutil;

namespace
{
    const int kWidth = 1280, kHeight = 720;
    const DWORD kClear = 0xFF000000u;

    template <class Rts, class = void>
    struct HasRoundedOption : std::false_type {};

    template <class Rts>
    struct HasRoundedOption<Rts, std::void_t<decltype(std::declval<Rts&>().SetRoundedOpaqueBox(true))>>
        : std::true_type {};

    template <class Rts>
    void SetRounded(Rts& rts, bool rounded)
    {
        if constexpr (HasRoundedOption<Rts>::value) {
            rts.SetRoundedOpaqueBox(rounded);
        }
    }

    std::string Srt(const std::string& text)
    {
        return "1\r\n00:00:01,000 --> 00:00:05,000\r\n" + text + "\r\n\r\n";
    }

    // A script with no styles of its own, so that its Default is the player's
    std::string Ass(const std::string& text)
    {
        return
            "[Script Info]\r\n"
            "ScriptType: v4.00+\r\n"
            "\r\n"
            "[Events]\r\n"
            "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r\n"
            "Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,," + text + "\r\n";
    }

    // Two seconds of each: Default, then Sign, both with styles of the script's own
    std::string AssWithStyles()
    {
        const std::string style = ",Arial,20,&H0000FFFF,&H000000FF,&H00FF0000,&H00000000,0,0,0,0,100,100,0,0,1,3,0,2,10,10,10,1\r\n";
        return
            "[Script Info]\r\n"
            "ScriptType: v4.00+\r\n"
            "\r\n"
            "[V4+ Styles]\r\n"
            "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\r\n"
            "Style: Default" + style +
            "Style: Sign" + style +
            "\r\n"
            "[Events]\r\n"
            "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r\n"
            "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Line in Default\r\n"
            "Dialogue: 0,0:00:02.00,0:00:03.00,Sign,,0,0,0,,Line in Sign\r\n";
    }

    STSStyle BoxStyle(double border = 2.0, double shadow = 0.0)
    {
        STSStyle style;
        style.fontName = L"Arial";
        style.fontSize = 18;
        style.borderStyle = 1;
        style.outlineWidthX = style.outlineWidthY = border;
        style.shadowDepthX = style.shadowDepthY = shadow;
        style.colors[2] = 0x00202020;
        style.colors[3] = 0x00404040;
        style.alpha[3] = 0x00;
        return style;
    }

    enum class Override { None, Default, All };

    struct Options {
        STSStyle style = BoxStyle();
        Override override = Override::None;
    };

    using Frame = std::vector<DWORD>;

    Frame RenderDoc(const std::string& doc, bool rounded, const Options& options = Options(), double seconds = 1.5)
    {
        const bool isAss = doc[0] == '[';
        CCritSec lock;
        CRenderedTextSubtitle rts(&lock);
        if (!rts.Open(CString(WriteTemp(isAss ? L"rts_rounded_box.ass" : L"rts_rounded_box.srt", doc)), DEFAULT_CHARSET, _T("test"))) {
            throw std::runtime_error("the subtitle did not open");
        }

        // CMainFrame::ApplySubtitleRenderingParameters
        STSStyle style = options.style;
        if (rts.m_bUsingPlayerDefaultStyle) {
            rts.SetDefaultStyle(style);
        }
        rts.SetOverride(options.override == Override::Default, options.override == Override::All, style);
        SetRounded(rts, rounded);
        rts.Deinit();

        Frame bits(size_t(kWidth) * kHeight, kClear);
        SubPicDesc spd;
        spd.type = MSP_RGB32;
        spd.w = kWidth;
        spd.h = kHeight;
        spd.bpp = 32;
        spd.pitch = kWidth * 4;
        spd.bits = reinterpret_cast<BYTE*>(bits.data());
        spd.vidrect = { 0, 0, kWidth, kHeight };

        RECT bbox = {};
        rts.Render(spd, REFERENCE_TIME(seconds * 10000000), 24000.0 / 1001, bbox);
        return bits;
    }

    DWORD At(const Frame& f, int x, int y) { return f[size_t(y) * kWidth + x]; }

    // right and bottom exclusive; empty when nothing was drawn
    CRect Ink(const Frame& f)
    {
        CRect r(kWidth, kHeight, 0, 0);
        for (int y = 0; y < kHeight; y++) {
            for (int x = 0; x < kWidth; x++) {
                if (At(f, x, y) != kClear) {
                    r.left = std::min<LONG>(r.left, x);
                    r.top = std::min<LONG>(r.top, y);
                    r.right = std::max<LONG>(r.right, x + 1);
                    r.bottom = std::max<LONG>(r.bottom, y + 1);
                }
            }
        }
        return r.left < r.right ? r : CRect();
    }

    int Differing(const Frame& a, const Frame& b)
    {
        int n = 0;
        for (size_t i = 0; i < a.size(); i++) {
            n += a[i] != b[i];
        }
        return n;
    }

    int Count(const Frame& f, DWORD color)
    {
        return int(std::count(f.begin(), f.end(), color));
    }

    bool TopCornersAreRound(const Frame& f)
    {
        const CRect r = Ink(f);
        return !r.IsRectEmpty() && At(f, r.left, r.top) == kClear && At(f, r.right - 1, r.top) == kClear;
    }

    bool BottomCornersAreRound(const Frame& f)
    {
        const CRect r = Ink(f);
        return !r.IsRectEmpty() && At(f, r.left, r.bottom - 1) == kClear && At(f, r.right - 1, r.bottom - 1) == kClear;
    }

    // Ink of one row, right exclusive; left > right when the row is empty
    void RowInk(const Frame& f, int y, int& left, int& right)
    {
        left = kWidth;
        right = 0;
        for (int x = 0; x < kWidth; x++) {
            if (At(f, x, y) != kClear) {
                left = std::min(left, x);
                right = x + 1;
            }
        }
    }

    // Goes by rows rather than by the ink's corners, because lines of different widths leave those clear anyway
    bool CornersOfTheEndRowsAreRound(const Frame& f)
    {
        const CRect r = Ink(f);
        if (r.IsRectEmpty()) {
            return false;
        }
        int left, right, nextLeft, nextRight;
        RowInk(f, r.top, left, right);
        RowInk(f, r.top + 4, nextLeft, nextRight);
        const bool top = nextLeft < left && nextRight > right;
        RowInk(f, r.bottom - 1, left, right);
        RowInk(f, r.bottom - 5, nextLeft, nextRight);
        return top && nextLeft < left && nextRight > right;
    }

    struct FallbackCase {
        const char* name;
        const char* text;
    };

    // Each of these is one shape, unlike the fallbacks below
    const FallbackCase kUnified[] = {
        { "large over small", "{\\fs30}first line\\N{\\fs16}second line" },
        { "small over large", "{\\fs16}first line\\N{\\fs30}second line" },
        { "size change in a line", "first {\\fs30}large{\\fs18} line" },
        { "size change in one of two lines", "first {\\fs30}large{\\fs18} line\\Nsecond line" },
        { "font differs between lines", "{\\fnTimes New Roman}first line\\N{\\fnArial}second line" },
        { "scale differs between lines", "{\\fscx150\\fscy120}first line\\N{\\fscx100\\fscy100}second line" },
        { "spacing differs between lines", "{\\fsp3}first line\\N{\\fsp0}second line" },
        { "border differs between lines", "{\\bord8}first line\\N{\\bord2}second line" },
        { "border differs in a line", "{\\bord8}first {\\bord2}second" },
        { "size and border differ", "{\\fs30\\bord6}first line\\N{\\fs16\\bord2}second line" },
    };

    // Each of these can't be one shape, so the option must change nothing at all
    const FallbackCase kFallbacks[] = {
        { "outline colour differs in a line", "{\\3c&H0000FF&}first {\\3c&H00FF00&}second" },
        { "outline colour differs between lines", "{\\3c&H0000FF&}first line\\N{\\3c&H00FF00&}second line" },
        { "shadow colour differs between lines", "{\\4c&H0000FF&}first line\\N{\\4c&H00FF00&}second line" },
        { "outline alpha differs between lines", "{\\3a&H80&}first line\\N{\\3a&H00&}second line" },
        { "shadow depth differs between lines", "{\\shad4}first line\\N{\\shad2}second line" },
        { "shadow depth differs in a line", "{\\shad4}first {\\shad2}second" },
        { "border on one line only", "{\\bord0}first line\\N{\\bord2}second line" },
        { "rotation differs between lines", "{\\frz5}first line\\N{\\frz0}second line" },
        { "shear differs between lines", "{\\fax0.3}first line\\N{\\fax0}second line" },
        { "blur differs between lines", "{\\blur2}first line\\N{\\blur0}second line" },
        { "ko karaoke", "{\\ko100}first {\\ko100}second" },
        { "k karaoke", "{\\k100}first {\\k100}second" },
        { "ko karaoke on each line", "{\\ko100}first line\\N{\\ko100}second line" },
        { "inverse clip", "{\\iclip(0,0,192,200)}first line\\Nsecond line" },
        { "empty line", "first line\\N\\Nsecond line" },
        { "leading empty line", "\\Nfirst line" },
        { "whitespace line", "first line\\N \\Nsecond line" },
    };

    void ExpectFallbackIsUnchanged(const Options& options)
    {
        for (const FallbackCase& c : kFallbacks) {
            for (const std::string& doc : { Srt(c.text), Ass(c.text) }) {
                SCOPED_TRACE(std::string(c.name) + (doc[0] == '[' ? " (ass)" : " (srt)"));
                const Frame off = RenderDoc(doc, false, options);
                const Frame on = RenderDoc(doc, true, options);
                ASSERT_FALSE(Ink(off).IsRectEmpty()) << "nothing was drawn";
                EXPECT_EQ(Differing(on, off), 0) << "ink " << Ink(on).Width() << "x" << Ink(on).Height()
                                                 << " with the option, " << Ink(off).Width() << "x" << Ink(off).Height() << " without";
            }
        }
    }
}

#define SKIP_WITHOUT_THE_OPTION() \
    if (!HasRoundedOption<CRenderedTextSubtitle>::value) { \
        GTEST_SKIP() << "this source has no SetRoundedOpaqueBox"; \
    }

TEST(RoundedBox, RoundsSingleAndMultipleLines)
{
    SKIP_WITHOUT_THE_OPTION();
    for (const char* text : { "A single line", "The first line\\Nof two" }) {
        for (const std::string& doc : { Srt(text), Ass(text) }) {
            SCOPED_TRACE(doc);
            const Frame off = RenderDoc(doc, false);
            const Frame on = RenderDoc(doc, true);
            EXPECT_FALSE(TopCornersAreRound(off));
            EXPECT_TRUE(TopCornersAreRound(on));
            EXPECT_TRUE(BottomCornersAreRound(on));
        }
    }
}

TEST(RoundedBox, OptionHasNoEffectOnAnOutlineStyle)
{
    SKIP_WITHOUT_THE_OPTION();
    Options outline;
    outline.style.borderStyle = 0;
    const std::string doc = Srt("A line of text\\Nand a second");
    EXPECT_EQ(Differing(RenderDoc(doc, true, outline), RenderDoc(doc, false, outline)), 0);
}

TEST(RoundedBox, FallbackLaysOutAsWithTheOptionOff)
{
    SKIP_WITHOUT_THE_OPTION();
    ExpectFallbackIsUnchanged(Options());
}

TEST(RoundedBox, FallbackLaysOutAsWithTheOptionOffWithShadowOnly)
{
    SKIP_WITHOUT_THE_OPTION();
    Options shadowOnly;
    shadowOnly.style = BoxStyle(0.0, 2.0);
    ExpectFallbackIsUnchanged(shadowOnly);
}

TEST(RoundedBox, FallbackLaysOutAsWithTheOptionOffWithAThickBorder)
{
    SKIP_WITHOUT_THE_OPTION();
    Options thick;
    thick.style = BoxStyle(6.0, 3.0);
    thick.style.alpha[2] = 0x60;
    ExpectFallbackIsUnchanged(thick);
}

TEST(RoundedBox, MixedSizesAndBordersDrawOneShape)
{
    SKIP_WITHOUT_THE_OPTION();
    for (const FallbackCase& c : kUnified) {
        for (const std::string& doc : { Srt(c.text), Ass(c.text) }) {
            SCOPED_TRACE(std::string(c.name) + (doc[0] == '[' ? " (ass)" : " (srt)"));
            EXPECT_NE(Differing(RenderDoc(doc, true), RenderDoc(doc, false)), 0) << "the option changed nothing";
            EXPECT_TRUE(CornersOfTheEndRowsAreRound(RenderDoc(doc, true)));

            // Without the text and half transparent, one shape is one value wherever the box is. A gap
            // would show as a clear pixel, and boxes drawn twice as a darker one.
            Options options;
            options.style.alpha[0] = 0xFF;
            options.style.alpha[2] = 0x80;
            const Frame on = RenderDoc(doc, true, options);
            const CRect r = Ink(on);
            ASSERT_FALSE(r.IsRectEmpty());
            const DWORD box = At(on, r.CenterPoint().x, r.CenterPoint().y);
            for (int y = r.top + 1; y < r.bottom - 1; y++) { // the end rows can be antialiased
                EXPECT_EQ(At(on, r.CenterPoint().x, y), box) << "not the same box at y=" << y;
            }
            int darker = 0;
            for (DWORD px : on) {
                darker += (px >> 24) < (box >> 24);
            }
            EXPECT_EQ(darker, 0) << "pixels drawn over twice";
        }
    }
}

// The smallest line's radius: all corners fit it, so the large line's are no rounder
TEST(RoundedBox, RadiusComesFromTheSmallestLine)
{
    SKIP_WITHOUT_THE_OPTION();
    // How far the top row starts from the box's side, which is the radius of the corner
    const auto cornerInset = [](const std::string& doc) {
        const Frame f = RenderDoc(doc, true);
        const CRect r = Ink(f);
        int left, right, widestLeft = kWidth;
        for (int y = r.top; y < r.bottom; y++) {
            RowInk(f, y, left, right);
            widestLeft = std::min(widestLeft, left);
        }
        RowInk(f, r.top, left, right);
        return left - widestLeft;
    };
    // A large line over a small one, against a large line alone and a small line alone
    const int mixed = cornerInset(Srt("{\\fs30}first line that is the widest\\N{\\fs12}second"));
    const int largeAlone = cornerInset(Srt("{\\fs30}first line that is the widest"));
    const int smallAlone = cornerInset(Srt("{\\fs12}first line that is the widest"));
    EXPECT_GT(largeAlone, smallAlone * 2);
    EXPECT_GT(mixed, 0) << "square corners";
    EXPECT_NEAR(mixed, smallAlone, 2);
}

// The narrower wrap width of a rounded box must not apply to a fallback either
TEST(RoundedBox, FallbackWrapsAsWithTheOptionOff)
{
    SKIP_WITHOUT_THE_OPTION();
    Options options;
    options.style.marginRect = CRect(38, 20, 38, 20);
    std::string text = "{\\3c&H0000FF&}first ";
    for (int words = 1; words <= 60; words++) {
        text += "{\\3c&H00FF00&}word ";
        const std::string doc = Srt(text);
        SCOPED_TRACE(words);
        EXPECT_EQ(Differing(RenderDoc(doc, true, options), RenderDoc(doc, false, options)), 0);
    }
}

TEST(RoundedBox, LinesJoinWithoutAGapOrOverlapAtAnyLineSpacing)
{
    SKIP_WITHOUT_THE_OPTION();
    const char* const text = "HHHHHHHHHHHHHHHHHHHH\\NHHHHHHHHHHHHHHHHHHHH\\NHHHHHHHHHHHHHHHHHHHH";
    for (double border : { 1.0, 2.0, 3.0, 5.0, 8.0, 12.0 }) {
        for (BYTE alpha : { BYTE(0x00), BYTE(0x80) }) {
            for (const std::string& doc : { Srt(text), Ass(text) }) {
                SCOPED_TRACE(testing::Message() << "border " << border << " alpha " << int(alpha) << (doc[0] == '[' ? " ass" : " srt"));
                Options options;
                options.style = BoxStyle(border);
                options.style.alpha[2] = alpha;

                const Frame on = RenderDoc(doc, true, options);
                const CRect r = Ink(on);
                ASSERT_FALSE(r.IsRectEmpty());
                EXPECT_TRUE(TopCornersAreRound(on));

                // A column through the side padding, clear of the text and the corners
                std::set<DWORD> values;
                for (int y = r.top + r.Height() / 4; y < r.bottom - r.Height() / 4; y++) {
                    values.insert(At(on, r.left + 2, y));
                }
                EXPECT_EQ(values.size(), size_t(1)) << "the box's side changes along a seam between lines";
                EXPECT_EQ(values.count(kClear), size_t(0));

                // The middle of the box, through the text, is never left clear
                for (int y = r.top; y < r.bottom; y++) {
                    EXPECT_NE(At(on, r.CenterPoint().x, y), kClear) << "gap at y=" << y;
                }
            }
        }
    }
}

// Keeps the uniform side checked above meaningful: the square boxes do overlap
TEST(RoundedBox, TransparentSquareBoxesOverlap)
{
    Options options;
    options.style = BoxStyle(6.0);
    options.style.alpha[2] = 0x80;
    const std::string doc = Ass("HHHHHHHHHHHHHHHHHHHH\\NHHHHHHHHHHHHHHHHHHHH");

    const Frame off = RenderDoc(doc, false, options);
    const CRect r = Ink(off);
    std::set<DWORD> values;
    for (int y = r.top; y < r.bottom; y++) {
        values.insert(At(off, r.left + 1, y));
    }
    EXPECT_GE(values.size(), size_t(2)) << "the square boxes no longer overlap, so this proves nothing";
}

// A box may reach past the margin by its border, as it does without the option
TEST(RoundedBox, LongLinesStayInsideTheMargins)
{
    SKIP_WITHOUT_THE_OPTION();
    Options options;
    options.style.marginRect = CRect(38, 20, 38, 20); // of the 384 wide default script
    const int margin = kWidth * 38 / 384;
    const int border = 2;

    // Wrapping balances the lines, so only a text that just fits on one line reaches the full
    // width. Widen it in small steps until it wraps.
    std::string text;
    for (int words = 0; words < 30; words++) {
        text += "a ";
    }
    int checked = 0;
    for (double scale = 80.0; scale < 125.0; scale += 0.2) {
        options.style.fontScaleX = scale;
        for (const std::string& doc : { Srt(text), Ass(text) }) {
            SCOPED_TRACE(testing::Message() << "scale " << scale << (doc[0] == '[' ? " ass" : " srt"));
            const CRect r = Ink(RenderDoc(doc, true, options));
            ASSERT_FALSE(r.IsRectEmpty());
            EXPECT_GE(r.left, margin - border - 2);
            EXPECT_LE(r.right, kWidth - margin + border + 2);
            checked += r.Width() >= kWidth - 2 * margin - 10;
        }
    }
    EXPECT_GT(checked, 0) << "no line came near the full wrap width, so this proves nothing";
}

TEST(RoundedBox, OverrideAllStylesRoundsAScriptWithItsOwnStyles)
{
    SKIP_WITHOUT_THE_OPTION();
    Options all;
    all.override = Override::All;
    for (double seconds : { 1.5, 2.5 }) {
        SCOPED_TRACE(seconds);
        EXPECT_FALSE(TopCornersAreRound(RenderDoc(AssWithStyles(), false, all, seconds)));
        EXPECT_TRUE(TopCornersAreRound(RenderDoc(AssWithStyles(), true, all, seconds)));
    }
}

TEST(RoundedBox, OverrideDefaultStyleRoundsOnlyDefaultEntries)
{
    SKIP_WITHOUT_THE_OPTION();
    Options def;
    def.override = Override::Default;
    EXPECT_TRUE(TopCornersAreRound(RenderDoc(AssWithStyles(), true, def, 1.5)));
    EXPECT_EQ(Differing(RenderDoc(AssWithStyles(), true, def, 2.5), RenderDoc(AssWithStyles(), false, def, 2.5)), 0)
            << "an entry that keeps the script's own style changed";
}

TEST(RoundedBox, AScriptWithItsOwnStylesIsLeftAloneWithoutAnOverride)
{
    SKIP_WITHOUT_THE_OPTION();
    for (double seconds : { 1.5, 2.5 }) {
        SCOPED_TRACE(seconds);
        EXPECT_EQ(Differing(RenderDoc(AssWithStyles(), true, Options(), seconds), RenderDoc(AssWithStyles(), false, Options(), seconds)), 0);
    }
}

TEST(RoundedBox, TextColoursKeepTheRoundedBox)
{
    SKIP_WITHOUT_THE_OPTION();
    const DWORD yellow = 0x00FFFF00; // alpha 0 is opaque in the subpic
    const struct {
        const char* name;
        const char* colored;
        const char* plain;
    } cases[] = {
        { "word", "One <font color=\"#ffff00\">coloured</font> word", "One coloured word" },
        { "word on a line", "First line\r\nwith <font color=\"#ffff00\">one</font> word", "First line\r\nwith one word" },
        { "whole line", "<font color=\"#ffff00\">The first line</font>\r\nThe second line", "The first line\r\nThe second line" },
        { "both lines", "<font color=\"#ffff00\">The first line</font>\r\n<font color=\"#00ffff\">The second line</font>", "The first line\r\nThe second line" },
        { "fill alpha", "One {\\1a&H80&}see-through{\\1a&H00&} word", "One see-through word" },
    };
    for (const auto& c : cases) {
        SCOPED_TRACE(c.name);
        const Frame colored = RenderDoc(Srt(c.colored), true);
        const Frame plain = RenderDoc(Srt(c.plain), true);
        EXPECT_TRUE(TopCornersAreRound(colored));
        EXPECT_TRUE(BottomCornersAreRound(colored));
        EXPECT_EQ(Ink(colored), Ink(plain)) << "the box moved or changed size";
        EXPECT_GT(Differing(colored, plain), 0) << "the text colour was lost";
        // The side padding, clear of the text, is bare box in both
        const CRect r = Ink(plain);
        for (int y = r.top; y < r.bottom; y++) {
            EXPECT_EQ(At(colored, r.left + 3, y), At(plain, r.left + 3, y)) << "the box changed at y=" << y;
            EXPECT_EQ(At(colored, r.right - 4, y), At(plain, r.right - 4, y)) << "the box changed at y=" << y;
        }
    }
    EXPECT_GT(Count(RenderDoc(Srt(cases[0].colored), true), yellow), 0) << "no fully yellow pixel in the text";
}

TEST(RoundedBox, DumpFrames)
{
    wchar_t dir[MAX_PATH];
    if (!GetEnvironmentVariableW(L"MPCTEST_ROUNDEDBOX_DUMP", dir, _countof(dir))) {
        GTEST_SKIP() << "MPCTEST_ROUNDEDBOX_DUMP is not set";
    }

    FILE* list = nullptr;
    ASSERT_EQ(_wfopen_s(&list, (CStringW(dir) + L"\\frames.txt").GetString(), L"w"), 0);

    auto dump = [&](CStringA name, const std::string& doc, bool rounded, const Options& options, double seconds) {
        const Frame f = RenderDoc(doc, rounded, options, seconds);
        unsigned __int64 hash = 0xcbf29ce484222325ull;
        for (DWORD px : f) {
            hash = (hash ^ px) * 0x100000001b3ull;
        }
        name += rounded ? "-on" : "-off";
        fprintf(list, "%s %016llx\n", name.GetString(), hash);

        // Over a mid grey, which shows both a dark box and light text
        std::vector<DWORD> out(f.size());
        for (size_t i = 0; i < f.size(); i++) {
            const DWORD a = f[i] >> 24;
            auto over = [&](int shift) { return std::min<DWORD>(255, ((f[i] >> shift) & 0xff) + 0x70 * a / 255) << shift; };
            out[i] = 0xFF000000u | over(16) | over(8) | over(0);
        }
        BITMAPFILEHEADER fh = {};
        BITMAPINFOHEADER ih = {};
        ih.biSize = sizeof(ih);
        ih.biWidth = kWidth;
        ih.biHeight = -kHeight;
        ih.biPlanes = 1;
        ih.biBitCount = 32;
        fh.bfType = 0x4D42;
        fh.bfOffBits = sizeof(fh) + sizeof(ih);
        fh.bfSize = fh.bfOffBits + DWORD(out.size() * 4);
        FILE* bmp = nullptr;
        if (_wfopen_s(&bmp, (CStringW(dir) + L"\\" + CStringW(name) + L".bmp").GetString(), L"wb") == 0) {
            fwrite(&fh, sizeof(fh), 1, bmp);
            fwrite(&ih, sizeof(ih), 1, bmp);
            fwrite(out.data(), 4, out.size(), bmp);
            fclose(bmp);
        }
    };

    auto both = [&](const char* name, const std::string& doc, const Options& options, double seconds = 1.5) {
        dump(name, doc, false, options, seconds);
        dump(name, doc, true, options, seconds);
    };

    const char* const two = "A first line of text\\Nand a second one";
    const char* const three = "A line\\Nand a much longer line in the middle\\Nand a last";
    for (int border : { 0, 1, 2, 4, 8 }) {
        for (BYTE alpha : { BYTE(0x00), BYTE(0x80) }) {
            Options o;
            o.style = BoxStyle(border, border ? 0.0 : 2.0);
            o.style.alpha[2] = alpha;
            CStringA name;
            name.Format("b%d-a%02x", border, alpha);
            both(name + "-srt-one", Srt("A single line of text"), o);
            both(name + "-srt-two", Srt(two), o);
            both(name + "-srt-three", Srt(three), o);
            both(name + "-ass-one", Ass("A single line of text"), o);
            both(name + "-ass-two", Ass(two), o);
            both(name + "-ass-three", Ass(three), o);
        }
    }

    int n = 0;
    for (const FallbackCase& c : kFallbacks) {
        CStringA name;
        name.Format("fallback%02d", n++);
        fprintf(list, "# %s = %s\n", name.GetString(), c.name);
        both(name + "-srt", Srt(c.text), Options());
        both(name + "-ass", Ass(c.text), Options());
        Options shadowOnly;
        shadowOnly.style = BoxStyle(0.0, 2.0);
        both(name + "-shadow-srt", Srt(c.text), shadowOnly);
    }

    n = 0;
    for (const FallbackCase& c : kUnified) {
        CStringA name;
        name.Format("unified%02d", n++);
        fprintf(list, "# %s = %s\n", name.GetString(), c.name);
        Options transparent;
        transparent.style.alpha[2] = 0x80;
        both(name + "-srt", Srt(c.text), Options());
        both(name + "-ass", Ass(c.text), Options());
        both(name + "-transparent", Ass(c.text), transparent);
    }

    Options margins;
    margins.style.marginRect = CRect(38, 20, 38, 20);
    std::string text;
    for (int words = 1; words <= 60; words++) {
        text += "word ";
        if (words % 5 == 0) {
            CStringA name;
            name.Format("wrap%02d", words);
            both(name, Srt(text), margins);
        }
    }

    Options all, def;
    all.override = Override::All;
    def.override = Override::Default;
    both("own-styles-default", AssWithStyles(), Options(), 1.5);
    both("own-styles-sign", AssWithStyles(), Options(), 2.5);
    both("override-all-default", AssWithStyles(), all, 1.5);
    both("override-all-sign", AssWithStyles(), all, 2.5);
    both("override-default-default", AssWithStyles(), def, 1.5);
    both("override-default-sign", AssWithStyles(), def, 2.5);

    both("colour-word", Srt("One <font color=\"#ffff00\">coloured</font> word"), Options());
    both("colour-line", Srt("<font color=\"#ffff00\">The first line</font>\r\nThe second line"), Options());

    fclose(list);
}
