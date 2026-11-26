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
#include "../../src/Subtitles/LibassTimeline.h"
#include "ass/ass.h"
#include <memory>
#include <string>
#include <vector>

// LibassTimeline (src/Subtitles/LibassTimeline.cpp) turns a libass track's
// events into the segments the subpic queue asks LibassContext about: the
// ranges over which the set of visible events does not change, each flagged
// animated when one of its events changes over time. Before it, the libass
// provider answered a one-tick segment [rt, rt+1) at whatever time it was
// asked (ledger S19), so the queue rendered every presented frame.

namespace
{
    LibassTimelineEvent Ev(long long start, long long duration, const char* text = "x", const char* effect = "")
    {
        return { start, duration, text, effect };
    }

    LibassTimeline BuildFrom(const std::vector<LibassTimelineEvent>& events, uint32_t generation = 1)
    {
        LibassTimeline t;
        t.Build(events.data(), events.size(), (int)events.size(), generation);
        return t;
    }

    void ExpectSegment(const LibassTimeline& t, size_t i, long long start, long long stop, bool animated)
    {
        ASSERT_LT(i, t.Count());
        EXPECT_EQ(t.At(i).start, start) << "segment " << i;
        EXPECT_EQ(t.At(i).stop, stop) << "segment " << i;
        EXPECT_EQ(t.At(i).animated, animated) << "segment " << i;
    }
}

TEST(LibassTimeline, SingleEventIsOneSegment)
{
    LibassTimeline t = BuildFrom({ Ev(5000, 5000) });
    ASSERT_EQ(t.Count(), 1u);
    ExpectSegment(t, 0, 5000, 10000, false);
}

TEST(LibassTimeline, OverlapSplitsAtEveryBoundary)
{
    // A [1000,5000) and B [3000,7000): three ranges with different content
    LibassTimeline t = BuildFrom({ Ev(1000, 4000), Ev(3000, 4000) });
    ASSERT_EQ(t.Count(), 3u);
    ExpectSegment(t, 0, 1000, 3000, false);
    ExpectSegment(t, 1, 3000, 5000, false);
    ExpectSegment(t, 2, 5000, 7000, false);
}

TEST(LibassTimeline, EventOrderDoesNotMatter)
{
    LibassTimeline a = BuildFrom({ Ev(1000, 4000), Ev(3000, 4000) });
    LibassTimeline b = BuildFrom({ Ev(3000, 4000), Ev(1000, 4000) });
    ASSERT_EQ(a.Count(), b.Count());
    for (size_t i = 0; i < a.Count(); i++) {
        EXPECT_EQ(a.At(i).start, b.At(i).start);
        EXPECT_EQ(a.At(i).stop, b.At(i).stop);
    }
}

TEST(LibassTimeline, TouchingEventsShareOneBoundary)
{
    // End == next Start: no one-ms gap between them and no doubled boundary
    LibassTimeline t = BuildFrom({ Ev(1000, 1000), Ev(2000, 1000) });
    ASSERT_EQ(t.Count(), 2u);
    ExpectSegment(t, 0, 1000, 2000, false);
    ExpectSegment(t, 1, 2000, 3000, false);
    EXPECT_EQ(t.At(0).stop, t.At(1).start);
}

TEST(LibassTimeline, IdenticalEventsMakeOneSegment)
{
    LibassTimeline t = BuildFrom({ Ev(1000, 1000), Ev(1000, 1000) });
    ASSERT_EQ(t.Count(), 1u);
    ExpectSegment(t, 0, 1000, 2000, false);
}

TEST(LibassTimeline, ZeroAndNegativeDurationsAreSkipped)
{
    // libass shows an event while Start <= now < Start + Duration, which is
    // empty for these, so they must not add a boundary either
    LibassTimeline none = BuildFrom({ Ev(1000, 0), Ev(2000, -500) });
    EXPECT_EQ(none.Count(), 0u);

    LibassTimeline t = BuildFrom({ Ev(1000, 0), Ev(1500, 1000), Ev(1800, -5) });
    ASSERT_EQ(t.Count(), 1u);
    ExpectSegment(t, 0, 1500, 2500, false);
}

TEST(LibassTimeline, GapIsNotASegment)
{
    LibassTimeline t = BuildFrom({ Ev(0, 1000), Ev(5000, 1000) });
    ASSERT_EQ(t.Count(), 2u);
    ExpectSegment(t, 0, 0, 1000, false);
    ExpectSegment(t, 1, 5000, 6000, false);
}

TEST(LibassTimeline, FindAtReturnsContainingOrNextSegment)
{
    LibassTimeline t = BuildFrom({ Ev(1000, 1000), Ev(5000, 1000) });
    EXPECT_EQ(t.FindAt(0), 0u) << "before the first line: the first line is next";
    EXPECT_EQ(t.FindAt(1000), 0u) << "the start is inclusive";
    EXPECT_EQ(t.FindAt(1999), 0u);
    EXPECT_EQ(t.FindAt(2000), 1u) << "the stop is exclusive: the next line is what is coming";
    EXPECT_EQ(t.FindAt(3000), 1u) << "in a gap: the next line";
    EXPECT_EQ(t.FindAt(5999), 1u);
    EXPECT_EQ(t.FindAt(6000), LibassTimeline::npos) << "after the last line there is nothing";
    EXPECT_EQ(LibassTimeline().FindAt(0), LibassTimeline::npos);
}

TEST(LibassTimeline, AnimatedFlagFollowsTheActiveEvents)
{
    // a static line with a moving one over its middle
    LibassTimeline t = BuildFrom({ Ev(0, 4000, "static"), Ev(2000, 1000, "{\\move(0,0,100,100)}moving") });
    ASSERT_EQ(t.Count(), 3u);
    ExpectSegment(t, 0, 0, 2000, false);
    ExpectSegment(t, 1, 2000, 3000, true);
    ExpectSegment(t, 2, 3000, 4000, false);
}

TEST(LibassTimeline, BannerEffectAnimatesItsSegment)
{
    LibassTimeline t = BuildFrom({ Ev(0, 1000, "plain text", "Banner;20;0;0") });
    ASSERT_EQ(t.Count(), 1u);
    EXPECT_TRUE(t.At(0).animated);
}

// The tag matcher. The reference is what sets CSubtitle::m_bIsAnimated in
// the internal renderer: \t, \move, \fad, \fade, \k, \K, \kf, \ko, \kt inside
// an override block, and the Banner and Scroll effects.
TEST(LibassTimelineAnimated, KaraokeTags)
{
    EXPECT_TRUE(LibassTimeline::IsAnimatedEvent("{\\k200}ka{\\k300}ra", nullptr));
    EXPECT_TRUE(LibassTimeline::IsAnimatedEvent("{\\kf200}fill", nullptr)) << "\\kf is its own tag, not \\k with text";
    EXPECT_TRUE(LibassTimeline::IsAnimatedEvent("{\\K200}fill", nullptr));
    EXPECT_TRUE(LibassTimeline::IsAnimatedEvent("{\\ko200}outline", nullptr));
    EXPECT_TRUE(LibassTimeline::IsAnimatedEvent("{\\kt500}shift", nullptr));
    EXPECT_TRUE(LibassTimeline::IsAnimatedEvent("{\\an8\\kf200}after another tag", nullptr));
}

TEST(LibassTimelineAnimated, TransformMoveAndFade)
{
    EXPECT_TRUE(LibassTimeline::IsAnimatedEvent("{\\t(\\fs40)}grow", nullptr));
    EXPECT_TRUE(LibassTimeline::IsAnimatedEvent("{\\t(0,500,\\1c&HFF0000&)}recolour", nullptr));
    EXPECT_TRUE(LibassTimeline::IsAnimatedEvent("{\\move(100,100,1100,100)}slide", nullptr));
    EXPECT_TRUE(LibassTimeline::IsAnimatedEvent("{\\fad(200,200)}fade", nullptr));
    EXPECT_TRUE(LibassTimeline::IsAnimatedEvent("{\\fade(255,0,255,0,500,1000,1500)}fade", nullptr));
    EXPECT_TRUE(LibassTimeline::IsAnimatedEvent("{\\pos(10,10)\\t(\\frz360)}spin", nullptr)) << "nested inside \\t";
    EXPECT_TRUE(LibassTimeline::IsAnimatedEvent("static start{\\move(0,0,1,1)}then moves", nullptr)) << "a block later in the text";
}

TEST(LibassTimelineAnimated, StaticTagsAreNot)
{
    EXPECT_FALSE(LibassTimeline::IsAnimatedEvent("{\\fs20\\b1\\pos(640,360)}static", nullptr));
    EXPECT_FALSE(LibassTimeline::IsAnimatedEvent("{\\an8\\1c&H00FFFF&\\blur2}static", nullptr));
    EXPECT_FALSE(LibassTimeline::IsAnimatedEvent("{\\fscx120\\fscy120\\frz10}static", nullptr)) << "\\fscx is not \\fad, \\frz is not \\fade";
    EXPECT_FALSE(LibassTimeline::IsAnimatedEvent("{\\clip(0,0,100,100)}static", nullptr));
    EXPECT_FALSE(LibassTimeline::IsAnimatedEvent("{comment, no tags}static", nullptr));
}

TEST(LibassTimelineAnimated, TagsOutsideABlockAreText)
{
    EXPECT_FALSE(LibassTimeline::IsAnimatedEvent("read \\move(1,2,3,4) in the manual", nullptr));
    EXPECT_FALSE(LibassTimeline::IsAnimatedEvent("first line\\Nsecond\\nthird\\hword", nullptr)) << "line breaks and hard spaces";
    EXPECT_FALSE(LibassTimeline::IsAnimatedEvent("{\\b1}bold \\t tab {\\b0}", nullptr)) << "\\t between blocks";
    EXPECT_FALSE(LibassTimeline::IsAnimatedEvent("{\\b1}closed} \\k outside", nullptr));
}

TEST(LibassTimelineAnimated, EffectField)
{
    EXPECT_TRUE(LibassTimeline::IsAnimatedEvent("plain", "Banner;20;0;0"));
    EXPECT_TRUE(LibassTimeline::IsAnimatedEvent("plain", "Scroll up;0;100;10"));
    EXPECT_TRUE(LibassTimeline::IsAnimatedEvent("plain", "Scroll down;0;100;10;50"));
    EXPECT_TRUE(LibassTimeline::IsAnimatedEvent("plain", "banner;20")) << "ParseEffect compares without case";
    EXPECT_TRUE(LibassTimeline::IsAnimatedEvent("plain", " Banner;20"));
    EXPECT_FALSE(LibassTimeline::IsAnimatedEvent("plain", "Karaoke"));
    EXPECT_FALSE(LibassTimeline::IsAnimatedEvent("plain", "Banner")) << "without the separator ParseEffect gives up";
    EXPECT_FALSE(LibassTimeline::IsAnimatedEvent("plain", ""));
    EXPECT_FALSE(LibassTimeline::IsAnimatedEvent("plain", nullptr));
}

TEST(LibassTimelineAnimated, EmptyInputs)
{
    EXPECT_FALSE(LibassTimeline::IsAnimatedEvent(nullptr, nullptr));
    EXPECT_FALSE(LibassTimeline::IsAnimatedEvent("", ""));
    EXPECT_FALSE(LibassTimeline::IsAnimatedEvent("{", nullptr)) << "an unclosed block";
    EXPECT_FALSE(LibassTimeline::IsAnimatedEvent("{\\", nullptr)) << "a backslash at the very end";
    EXPECT_TRUE(LibassTimeline::IsAnimatedEvent("{\\t", nullptr)) << "an unterminated tag still names \\t";
}

// The rebuild trigger LibassContext::EnsureTimeline uses: the event count
// moving (an embedded chunk was added) or the generation moving (a load,
// flush or reload replaced the events, possibly with the same count).
TEST(LibassTimelineRebuild, EventCountAndGeneration)
{
    LibassTimeline t;
    EXPECT_TRUE(t.NeedsRebuild(0, 0)) << "never built";

    std::vector<LibassTimelineEvent> events = { Ev(0, 1000) };
    t.Build(events.data(), events.size(), 1, 7);
    EXPECT_FALSE(t.NeedsRebuild(1, 7));
    EXPECT_TRUE(t.NeedsRebuild(2, 7)) << "a chunk arrived";
    EXPECT_TRUE(t.NeedsRebuild(1, 8)) << "flushed and refilled to the same count";
    EXPECT_TRUE(t.NeedsRebuild(0, 7)) << "flushed";

    t.Clear();
    EXPECT_EQ(t.Count(), 0u);
    EXPECT_TRUE(t.NeedsRebuild(0, 0)) << "cleared on unload: even an empty track is built once";
}

TEST(LibassTimelineRebuild, RebuildReplacesTheSegments)
{
    std::vector<LibassTimelineEvent> a = { Ev(0, 1000) };
    std::vector<LibassTimelineEvent> b = { Ev(5000, 1000), Ev(8000, 1000) };
    LibassTimeline t;
    t.Build(a.data(), a.size(), 1, 1);
    ASSERT_EQ(t.Count(), 1u);
    t.Build(b.data(), b.size(), 2, 1);
    ASSERT_EQ(t.Count(), 2u);
    ExpectSegment(t, 0, 5000, 6000, false);
    ExpectSegment(t, 1, 8000, 9000, false);
}

// The same timeline from a real ASS_Track, the way LibassContext builds it,
// with events fed through ass_process_chunk the way the input pin feeds an
// embedded track. Also pins the two libass behaviours LibassContext relies
// on: a repeated ReadOrder does not add an event (ProcessChunk reports an
// added event by the count moving), and ass_flush_events empties the track.
namespace
{
    const char* const header =
        "[Script Info]\nScriptType: v4.00+\nPlayResX: 1280\nPlayResY: 720\n\n"
        "[V4+ Styles]\n"
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
        "Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1\n\n"
        "[Events]\n"
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n";

    struct Track {
        ASS_Library* lib = ass_library_init();
        ASS_Track* track = ass_new_track(lib);
        Track() {
            ass_process_codec_private(track, const_cast<char*>(header), (int)strlen(header));
        }
        ~Track() {
            ass_free_track(track);
            ass_library_done(lib);
        }
        // the Matroska block form: ReadOrder,Layer, then the header's fields from Style on
        // (ass_process_chunk skips the format's Layer, Start and End)
        void Chunk(int readOrder, long long startMs, long long durationMs, const char* text, const char* effect = "") {
            std::string line = std::to_string(readOrder) + ",0,Default,,0,0,0," + effect + "," + text;
            ass_process_chunk(track, line.data(), (int)line.size(), startMs, durationMs);
        }
    };
}

TEST(LibassTimelineTrack, BuiltFromProcessedChunks)
{
    Track t;
    t.Chunk(0, 5000, 5000, "Static line");
    t.Chunk(1, 30000, 5000, "{\\move(100,100,1100,100)}Moving line");
    t.Chunk(2, 35000, 7000, "First overlapping line");
    t.Chunk(3, 37000, 7000, "Second overlapping line");
    ASSERT_EQ(t.track->n_events, 4);

    LibassTimeline tl;
    tl.Build(t.track, 3);
    EXPECT_FALSE(tl.NeedsRebuild(4, 3));
    ASSERT_EQ(tl.Count(), 5u);
    ExpectSegment(tl, 0, 5000, 10000, false);
    ExpectSegment(tl, 1, 30000, 35000, true);
    ExpectSegment(tl, 2, 35000, 37000, false);
    ExpectSegment(tl, 3, 37000, 42000, false);
    ExpectSegment(tl, 4, 42000, 44000, false);
    EXPECT_EQ(tl.FindAt(20000), 1u) << "the 20 s gap answers the moving line";
}

TEST(LibassTimelineTrack, BannerEffectFromTheEffectField)
{
    Track t;
    t.Chunk(0, 0, 3000, "scrolling text", "Banner;20;0;0");
    LibassTimeline tl;
    tl.Build(t.track, 1);
    ASSERT_EQ(tl.Count(), 1u);
    EXPECT_TRUE(tl.At(0).animated);
}

TEST(LibassTimelineTrack, DuplicateReadOrderAddsNoEvent)
{
    Track t;
    t.Chunk(7, 1000, 1000, "once");
    ASSERT_EQ(t.track->n_events, 1);
    t.Chunk(7, 1000, 1000, "again");
    EXPECT_EQ(t.track->n_events, 1) << "the count is how ProcessChunk knows nothing was added";
    t.Chunk(8, 2000, 1000, "new");
    EXPECT_EQ(t.track->n_events, 2);
}

TEST(LibassTimelineTrack, FlushEmptiesTheTrack)
{
    Track t;
    t.Chunk(0, 1000, 1000, "a");
    t.Chunk(1, 2000, 1000, "b");
    LibassTimeline tl;
    tl.Build(t.track, 1);
    ASSERT_EQ(tl.Count(), 2u);

    ass_flush_events(t.track);
    EXPECT_EQ(t.track->n_events, 0);
    EXPECT_TRUE(tl.NeedsRebuild(t.track->n_events, 1));
    tl.Build(t.track, 2);
    EXPECT_EQ(tl.Count(), 0u);
    EXPECT_EQ(tl.FindAt(1500), LibassTimeline::npos);
}

TEST(LibassTimelineTrack, EmptyTrackBuildsOnce)
{
    Track t;
    LibassTimeline tl;
    EXPECT_TRUE(tl.NeedsRebuild(t.track->n_events, 1));
    tl.Build(t.track, 1);
    EXPECT_EQ(tl.Count(), 0u);
    EXPECT_FALSE(tl.NeedsRebuild(t.track->n_events, 1)) << "an empty track is not rebuilt on every lookup";
}
