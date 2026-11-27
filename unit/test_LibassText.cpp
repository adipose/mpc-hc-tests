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
#include "../../src/Subtitles/LibassText.h"
#include "../../src/Subtitles/LibassTimeline.h"
#include "ass/ass.h"
#include <cstring>
#include <string>
#include <vector>

// Auto-copy for a track rendered by libass reads the text and timing from
// libass's own events (ledger S18): an embedded libass track never reaches the
// internal renderer's parse, so before this auto-copy copied nothing for it.
// StripAssOverrideTags turns an ASS_Event's raw Text into plain text the way
// the internal renderer's RemoveSSATags does, and LibassTimeline::VisibleAt
// picks the events libass shows at a time.

TEST(LibassText, PlainTextIsUnchanged)
{
    EXPECT_EQ(StripAssOverrideTags("Hello, world"), "Hello, world");
    EXPECT_EQ(StripAssOverrideTags(""), "");
    EXPECT_EQ(StripAssOverrideTags(nullptr), "");
}

TEST(LibassText, OverrideBlocksAreRemoved)
{
    EXPECT_EQ(StripAssOverrideTags("{\\an8}Top line"), "Top line") << "at the start";
    EXPECT_EQ(StripAssOverrideTags("Some {\\i1}italic{\\i0} words"), "Some italic words") << "mid-line";
    EXPECT_EQ(StripAssOverrideTags("Last word{\\fad(200,200)}"), "Last word") << "at the end";
    EXPECT_EQ(StripAssOverrideTags("{\\b1}{\\i1}Both{\\i0}{\\b0}"), "Both") << "adjacent blocks";
    EXPECT_EQ(StripAssOverrideTags("{\\pos(10,20)\\c&H00FF00&}Green"), "Green") << "several tags in one block";
    EXPECT_EQ(StripAssOverrideTags("{a comment}Text"), "Text") << "a block without tags is a comment";
    EXPECT_EQ(StripAssOverrideTags("{}Text"), "Text");
}

TEST(LibassText, NestedLookingBlocksEndAtTheFirstClose)
{
    // libass ends a block at the first '}', so does the stripper
    EXPECT_EQ(StripAssOverrideTags("{\\b1{\\i1}x}y"), "x}y");
}

TEST(LibassText, LineBreaksAndHardSpaces)
{
    EXPECT_EQ(StripAssOverrideTags("First\\NSecond"), "First\nSecond");
    EXPECT_EQ(StripAssOverrideTags("First\\nSecond"), "First\nSecond");
    EXPECT_EQ(StripAssOverrideTags("a\\hb"), "a b");
    EXPECT_EQ(StripAssOverrideTags("{\\i1}One\\N{\\i0}Two"), "One\nTwo");
    EXPECT_EQ(StripAssOverrideTags("C:\\path"), "C:\\path") << "any other backslash is text";
    EXPECT_EQ(StripAssOverrideTags("trailing\\"), "trailing\\");
}

TEST(LibassText, UnclosedBraceIsText)
{
    EXPECT_EQ(StripAssOverrideTags("a { b"), "a { b");
    EXPECT_EQ(StripAssOverrideTags("{\\i1 never closed"), "{\\i1 never closed");
    EXPECT_EQ(StripAssOverrideTags("x{y\\Nz"), "x{y\nz") << "line breaks after it still convert, as in RemoveSSATags";
    EXPECT_EQ(StripAssOverrideTags("{\\b1}ok {broken"), "ok {broken") << "a closed block before it is still removed";
}

TEST(LibassText, Utf8PassesThrough)
{
    // "Grüße {\i1}日本{\i0}" in UTF-8
    EXPECT_EQ(StripAssOverrideTags("Gr\xC3\xBC\xC3\x9F" "e {\\i1}\xE6\x97\xA5\xE6\x9C\xAC{\\i0}"),
              "Gr\xC3\xBC\xC3\x9F" "e \xE6\x97\xA5\xE6\x9C\xAC");
}

// A drawing is text to the stripper: its commands survive. The internal
// renderer's RemoveSSATags does the same, so the auto-copy guards see the same
// string on both paths. A drawing is non-empty, so only its duration (shorter
// than MIN_AUTOCOPY_SUBTITLE_DURATION) or the line and length caps keep it off
// the clipboard; a lone long-lived drawing is copied as its commands, on
// either path.
TEST(LibassText, DrawingKeepsItsCommands)
{
    EXPECT_EQ(StripAssOverrideTags("{\\p1}m 0 0 l 100 0 100 100 0 100{\\p0}"), "m 0 0 l 100 0 100 100 0 100");
}

// The SRT path: srt_read_data turns <i> and friends into override blocks, so
// an SRT track comes out of the same stripper.
TEST(LibassText, ConvertedSrtTags)
{
    EXPECT_EQ(StripAssOverrideTags("{\\i1}Italic{\\i0} and {\\b1}bold{\\b0}"), "Italic and bold");
}

namespace
{
    LibassTimelineEvent Ev(long long start, long long duration, int readOrder, const char* text = "x")
    {
        return { start, duration, text, "", readOrder };
    }
}

TEST(LibassVisibleAt, StartInclusiveEndExclusive)
{
    std::vector<LibassTimelineEvent> e = { Ev(1000, 2000, 0) };
    EXPECT_TRUE(LibassTimeline::VisibleAt(e.data(), e.size(), 999).empty());
    EXPECT_EQ(LibassTimeline::VisibleAt(e.data(), e.size(), 1000), std::vector<size_t>({ 0 }));
    EXPECT_EQ(LibassTimeline::VisibleAt(e.data(), e.size(), 2999), std::vector<size_t>({ 0 }));
    EXPECT_TRUE(LibassTimeline::VisibleAt(e.data(), e.size(), 3000).empty()) << "libass: Start <= now < Start + Duration";
}

TEST(LibassVisibleAt, ZeroDurationIsNeverVisible)
{
    std::vector<LibassTimelineEvent> e = { Ev(1000, 0, 0) };
    EXPECT_TRUE(LibassTimeline::VisibleAt(e.data(), e.size(), 1000).empty());
}

TEST(LibassVisibleAt, OverlappingEventsComeInReadOrder)
{
    // stored out of file order, the way chunks can arrive while seeking
    std::vector<LibassTimelineEvent> e = {
        Ev(0, 5000, 2, "third"),
        Ev(9000, 1000, 3, "later"),
        Ev(1000, 3000, 0, "first"),
        Ev(500, 4000, 1, "second"),
    };
    EXPECT_EQ(LibassTimeline::VisibleAt(e.data(), e.size(), 2000), std::vector<size_t>({ 2, 3, 0 }));
    EXPECT_EQ(LibassTimeline::VisibleAt(e.data(), e.size(), 4500), std::vector<size_t>({ 0 })) << "only the long one is left";
    EXPECT_EQ(LibassTimeline::VisibleAt(e.data(), e.size(), 9500), std::vector<size_t>({ 1 }));
    EXPECT_TRUE(LibassTimeline::VisibleAt(e.data(), e.size(), 6000).empty()) << "a gap";
}

TEST(LibassVisibleAt, MatchesTheTimelineSegments)
{
    // every time inside a segment sees the same events, which is why the
    // segment index identifies what auto-copy already copied
    std::vector<LibassTimelineEvent> e = { Ev(0, 4000, 0), Ev(2000, 4000, 1), Ev(8000, 1000, 2) };
    LibassTimeline t;
    t.Build(e.data(), e.size(), (int)e.size(), 1);
    ASSERT_EQ(t.Count(), 4u);
    for (size_t s = 0; s < t.Count(); s++) {
        auto first = LibassTimeline::VisibleAt(e.data(), e.size(), t.At(s).start);
        auto last = LibassTimeline::VisibleAt(e.data(), e.size(), t.At(s).stop - 1);
        EXPECT_FALSE(first.empty()) << "segment " << s;
        EXPECT_EQ(first, last) << "segment " << s;
        EXPECT_EQ(t.FindAt(t.At(s).start), s);
    }
}

// The same lookup over a real ASS_Track filled through ass_process_chunk, the
// way the input pin fills an embedded track, and then stripped: what
// LibassContext::GetEventsAt and auto-copy do together.
namespace
{
    const char* const header =
        "[Script Info]\nScriptType: v4.00+\nPlayResX: 1280\nPlayResY: 720\n\n"
        "[V4+ Styles]\n"
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
        "Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1\n\n"
        "[Events]\n"
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n";
}

TEST(LibassVisibleAt, FromProcessedChunks)
{
    EXPECT_TRUE(LibassTimeline::EventsOf(nullptr).empty());

    ASS_Library* lib = ass_library_init();
    ASS_Track* track = ass_new_track(lib);
    ass_process_codec_private(track, const_cast<char*>(header), (int)strlen(header));
    auto chunk = [&](int readOrder, long long startMs, long long durationMs, const char* text) {
        std::string line = std::to_string(readOrder) + ",0,Default,,0,0,0,," + text;
        ass_process_chunk(track, line.data(), (int)line.size(), startMs, durationMs);
    };
    // the bottom line demuxed first, file order says it comes second
    chunk(1, 1000, 3000, "{\\an2}Bottom\\Nline");
    chunk(0, 1000, 3000, "{\\an8}{\\b1}Top{\\b0}");

    std::vector<LibassTimelineEvent> events = LibassTimeline::EventsOf(track);
    ASSERT_EQ(events.size(), 2u);
    std::vector<std::string> texts;
    for (size_t i : LibassTimeline::VisibleAt(events.data(), events.size(), 2000)) {
        texts.push_back(StripAssOverrideTags(events[i].text));
    }
    EXPECT_EQ(texts, std::vector<std::string>({ "Top", "Bottom\nline" }));

    ass_free_track(track);
    ass_library_done(lib);
}
