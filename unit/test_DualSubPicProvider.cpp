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
#include "../../src/SubPic/DualSubPicProvider.h"
#include "../../src/SubPic/SubPicProviderImpl.h"
#include <vector>

// CDualSubPicProvider (src/SubPic/DualSubPicProvider.cpp) merges the timelines
// of the primary and the secondary subtitle into the one the subpic queue
// enumerates: a boundary wherever either track has one, and a segment wherever
// either track shows something.
//
// It used to carry a special case for a segment of exactly one tick at the time
// asked about, which is what the libass provider answered before it had a
// timeline (#4470): the merged timeline then became that one tick alone, and
// both tracks were rendered every frame. Nothing answers that shape any more,
// and a real segment that happens to have it must be merged like any other.

namespace
{
    const REFERENCE_TIME kMs = 10000;

    struct Segment {
        REFERENCE_TIME start, stop;
        bool animated;
    };

    class CSegmentProvider : public CSubPicProviderImpl
    {
        CCritSec m_lock;
        std::vector<Segment> m_segments;
        HRESULT m_hrRender;
        CRect m_bbox;

    public:
        std::vector<REFERENCE_TIME> m_renderTimes;

        CSegmentProvider(std::vector<Segment> segments, HRESULT hrRender = S_OK, CRect bbox = CRect(0, 0, 0, 0))
            : CSubPicProviderImpl(&m_lock)
            , m_segments(std::move(segments))
            , m_hrRender(hrRender)
            , m_bbox(bbox) {}

        STDMETHODIMP_(POSITION) GetStartPosition(REFERENCE_TIME rt, double) override {
            for (size_t i = 0; i < m_segments.size(); i++) {
                if (m_segments[i].stop > rt) {
                    return (POSITION)(INT_PTR)(i + 1);
                }
            }
            return nullptr;
        }
        STDMETHODIMP_(POSITION) GetNext(POSITION pos) override {
            size_t next = (size_t)(INT_PTR)pos;
            return next < m_segments.size() ? (POSITION)(INT_PTR)(next + 1) : nullptr;
        }
        STDMETHODIMP_(REFERENCE_TIME) GetStart(POSITION pos, double) override { return m_segments[(size_t)(INT_PTR)pos - 1].start; }
        STDMETHODIMP_(REFERENCE_TIME) GetStop(POSITION pos, double) override { return m_segments[(size_t)(INT_PTR)pos - 1].stop; }
        STDMETHODIMP_(bool) IsAnimated(POSITION pos) override { return m_segments[(size_t)(INT_PTR)pos - 1].animated; }
        STDMETHODIMP Render(SubPicDesc&, REFERENCE_TIME rt, double, RECT& bbox) override {
            m_renderTimes.push_back(rt);
            bbox = m_bbox;
            return m_hrRender;
        }
    };

    struct Dual {
        CComPtr<CSegmentProvider> pPrimary, pSecondary;
        CComPtr<ISubPicProvider> pDual;

        Dual(CSegmentProvider* primary, CSegmentProvider* secondary)
            : pPrimary(primary), pSecondary(secondary) {
            pDual = new CDualSubPicProvider(pPrimary, pSecondary);
        }
        Dual(std::vector<Segment> primary, std::vector<Segment> secondary)
            : Dual(new CSegmentProvider(std::move(primary)), new CSegmentProvider(std::move(secondary))) {}

        // The timeline as the queue reads it, from the given time on
        std::vector<Segment> Timeline(REFERENCE_TIME rt) const {
            std::vector<Segment> merged;
            for (POSITION pos = pDual->GetStartPosition(rt, 24.0); pos; pos = pDual->GetNext(pos)) {
                merged.push_back({ pDual->GetStart(pos, 24.0), pDual->GetStop(pos, 24.0), pDual->IsAnimated(pos) });
            }
            return merged;
        }
    };

    void ExpectTimeline(const std::vector<Segment>& actual, const std::vector<Segment>& expected)
    {
        ASSERT_EQ(actual.size(), expected.size());
        for (size_t i = 0; i < expected.size(); i++) {
            EXPECT_EQ(actual[i].start, expected[i].start) << "segment " << i;
            EXPECT_EQ(actual[i].stop, expected[i].stop) << "segment " << i;
            EXPECT_EQ(actual[i].animated, expected[i].animated) << "segment " << i;
        }
    }
}

TEST(DualSubPicProvider, OverlappingLinesSplitAtEveryBoundary)
{
    Dual d({ { 1000 * kMs, 5000 * kMs, false } }, { { 3000 * kMs, 8000 * kMs, false } });
    ExpectTimeline(d.Timeline(0), {
        { 1000 * kMs, 3000 * kMs, false },
        { 3000 * kMs, 5000 * kMs, false },
        { 5000 * kMs, 8000 * kMs, false },
    });
}

TEST(DualSubPicProvider, GapWithNeitherTrackIsNotASegment)
{
    Dual d({ { 1000 * kMs, 2000 * kMs, false } }, { { 6000 * kMs, 7000 * kMs, false } });
    ExpectTimeline(d.Timeline(0), {
        { 1000 * kMs, 2000 * kMs, false },
        { 6000 * kMs, 7000 * kMs, false },
    });
}

TEST(DualSubPicProvider, SegmentIsAnimatedWhenEitherTrackIs)
{
    Dual d({ { 1000 * kMs, 5000 * kMs, true } }, { { 3000 * kMs, 8000 * kMs, false } });
    ExpectTimeline(d.Timeline(0), {
        { 1000 * kMs, 3000 * kMs, true },
        { 3000 * kMs, 5000 * kMs, true },
        { 5000 * kMs, 8000 * kMs, false },
    });
}

TEST(DualSubPicProvider, SegmentsThatHaveEndedAreLeftOut)
{
    Dual d({ { 1000 * kMs, 2000 * kMs, false }, { 4000 * kMs, 5000 * kMs, false } }, { { 1500 * kMs, 4500 * kMs, false } });
    ExpectTimeline(d.Timeline(4200 * kMs), {
        { 4000 * kMs, 4500 * kMs, false },
        { 4500 * kMs, 5000 * kMs, false },
    });
}

TEST(DualSubPicProvider, OnlyOneTrackHasLines)
{
    const std::vector<Segment> empty;
    Dual d(empty, { { 3000 * kMs, 8000 * kMs, true } });
    ExpectTimeline(d.Timeline(0), { { 3000 * kMs, 8000 * kMs, true } });
    Dual none(empty, empty);
    EXPECT_EQ(none.pDual->GetStartPosition(0, 24.0), nullptr);
}

// A segment one tick long that starts at the time asked about is a segment like
// any other: the lines after it, of both tracks, stay in the timeline.
TEST(DualSubPicProvider, OneTickSegmentAtTheAskedTimeDoesNotEndTheTimeline)
{
    const REFERENCE_TIME rt = 1000 * kMs;
    for (bool bInPrimary : { true, false }) {
        std::vector<Segment> withTick = { { rt, rt + 1, false }, { 2000 * kMs, 3000 * kMs, false } };
        std::vector<Segment> other = { { 2500 * kMs, 4000 * kMs, true } };
        Dual d(bInPrimary ? withTick : other, bInPrimary ? other : withTick);
        ExpectTimeline(d.Timeline(rt), {
            { rt, rt + 1, false },
            { 2000 * kMs, 2500 * kMs, false },
            { 2500 * kMs, 3000 * kMs, true },
            { 3000 * kMs, 4000 * kMs, true },
        });
    }
}

TEST(DualSubPicProvider, RendersBothTracksAndJoinsTheirBoxes)
{
    Dual d(new CSegmentProvider({ { 0, 5000 * kMs, false } }, S_OK, CRect(100, 600, 500, 700)),
           new CSegmentProvider({ { 0, 5000 * kMs, false } }, S_OK, CRect(300, 50, 900, 120)));
    SubPicDesc spd;
    CRect bbox;
    EXPECT_EQ(d.pDual->Render(spd, 1234 * kMs, 24.0, bbox), S_OK);
    EXPECT_EQ(bbox, CRect(100, 50, 900, 700));
    ASSERT_EQ(d.pPrimary->m_renderTimes.size(), 1u);
    ASSERT_EQ(d.pSecondary->m_renderTimes.size(), 1u);
    EXPECT_EQ(d.pPrimary->m_renderTimes[0], 1234 * kMs);
    EXPECT_EQ(d.pSecondary->m_renderTimes[0], 1234 * kMs);
}

TEST(DualSubPicProvider, RenderIsEmptyOnlyWhenBothTracksAre)
{
    SubPicDesc spd;
    CRect bbox;
    Dual oneEmpty(new CSegmentProvider({}, S_FALSE), new CSegmentProvider({}, S_OK, CRect(0, 0, 10, 10)));
    EXPECT_EQ(oneEmpty.pDual->Render(spd, 0, 24.0, bbox), S_OK);
    Dual bothEmpty(new CSegmentProvider({}, S_FALSE), new CSegmentProvider({}, S_FALSE));
    EXPECT_EQ(bothEmpty.pDual->Render(spd, 0, 24.0, bbox), S_FALSE);
    Dual oneFailed(new CSegmentProvider({}, S_OK, CRect(0, 0, 10, 10)), new CSegmentProvider({}, E_FAIL));
    EXPECT_EQ(oneFailed.pDual->Render(spd, 0, 24.0, bbox), E_FAIL);
}
