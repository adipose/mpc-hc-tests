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

// WebVTT, src/Subtitles/STS.cpp: OpenVTT, WebVTT2SSA, WebVTTCueStrip and the
// VTT branch of CSimpleTextSubtitle::Add. Modelled on #668 (unsupported tags),
// #673 (escapes), #677 (regex_replace broke Unicode), #930/#992/#1023/#1054/
// #1806 (colour classes and STYLE blocks) and #4197 (duplicate-cue check).

using namespace testutil;

namespace
{
    // fixtures/webvtt_tags.vtt, in file order
    enum { PLAIN, INLINE_TAGS, NO_HOURS, VOICE, CLASS_AND_LANG, KARAOKE, ESCAPES, TWO_LINES, ALIGN_START, ALIGN_CENTER, ALIGN_END, TAGS_COUNT };
}

TEST(WebVTT, HeaderNotesAndCueIdentifiersAreNotCues)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenFixture(sts, L"webvtt_tags.vtt"));
    EXPECT_EQ(sts.m_subtitleType, Subtitle::VTT);
    ASSERT_EQ(sts.GetCount(), (size_t)TAGS_COUNT);
    EXPECT_EQ(sts[PLAIN].str, L"Plain first cue");
    EXPECT_EQ(StartMs(sts, PLAIN), 1000);
    EXPECT_EQ(EndMs(sts, PLAIN), 2500);
}

TEST(WebVTT, TimestampsWithoutHours)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenFixture(sts, L"webvtt_tags.vtt"));
    ASSERT_EQ(sts.GetCount(), (size_t)TAGS_COUNT);
    EXPECT_EQ(StartMs(sts, NO_HOURS), 5000);
    EXPECT_EQ(EndMs(sts, NO_HOURS), 6250);
}

TEST(WebVTT, ItalicBoldUnderlineBecomeSSATags)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenFixture(sts, L"webvtt_tags.vtt"));
    ASSERT_EQ(sts.GetCount(), (size_t)TAGS_COUNT);
    const CStringW& raw = sts[INLINE_TAGS].str;
    EXPECT_TRUE(raw.Find(L"{\\i1}italic{\\i}") >= 0);
    EXPECT_TRUE(raw.Find(L"{\\b1}bold{\\b}") >= 0);
    EXPECT_TRUE(raw.Find(L"{\\u1}underline{\\u}") >= 0);
    EXPECT_EQ(raw.Find(L'<'), -1);
    // GetStrW() without SSA tags is the plain-text view; it keeps italics as <i>
    EXPECT_EQ(sts.GetStrW(INLINE_TAGS), L"<i>italic</i> bold underline");
}

// #668: tags the renderer has no use for are removed, their content kept.
TEST(WebVTT, UnsupportedTagsAreRemovedAndTheirTextKept)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenFixture(sts, L"webvtt_tags.vtt"));
    ASSERT_EQ(sts.GetCount(), (size_t)TAGS_COUNT);
    EXPECT_EQ(sts.GetStrW(VOICE), L"Voice span and another");
    EXPECT_EQ(sts.GetStrW(CLASS_AND_LANG), L"class-less unknown class language");
    EXPECT_EQ(sts.GetStrW(KARAOKE), L"Karaoke timestamps vanish");
    for (int i : { VOICE, CLASS_AND_LANG, KARAOKE }) {
        EXPECT_EQ(sts[i].str.Find(L'<'), -1);
        EXPECT_EQ(sts[i].str.Find(L'>'), -1);
    }
}

// #673
TEST(WebVTT, EscapeSequences)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenFixture(sts, L"webvtt_tags.vtt"));
    ASSERT_EQ(sts.GetCount(), (size_t)TAGS_COUNT);
    EXPECT_EQ(sts[ESCAPES].str, L"Tom & Jerry: 1 < 2 > 0, non\\hbreaking, marks gone");
}

TEST(WebVTT, EscapedAmpersandIsNotDecodedTwice)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenText(sts, L"amp.vtt", "WEBVTT\n\n00:01.000 --> 00:02.000\n&amp;lt; is how you write &lt;\n"));
    ASSERT_EQ(sts.GetCount(), (size_t)1);
    EXPECT_EQ(sts[0].str, L"&lt; is how you write <");
}

TEST(WebVTT, MultiLineCue)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenFixture(sts, L"webvtt_tags.vtt"));
    ASSERT_EQ(sts.GetCount(), (size_t)TAGS_COUNT);
    EXPECT_EQ(sts[TWO_LINES].str, L"first line\\Nsecond line");
}

TEST(WebVTT, AlignCueSettingBecomesAlignmentTag)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenFixture(sts, L"webvtt_tags.vtt"));
    ASSERT_EQ(sts.GetCount(), (size_t)TAGS_COUNT);
    EXPECT_EQ(sts[ALIGN_START].str, L"{\\an1}Aligned to the start");
    EXPECT_EQ(sts[ALIGN_CENTER].str, L"{\\an2}Aligned to the centre");
    EXPECT_EQ(sts[ALIGN_END].str, L"{\\an3}Aligned to the end");
    EXPECT_EQ(StartMs(sts, ALIGN_START), 17000);
}

// #677: std::regex_replace on a narrow copy mangled everything outside ASCII.
// Every cue here goes through the tag-removal regexes.
TEST(WebVTT, UnicodeSurvivesTagRemoval)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenFixture(sts, L"webvtt_unicode.vtt"));
    ASSERT_EQ(sts.GetCount(), (size_t)4);
    EXPECT_EQ(sts.GetStrW(0), L"Za\x017c\x00f3\x0142\x0107 g\x0119\x015bl\x0105 ja\x017a\x0144");
    EXPECT_EQ(sts.GetStrW(1), L"\x65e5\x672c\x8a9e\x306e\x5b57\x5e55");
    EXPECT_EQ(sts.GetStrW(2), L"\x0395\x03bb\x03bb\x03b7\x03bd\x03b9\x03ba\x03ac \x0438 \x043a\x0438\x0440\x0438\x043b\x043b\x0438\x0446\x0430");
    EXPECT_EQ(sts.GetStrW(3), L"<i>emoji \xd83d\xde00 outside the BMP</i>");
    EXPECT_TRUE(sts[0].fUnicode);
}

TEST(WebVTT, Utf8BomAndCrLf)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenText(sts, L"bom.vtt", "\xEF\xBB\xBFWEBVTT\r\n\r\n00:00:01.000 --> 00:00:02.000\r\nline one\r\nline two\r\n\r\n00:00:03.000 --> 00:00:04.000\r\nnext\r\n"));
    ASSERT_EQ(sts.GetCount(), (size_t)2);
    EXPECT_EQ(sts[0].str, L"line one\\Nline two");
    EXPECT_EQ(sts[1].str, L"next");
}

TEST(WebVTT, FileWithoutSignatureIsNotWebVTT)
{
    // The .vtt extension only decides which parser is tried first. Without
    // the signature the WebVTT parser declines and the SubRip one, which does
    // not insist on cue numbers, takes the file.
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenText(sts, L"nosig.vtt", "00:00:01.000 --> 00:00:02.000\n<c.yellow>no header</c>\n"));
    EXPECT_EQ(sts.m_subtitleType, Subtitle::SRT);
    ASSERT_EQ(sts.GetCount(), (size_t)1);
    EXPECT_EQ(sts[0].str, L"<c.yellow>no header</c>");
}

TEST(WebVTT, HeaderOnlyIsAnEmptyButValidTrack)
{
    // Embedded tracks deliver the header first and the cues later.
    CSimpleTextSubtitle sts;
    EXPECT_TRUE(OpenText(sts, L"header.vtt", "WEBVTT\n"));
    EXPECT_EQ(sts.GetCount(), (size_t)0);
    EXPECT_EQ(sts.m_subtitleType, Subtitle::VTT);
}

// --- colour classes and STYLE blocks: #930, #992, #1023, #1054, #1806 -------

namespace
{
    // fixtures/webvtt_styles.vtt, in file order
    enum { S_WARN, S_SHADE, S_BOTH, S_DEFAULT_CLASS, S_DEFAULT_BG, S_TAG_RULE, S_NESTED, STYLES_COUNT };
}

TEST(WebVTT, StyleBlockClassColour)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenFixture(sts, L"webvtt_styles.vtt"));
    ASSERT_EQ(sts.GetCount(), (size_t)STYLES_COUNT);
    // SSA colours are BGR: #ff0000 is &H0000ff&
    EXPECT_EQ(sts[S_WARN].str, L"{\\c&H0000ff&}red text");
    EXPECT_EQ(StartMs(sts, S_WARN), 1000);
}

// #1806: "background-color" must not be read as "color", and rgb() is accepted
TEST(WebVTT, StyleBlockBackgroundColourRgb)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenFixture(sts, L"webvtt_styles.vtt"));
    ASSERT_EQ(sts.GetCount(), (size_t)STYLES_COUNT);
    EXPECT_EQ(sts[S_SHADE].str, L"{\\3c&Hff0000&}blue background");
}

TEST(WebVTT, DefaultColourClasses)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenFixture(sts, L"webvtt_styles.vtt"));
    ASSERT_EQ(sts.GetCount(), (size_t)STYLES_COUNT);
    // the style is reset after the span so that the rest of the line is plain
    EXPECT_EQ(sts[S_DEFAULT_CLASS].str, L"{\\c&H00ffff&}default class{\\r} then plain");
    EXPECT_EQ(sts[S_DEFAULT_BG].str, L"{\\3c&H0000ff&}default background class");
}

TEST(WebVTT, StyleRuleForAPlainTag)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenFixture(sts, L"webvtt_styles.vtt"));
    ASSERT_EQ(sts.GetCount(), (size_t)STYLES_COUNT);
    EXPECT_EQ(sts[S_TAG_RULE].str, L"{\\b1}{\\c&H00ffff&}styled bold{\\b}");
}

// #1054: the outer colour comes back when the inner span closes
TEST(WebVTT, NestedColourSpansRestoreTheOuterColour)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenFixture(sts, L"webvtt_styles.vtt"));
    ASSERT_EQ(sts.GetCount(), (size_t)STYLES_COUNT);
    EXPECT_EQ(sts[S_NESTED].str, L"{\\c&H0000ff&}outer {\\c&H00ffff&}inner{\\c&H0000ff&} outer again");
}

// #992: a rule that sets only the foreground
TEST(WebVTT, StyleRuleColourFirstDeclarationIsApplied)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenFixture(sts, L"webvtt_styles.vtt"));
    ASSERT_EQ(sts.GetCount(), (size_t)STYLES_COUNT);
    EXPECT_TRUE(sts[S_BOTH].str.Find(L"{\\c&H00ff00&}") >= 0);
    EXPECT_EQ(sts.GetStrW(S_BOTH), L"lime on black");
}

// #4216: from #1806 until then only the FIRST declaration of a ::cue rule was
// read, so '{ color: lime; background: #000080; }' lost its background.
TEST(WebVTT, StyleRuleWithColourAndBackground)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenFixture(sts, L"webvtt_styles.vtt"));
    ASSERT_EQ(sts.GetCount(), (size_t)STYLES_COUNT);
    EXPECT_TRUE(sts[S_BOTH].str.Find(L"{\\c&H00ff00&}") >= 0);
    EXPECT_TRUE(sts[S_BOTH].str.Find(L"{\\3c&H800000&}") >= 0);
}

// #4216: SSAColorTag treated a parsed value of 0 as 'could not parse' and
// substituted white, so .black, '#000000' and rgb(0,0,0) all rendered white.
TEST(WebVTT, BlackIsBlack)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenText(sts, L"black.vtt",
                     "WEBVTT\n\nSTYLE\n::cue(.ink) { color: #000000; }\n\n"
                     "00:01.000 --> 00:02.000\n<c.black>default class</c>\n\n"
                     "00:03.000 --> 00:04.000\n<c.ink>hex</c>\n"));
    ASSERT_EQ(sts.GetCount(), (size_t)2);
    EXPECT_EQ(sts[0].str, L"{\\c&H000000&}default class");
    EXPECT_EQ(sts[1].str, L"{\\c&H000000&}hex");
}

TEST(WebVTT, NamedBlackWorks)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenText(sts, L"named-black.vtt", "WEBVTT\n\nSTYLE\n::cue(.ink) { color: black; }\n\n00:01.000 --> 00:02.000\n<c.ink>named</c>\n"));
    ASSERT_EQ(sts.GetCount(), (size_t)1);
    EXPECT_EQ(sts[0].str, L"{\\c&H000000&}named");
}

TEST(WebVTT, DefaultCueStyleAppliesToEveryCue)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenText(sts, L"cue-default.vtt",
                     "WEBVTT\n\nSTYLE\n::cue {\n  color: rgb(255, 0, 0);\n}\n\n"
                     "00:01.000 --> 00:02.000\none\n\n00:03.000 --> 00:04.000\ntwo\n"));
    ASSERT_EQ(sts.GetCount(), (size_t)2);
    EXPECT_EQ(sts[0].str, L"{\\c&H0000ff&}one");
    EXPECT_EQ(sts[1].str, L"{\\c&H0000ff&}two");
}

// Seen in the wild and tolerated by the parser: "Style:" in place of "STYLE".
TEST(WebVTT, MisspelledStyleBlockHeader)
{
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenText(sts, L"style-colon.vtt", "WEBVTT\n\nStyle:\n::cue(.hot) { color: #ff0000; }\n\n00:01.000 --> 00:02.000\n<c.hot>x</c>\n"));
    ASSERT_EQ(sts.GetCount(), (size_t)1);
    EXPECT_EQ(sts[0].str, L"{\\c&H0000ff&}x");
}

TEST(WebVTT, StyleBlockRunningIntoTheFirstCueLosesNothing)
{
    // No blank line between the STYLE block and the first cue timing.
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenText(sts, L"style-nogap.vtt", "WEBVTT\n\nSTYLE\n::cue(.hot) { color: #ff0000; }\n00:01.000 --> 00:02.000\n<c.hot>x</c>\n"));
    ASSERT_EQ(sts.GetCount(), (size_t)1);
    EXPECT_EQ(StartMs(sts, 0), 1000);
    EXPECT_EQ(sts[0].str, L"{\\c&H0000ff&}x");
}

// --- duplicates -------------------------------------------------------------

TEST(WebVTT, RepeatedCueInFileIsDropped)
{
    // HLS segmenters repeat the cue that straddles a segment boundary.
    CSimpleTextSubtitle sts;
    ASSERT_TRUE(OpenText(sts, L"dupes.vtt",
                     "WEBVTT\n\n"
                     "00:00:01.000 --> 00:00:02.000\nsame\n\n"
                     "00:00:01.000 --> 00:00:02.000\nsame\n\n"
                     "00:00:02.000 --> 00:00:03.000\nsame\n\n"
                     "00:00:04.000 --> 00:00:05.000\nother\n"));
    ASSERT_EQ(sts.GetCount(), (size_t)3);
    EXPECT_EQ(StartMs(sts, 0), 1000);
    EXPECT_EQ(StartMs(sts, 1), 2000);
    EXPECT_EQ(sts[2].str, L"other");
}

// #4197. Embedded WebVTT arrives cue by cue through Add(). The duplicate
// check looks up the segment starting at the cue's start time; for a cue
// later than everything so far -- the normal case -- that lookup returns the
// end of the array, which the old code dereferenced. The read stays inside
// the array's spare capacity, so it cannot be caught without ASan: what this
// pins is the behaviour around it -- ordered cues are all kept, a repeat is
// dropped, an overlap is not mistaken for one.
TEST(WebVTT, AddKeepsOrderedCuesAndDropsARepeat)
{
    CSimpleTextSubtitle sts;
    sts.m_subtitleType = Subtitle::VTT;
    for (int i = 0; i < 40; i++) {
        CStringW text;
        text.Format(L"cue %d", i);
        sts.Add(text, true, MS2RT(1000 * i), MS2RT(1000 * i + 900));
    }
    ASSERT_EQ(sts.GetCount(), (size_t)40);

    sts.Add(L"cue 7", true, MS2RT(7000), MS2RT(7900));          // exact repeat
    EXPECT_EQ(sts.GetCount(), (size_t)40);
    sts.Add(L"overlap", true, MS2RT(7000), MS2RT(8500));        // same start, other end
    EXPECT_EQ(sts.GetCount(), (size_t)41);
    sts.Add(L"after all", true, MS2RT(100000), MS2RT(101000));  // beyond the last segment
    EXPECT_EQ(sts.GetCount(), (size_t)42);
    sts.Add(L"before all", true, MS2RT(0), MS2RT(500));
    EXPECT_EQ(sts.GetCount(), (size_t)43);
}

// The embedded path also has to strip what a demuxer leaves in the payload:
// the cue identifier and the cue settings line.
TEST(WebVTT, AddStripsCueIdentifierAndSettings)
{
    CSimpleTextSubtitle sts;
    sts.m_subtitleType = Subtitle::VTT;
    sts.Add(L"12\nalign:start position:10%\n<i>Hello</i> &amp; goodbye", true, MS2RT(1000), MS2RT(2000));
    ASSERT_EQ(sts.GetCount(), (size_t)1);
    EXPECT_EQ(sts.GetStrW(0), L"<i>Hello</i> & goodbye");
    EXPECT_TRUE(sts[0].str.Find(L"{\\an1}") == 0);
    EXPECT_TRUE(sts[0].str.Find(L"{\\i1}Hello{\\i}") > 0);
}

TEST(WebVTT, AddDropsACueThatIsOnlyMarkup)
{
    CSimpleTextSubtitle sts;
    sts.m_subtitleType = Subtitle::VTT;
    sts.Add(L"<c></c>", true, MS2RT(1000), MS2RT(2000));
    EXPECT_EQ(sts.GetCount(), (size_t)0);
}
