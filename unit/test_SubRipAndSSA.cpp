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
#include "SubtitleTestUtil.h"
#include "../../src/Subtitles/LibassContext.h"

// SubRip and SSA/ASS through CSimpleTextSubtitle::Open (src/Subtitles/STS.cpp),
// and the SRT-to-ASS tag converter libass rendering uses
// (src/Subtitles/LibassContext.cpp: ParseSrtLine, GetTag, ConsumeAttribute).
// Modelled on #1038 ('=' in ASS lines) and #4185 (long tags).

using namespace testutil;

namespace
{
    // fixtures/subrip_basic.srt, in file order
    enum { PLAIN, INLINE_TAGS, TWO_LINES, NO_MS, HOURS, EQUALS, SRT_COUNT };
}

TEST(SubRip, TimingsAndText)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenFixture(sts, L"subrip_basic.srt"));
    EXPECT_EQ(sts.m_subtitleType, Subtitle::SRT);
    ASSERT_EQ(sts.GetCount(), (size_t)SRT_COUNT);

    EXPECT_EQ(sts[PLAIN].str, L"Plain first cue");
    EXPECT_EQ(StartMs(sts, PLAIN), 1000);
    EXPECT_EQ(EndMs(sts, PLAIN), 2500);

    EXPECT_EQ(sts[TWO_LINES].str, L"first line\\Nsecond line");

    EXPECT_EQ(StartMs(sts, NO_MS), 7000);
    EXPECT_EQ(EndMs(sts, NO_MS), 8000);

    EXPECT_EQ(StartMs(sts, HOURS), ((1 * 60 + 2) * 60 + 3) * 1000 + 4);
    EXPECT_EQ(EndMs(sts, HOURS), ((1 * 60 + 2) * 60 + 5) * 1000 + 6);

    EXPECT_EQ(sts[EQUALS].str, L"2 + 2 = 4, and a = b");
    EXPECT_EQ(sts[PLAIN].style, L"Default");
}

TEST(SubRip, HtmlTagsBecomeSSATags)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenFixture(sts, L"subrip_basic.srt"));
    ASSERT_EQ(sts.GetCount(), (size_t)SRT_COUNT);
    EXPECT_EQ(sts[INLINE_TAGS].str, L"{\\i1}italic{\\i} {\\b1}bold{\\b} {\\u1}underline{\\u}");
}

TEST(SubRip, Utf8BomCrLfAndNoTrailingNewline)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenText(sts, L"bom.srt", "\xEF\xBB\xBF" "1\r\n00:00:01,000 --> 00:00:02,000\r\nna\xC3\xAFve caf\xC3\xA9\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nlast"));
    ASSERT_EQ(sts.GetCount(), (size_t)2);
    EXPECT_EQ(sts[0].str, L"na\x00efve caf\x00e9");
    EXPECT_EQ(sts[1].str, L"last");
    EXPECT_EQ(sts.m_encoding, CTextFile::UTF8);
}

TEST(SubRip, BlankLineInsideACueDoesNotEndIt)
{
    // A cue ends at a blank line only when a cue number follows it.
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenText(sts, L"gap.srt", "1\n00:00:01,000 --> 00:00:02,000\nbefore the gap\n\nafter the gap\n\n2\n00:00:03,000 --> 00:00:04,000\nsecond\n"));
    ASSERT_EQ(sts.GetCount(), (size_t)2);
    EXPECT_EQ(sts[0].str, L"before the gap\\N\\Nafter the gap");
    EXPECT_EQ(sts[1].str, L"second");
}

TEST(SubRip, TextStartingWithANumberIsNotACueNumber)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenText(sts, L"number.srt", "1\n00:00:01,000 --> 00:00:02,000\n1984 was a year\n\n2\n00:00:03,000 --> 00:00:04,000\n42\n"));
    ASSERT_EQ(sts.GetCount(), (size_t)2);
    EXPECT_EQ(sts[0].str, L"1984 was a year");
    EXPECT_EQ(sts[1].str, L"42");
}

TEST(SubRip, OutOfOrderCuesAreKept)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenText(sts, L"order.srt", "1\n00:00:05,000 --> 00:00:06,000\nlater\n\n2\n00:00:01,000 --> 00:00:02,000\nearlier\n"));
    ASSERT_EQ(sts.GetCount(), (size_t)2);
    EXPECT_EQ(sts[0].str, L"later");
    EXPECT_EQ(sts[1].str, L"earlier");
}

TEST(SubRip, GarbageIsRejectedWithoutADialog)
{
    CSimpleTextSubtitle sts;
    EXPECT_FALSE(OpenText(sts, L"garbage.srt", "this is not a subtitle file\nat all\n"));
    EXPECT_EQ(sts.GetCount(), (size_t)0);
    EXPECT_EQ(mpctest::MessageBoxCount(), 0);
}

TEST(SubRip, EmptyFileIsRejected)
{
    CSimpleTextSubtitle sts;
    EXPECT_FALSE(OpenText(sts, L"empty.srt", ""));
    EXPECT_EQ(sts.GetCount(), (size_t)0);
}

// --- SSA / ASS --------------------------------------------------------------

// #1038: an '=' anywhere in an ASS dialogue line raised "Syntax error".
TEST(ASS, EqualsSignInDialogueText)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenFixture(sts, L"ass_equals.ass"));
    EXPECT_EQ(mpctest::MessageBoxCount(), 0);
    ASSERT_EQ(sts.GetCount(), (size_t)4);

    EXPECT_EQ(sts[0].str, L"No equals sign here");
    EXPECT_EQ(sts[1].str, L"E = mc^2, obviously");
    EXPECT_EQ(sts[2].str, L"=== SIGN ===");
    EXPECT_EQ(sts[3].str, L"{\\i1}a=b{\\i0}, with commas, too");

    EXPECT_EQ(StartMs(sts, 1), 3000);
    EXPECT_EQ(EndMs(sts, 1), 4000);
    EXPECT_EQ(sts[2].style, L"Sign");
    EXPECT_EQ(sts[2].actor, L"Narrator");
    EXPECT_EQ(sts[2].layer, 1);
}

TEST(ASS, ScriptInfoAndStyles)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenFixture(sts, L"ass_equals.ass"));
    EXPECT_TRUE(sts.m_subtitleType == Subtitle::ASS || sts.m_subtitleType == Subtitle::SSA);
    EXPECT_EQ(sts.m_playRes.cx, 1280);
    EXPECT_EQ(sts.m_playRes.cy, 720);

    STSStyle* sign = nullptr;
    ASSERT_TRUE(sts.m_styles.Lookup(L"Sign", sign));
    ASSERT_TRUE(sign != nullptr);
    EXPECT_EQ(sign->fontName, L"Arial");
    EXPECT_EQ(sign->fontSize, 36.0);
    EXPECT_EQ(sign->scrAlignment, 8);
    EXPECT_EQ(sign->colors[0], (COLORREF)0x00FFFF); // &H0000FFFF: yellow, stored BGR
    EXPECT_TRUE(sign->fontWeight > FW_NORMAL);
}

TEST(SSA, MarkedFieldAndEqualsSignInText)
{
    // In SSA v4 the first event field is "Marked=0"; the parser splits on
    // that '=' and must not go looking for another one in the text.
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenFixture(sts, L"ssa_equals.ssa"));
    EXPECT_EQ(mpctest::MessageBoxCount(), 0);
    ASSERT_EQ(sts.GetCount(), (size_t)2);
    EXPECT_EQ(sts[0].str, L"x = y");
    EXPECT_EQ(sts[1].str, L"no sign");
    EXPECT_EQ(StartMs(sts, 0), 1000);
}

TEST(ASS, BrokenDialogueLineReportsASyntaxError)
{
    // The one place a parser talks to the user: a line that starts like a
    // dialogue and is not one. The harness swallows the dialog.
    mpctest::ExpectMessageBox();
    CSimpleTextSubtitle sts;
    const std::string doc =
        "[Script Info]\nScriptType: v4.00+\n\n[Events]\n"
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
        "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,fine\n"
        "Dialogue: 0,not a time,0:00:04.00,Default,,0,0,0,,broken\n";
    EXPECT_FALSE(OpenText(sts, L"broken.ass", doc));
    EXPECT_EQ(mpctest::MessageBoxCount(), 1);
    EXPECT_EQ(sts.GetCount(), (size_t)0);
}

// --- the SRT tag converter used when SRT is rendered through libass ---------

namespace
{
    std::string SrtToAss(std::string line)
    {
        STSStyle style; // the defaults: what </font> restores
        ParseSrtLine(line, style);
        return line;
    }
}

TEST(LibassSrt, BasicTags)
{
    EXPECT_EQ(SrtToAss("<i>italic</i> and <b>bold</b>"), "{\\i1}italic{\\i0} and {\\b1}bold{\\b0}");
    EXPECT_EQ(SrtToAss("<u>u</u><s>s</s>"), "{\\u1}u{\\u0}{\\s1}s{\\s0}");
    EXPECT_EQ(SrtToAss("one<br>two"), "one\\Ntwo");
    EXPECT_EQ(SrtToAss("one\ntwo\r\nthree"), "one\\Ntwo\\Nthree");
    EXPECT_EQ(SrtToAss("<I>upper case tag</I>"), "{\\i1}upper case tag{\\i0}");
}

TEST(LibassSrt, UnknownTagsAreHiddenAndLoneBracketsKept)
{
    EXPECT_EQ(SrtToAss("<blink>text</blink>"), "text");
    EXPECT_EQ(SrtToAss("1 < 2 and 3 > 2"), "1 < 2 and 3 > 2");
    EXPECT_EQ(SrtToAss("a <- b"), "a <- b");
}

TEST(LibassSrt, FontTag)
{
    STSStyle style;
    const std::string restore = "{\\c}{\\fn" + std::string(CT2CA(style.fontName)) + "}{\\fs" + std::to_string((int)std::round(style.fontSize)) + "}";

    // HTML colours are RGB, ASS colours BGR
    EXPECT_EQ(SrtToAss("<font color=\"#ff0000\">red</font>"), "{\\c&H0000ff&}red" + restore);
    EXPECT_EQ(SrtToAss("<font color=\"red\">red</font>"), "{\\c&H0000FF&}red" + restore);
    EXPECT_EQ(SrtToAss("<font face=\"Comic Sans MS\" size=\"24\">x</font>"), "{\\fnComic Sans MS}{\\fs24}x" + restore);
    EXPECT_EQ(SrtToAss("<font color=nonsense>x</font>"), "{\\c&HFFFFFF&}x" + restore);
}

TEST(LibassSrt, MicroDvdExtensions)
{
    EXPECT_EQ(SrtToAss("{y:i}italic"), "{\\i1}italic");
    EXPECT_EQ(SrtToAss("{c:$0000FF}red"), "{\\c&H0000FF&}red");
    EXPECT_EQ(SrtToAss("{s:30}big"), "{\\fs30}big");
}

TEST(LibassSrt, GetTagAndConsumeAttribute)
{
    const char* p = "<font color=\"#00ff00\" face='Arial'>x";
    EXPECT_EQ(GetTag(&p, false), "font");
    std::string value;
    EXPECT_EQ(ConsumeAttribute(&p, value), "color");
    EXPECT_EQ(value, "00ff00"); // the '#' is dropped here, not by the caller
    EXPECT_EQ(ConsumeAttribute(&p, value), "face");
    EXPECT_EQ(value, "Arial");
    EXPECT_EQ(ConsumeAttribute(&p, value), "");
    EXPECT_EQ(std::string(p), ">x");

    const char* notATag = "<3 hearts";
    EXPECT_EQ(GetTag(&notATag, false), "");
    EXPECT_EQ(std::string(notATag), "<3 hearts");
}

// #4185. Tag and attribute names and values were copied into BUFSIZ (512)
// byte stack buffers with strncpy_s, which treats a too-small destination as
// a fatal error, and were then terminated at an index past the buffer. One
// long run of letters after '<' ended the player (#4185). Isolated because
// before the fix this did not fail, it died -- and would again.
TEST_ISOLATED(LibassSrt, LongTagName)
{
    const std::string name(3000, 'a');
    EXPECT_EQ(SrtToAss("<" + name + ">text</" + name + ">"), "text");

    const char* p = nullptr;
    const std::string tag = "<" + name + ">";
    p = tag.c_str();
    EXPECT_EQ(GetTag(&p, false).size(), name.size());
}

// #4185 again: an attribute name or value longer than BUFSIZ overran a
// stack buffer in ConsumeAttribute.
TEST_ISOLATED(LibassSrt, LongAttribute)
{
    const std::string longValue(3000, 'x');
    const std::string longName(3000, 'n');
    STSStyle style;

    const std::string withLongValue = "<font face=\"" + longValue + "\">text</font>";
    EXPECT_TRUE(SrtToAss(withLongValue).find("{\\fn" + longValue + "}text") == 0);

    std::string value;
    const std::string attr = " " + longName + "=\"v\">";
    const char* p = attr.c_str();
    EXPECT_EQ(ConsumeAttribute(&p, value).size(), longName.size());
    EXPECT_EQ(value, "v");
}
