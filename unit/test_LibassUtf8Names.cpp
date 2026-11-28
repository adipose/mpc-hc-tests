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
#include "../../src/Subtitles/STS.h"
#include "../../src/Subtitles/LibassContext.h"
#include <sstream>
#include <string>

// libass reads every string it is given as UTF-8, but LibassContext.cpp used
// to convert the default style's font name and custom tags with CT2CA, which
// is the ANSI code page (issue #4466). A CJK family name came out as code page
// 936 bytes on a Chinese system and as '?' on a western one, so the default
// family was never found. These cover the SRT-to-ASS conversion, which writes
// the name into the generated header and into the {\fn} that restores it after
// </font>. The ass_set_fonts() calls take the same string and need a renderer.

namespace
{
    // the family from the report
    const wchar_t* fontW = L"\u65B9\u6B63\u51C6\u5706_GBK";
    const std::string fontUtf8 = "\xE6\x96\xB9\xE6\xAD\xA3\xE5\x87\x86\xE5\x9C\x86_GBK";

    STSStyle MakeStyle()
    {
        STSStyle style;
        style.fontName = fontW;
        return style;
    }
}

TEST(LibassUtf8Names, SrtHeaderWritesDefaultFontAsUtf8)
{
    STSStyle style = MakeStyle();
    OpenTypeLang::HintStr hint = {};
    char header[1024] = {};
    srt_header(header, style, hint);

    std::string text(header);
    EXPECT_NE(text.find("Style: Default," + fontUtf8 + ","), std::string::npos) << text;
}

TEST(LibassUtf8Names, FontCloseTagRestoresDefaultFontAsUtf8)
{
    STSStyle style = MakeStyle();
    std::string line = "<font color=\"#ff0000\">red</font> plain";
    ParseSrtLine(line, style);

    EXPECT_NE(line.find("{\\fn" + fontUtf8 + "}"), std::string::npos) << line;
}

TEST(LibassUtf8Names, SrtEventsCarryCustomTagsAsUtf8)
{
    CSimpleTextSubtitle sts;
    sts.m_subtitleType = Subtitle::SRT;
    LibassContext ctx{ &sts };
    ctx.InitLibASS();

    STSStyle style;
    style.customTags = CStringW(L"{\\fn") + fontW + L"}";
    OpenTypeLang::HintStr hint = {};
    std::istringstream srt("1\n00:00:01,000 --> 00:00:02,000\nhello\n\n");

    ASS_Track* track = ctx.m_track.get();
    ASSERT_NE(track, nullptr);
    srt_read_data(ctx.m_ass.get(), track, srt, style, hint);

    ASSERT_EQ(track->n_events, 1);
    std::string text(track->events[0].Text);
    EXPECT_NE(text.find("{\\fn" + fontUtf8 + "}"), std::string::npos) << text;
}
