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
#include <string>
#include <vector>

// LibassContext::LoadTrackData (src/Subtitles/LibassContext.cpp) keeps a copy
// of an embedded ASS track's header in m_trackData, which StylesChanged hands
// back to LoadASSTrack to undo style overrides. The header arrives as a
// pointer and a length: for an embedded track the pointer is into the pin's
// media type format block (SubtitleInputPin, MKV CodecPrivate), which is not
// terminated after the header. The copy used to be `m_trackData = data`, which
// read on to the next zero byte and stored whatever followed (ledger 89).
//
// The buffer here is the header followed by non-zero bytes, then a zero, so
// the old copy picks up the tail deterministically without needing page heap.

namespace
{
    const std::string header =
        "[Script Info]\r\nScriptType: v4.00+\r\n\r\n"
        "[V4+ Styles]\r\n"
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\r\n"
        "Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1\r\n\r\n"
        "[Events]\r\n"
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r\n";

    struct Track {
        CSimpleTextSubtitle sts;
        LibassContext ctx{ &sts };
        Track() {
            sts.m_subtitleType = Subtitle::ASS;
            ctx.InitLibASS();
        }
    };
}

TEST(LibassTrackData, CopiesOnlyTheCountedHeader)
{
    // the format block goes on past the header with no terminator in between
    std::vector<char> block(header.begin(), header.end());
    const std::string tail = "OVERREAD";
    block.insert(block.end(), tail.begin(), tail.end());
    block.push_back('\0');

    Track t;
    t.ctx.LoadTrackData(t.ctx.m_track.get(), block.data(), (int)header.size());
    EXPECT_EQ(t.ctx.m_trackData.size(), header.size());
    EXPECT_EQ(t.ctx.m_trackData, header) << "bytes past the counted length must not be kept";
    ASSERT_NE(t.ctx.m_track, nullptr);
    EXPECT_GE(t.ctx.m_track->n_styles, 1) << "the header must still reach libass";
}

TEST(LibassTrackData, ReplayKeepsTheSameHeader)
{
    // StylesChanged replays m_trackData into itself through LoadASSTrack
    std::vector<char> block(header.begin(), header.end());
    block.insert(block.end(), 16, 'x');

    Track t;
    t.ctx.LoadTrackData(t.ctx.m_track.get(), block.data(), (int)header.size());
    t.ctx.LoadTrackData(t.ctx.m_track.get(), (char*)t.ctx.m_trackData.c_str(), (int)t.ctx.m_trackData.length());
    EXPECT_EQ(t.ctx.m_trackData, header);
}
