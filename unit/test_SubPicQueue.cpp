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
#include "../../src/SubPic/SubPicQueueImpl.h"
#include "../../src/SubPic/SubPicProviderImpl.h"
#include "../../src/SubPic/SubPicImpl.h"
#if __has_include("../../src/SubPic/SubPicQueueTiming.h")
#include "../../src/SubPic/SubPicQueueTiming.h"
#define MPCTEST_HAVE_QUEUE_TIMING 1
#endif
#include <atomic>
#include <cmath>
#include <map>
#include <set>
#include <vector>

// The two subpic queues (src/SubPic/SubPicQueueImpl.cpp), driven the way a
// renderer drives them: SetTime with a frame's time, then LookupSubPic for it.
// The provider is a list of segments and the subpics carry the time they were
// rendered at, so a test can tell which picture each frame was given and how
// many were rendered for nothing. Both subtitle renderers reach the queue as
// such a provider (the internal one, and libass since its timeline in #4470).
//
// What is asserted about animated segments:
//   - a frame is shown a picture rendered for that frame's own time. The
//     buffered queue used to render the middle of a 3/4 frame range that began
//     wherever the previous range ended, up to 3/8 of a frame off the frame;
//   - each frame costs one render. The ranges drifted against the frames once
//     the buffer was full, so about every fourth picture was dropped unseen;
//   - a time within 2 ms of the segment's start or end is rendered at that edge.

namespace
{
    const REFERENCE_TIME kMs = 10000;
    const REFERENCE_TIME kTolerance = 2 * kMs;

    struct Segment {
        REFERENCE_TIME start, stop;
        bool animated;
    };

    // Holds nothing but the time it was rendered at
    class CTimeSubPic : public CSubPicImpl
    {
    public:
        REFERENCE_TIME m_rtRendered = -1;

        STDMETHODIMP_(void*) GetObject() override { return nullptr; }
        STDMETHODIMP GetDesc(SubPicDesc& spd) override {
            spd = SubPicDesc();
            spd.w = 2;
            spd.h = 1;
            spd.bpp = 32;
            spd.pitch = 8;
            spd.bits = reinterpret_cast<BYTE*>(&m_rtRendered);
            spd.vidrect = CRect(0, 0, 2, 1);
            return S_OK;
        }
        STDMETHODIMP CopyTo(ISubPic* pSubPic) override {
            HRESULT hr = __super::CopyTo(pSubPic);
            if (SUCCEEDED(hr)) {
                static_cast<CTimeSubPic*>(pSubPic)->m_rtRendered = m_rtRendered;
            }
            return hr;
        }
        STDMETHODIMP ClearDirtyRect() override {
            m_rcDirty.SetRectEmpty();
            return S_OK;
        }
        STDMETHODIMP Lock(SubPicDesc& spd) override { return GetDesc(spd); }
        STDMETHODIMP Unlock(RECT* pDirtyRect) override {
            m_rcDirty = pDirtyRect ? *pDirtyRect : CRect(0, 0, 2, 1);
            return S_OK;
        }
        STDMETHODIMP AlphaBlt(RECT*, RECT*, SubPicDesc*) override { return S_OK; }
    };

    class CTimeAllocator : public CSubPicAllocatorImpl
    {
        bool Alloc(bool, ISubPic** ppSubPic) override {
            *ppSubPic = new CTimeSubPic();
            (*ppSubPic)->AddRef();
            return true;
        }

    public:
        CTimeAllocator() : CSubPicAllocatorImpl(CSize(2, 1), false) {}
        STDMETHODIMP SetMaxTextureSize(SIZE) override { return S_OK; }
    };

    class CSegmentProvider : public CSubPicProviderImpl
    {
        CCritSec m_lock;
        std::vector<Segment> m_segments;

    public:
        std::atomic<int> m_renders{ 0 };
        std::atomic<int> m_positionQueries{ 0 };
        std::vector<REFERENCE_TIME> m_renderTimes; // written under the provider lock

        explicit CSegmentProvider(std::vector<Segment> segments)
            : CSubPicProviderImpl(&m_lock)
            , m_segments(std::move(segments)) {}

        std::vector<REFERENCE_TIME> RenderTimes() {
            CAutoLock lock(&m_lock);
            return m_renderTimes;
        }

        STDMETHODIMP_(POSITION) GetStartPosition(REFERENCE_TIME rt, double) override {
            m_positionQueries++;
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
        STDMETHODIMP Render(SubPicDesc& spd, REFERENCE_TIME rt, double, RECT& bbox) override {
            memcpy(spd.bits, &rt, sizeof(rt));
            bbox = CRect(0, 0, 2, 1);
            m_renderTimes.push_back(rt);
            m_renders++;
            return S_OK;
        }
    };

    // Frame times as a Matroska file gives them: the exact time rounded to the millisecond
    REFERENCE_TIME FrameTime(int n, double fps)
    {
        return std::llround(n * 1000.0 / fps) * kMs;
    }

    struct Shown {
        REFERENCE_TIME rtFrame;
        REFERENCE_TIME rtRendered; // -1 when the frame got no subpic
    };

    struct Playback {
        CComPtr<CSegmentProvider> pProvider;
        CComPtr<ISubPicQueue> pQueue;
        int nSize = 0;
        double fps = 0;
        std::vector<Shown> shown;

        // bFpsAfterProvider: the order a player start can take, where the thread has
        // the provider, and renders ahead, before the renderer has told the frame rate
        Playback(std::vector<Segment> segments, int size, double framesPerSecond, int nAnimationRate = 100, bool bFpsAfterProvider = false)
            : nSize(size), fps(framesPerSecond) {
            pProvider = new CSegmentProvider(std::move(segments));
            CComPtr<ISubPicAllocator> pAllocator = new CTimeAllocator();
            SubPicQueueSettings settings(size, 2560, 1440, false, 50, nAnimationRate, true);
            HRESULT hr = E_FAIL;
            if (size > 0) {
                pQueue = new CSubPicQueue(settings, pAllocator, &hr);
            } else {
                pQueue = new CSubPicQueueNoThread(settings, pAllocator, &hr);
            }
            EXPECT_HRESULT_SUCCEEDED(hr);
            if (bFpsAfterProvider) {
                pQueue->SetSubPicProvider(pProvider);
                Settle();
                pQueue->SetFPS(fps);
            } else {
                pQueue->SetFPS(fps);
                pQueue->SetSubPicProvider(pProvider);
            }
        }

        ~Playback() {
            pQueue.Release(); // stops the render thread before the provider goes
        }

        // Gives the render thread the time a playing video gives it: until the
        // buffer is full again, or it has nothing left to render.
        void Settle() const {
            if (nSize == 0) {
                return;
            }
            LARGE_INTEGER frequency, counter;
            QueryPerformanceFrequency(&frequency);
            auto micros = [&]() {
                QueryPerformanceCounter(&counter);
                return counter.QuadPart * 1000000 / frequency.QuadPart;
            };
            const long long usStart = micros();
            long long usLastActivity = usStart;
            int nLastActivity = -1;
            for (;;) {
                int nSubPics = 0;
                REFERENCE_TIME rtNow, rtStart, rtStop;
                pQueue->GetStats(nSubPics, rtNow, rtStart, rtStop);
                const int nActivity = pProvider->m_renders + pProvider->m_positionQueries;
                const long long us = micros();
                if (nActivity != nLastActivity) {
                    nLastActivity = nActivity;
                    usLastActivity = us;
                }
                // a full buffer leaves the thread one more render to do; an idle thread shows as silence
                if (us - usLastActivity >= (nSubPics == nSize ? 300 : 5000) || us - usStart > 2000000) {
                    return;
                }
                SwitchToThread();
            }
        }

        Shown Frame(REFERENCE_TIME rt) {
            pQueue->SetTime(rt);
            Settle();
            CComPtr<ISubPic> pSubPic;
            Shown s = { rt, -1 };
            if (pQueue->LookupSubPic(rt, false, pSubPic) && pSubPic) {
                s.rtRendered = static_cast<CTimeSubPic*>(pSubPic.p)->m_rtRendered;
            }
            shown.push_back(s);
            return s;
        }

        void Play(REFERENCE_TIME rtFrom, REFERENCE_TIME rtTo) {
            for (int n = (int)std::ceil(rtFrom / 1e7 * fps); FrameTime(n, fps) < rtTo; n++) {
                if (FrameTime(n, fps) >= rtFrom) {
                    Frame(FrameTime(n, fps));
                }
            }
        }

        std::vector<Shown> ShownIn(REFERENCE_TIME rtStart, REFERENCE_TIME rtStop) const {
            std::vector<Shown> v;
            for (const Shown& s : shown) {
                if (rtStart <= s.rtFrame && s.rtFrame < rtStop) {
                    v.push_back(s);
                }
            }
            return v;
        }
    };

    // Every frame of the animated segment got a picture rendered for its own time,
    // and no more pictures were rendered than there were frames to show them.
    void ExpectOneRenderPerFrame(Playback& p, const Segment& segment)
    {
        const std::vector<Shown> frames = p.ShownIn(segment.start, segment.stop);
        ASSERT_GT(frames.size(), 10u);

        std::map<REFERENCE_TIME, int> timesShown;
        int nMissing = 0, nOff = 0;
        REFERENCE_TIME rtWorst = 0;
        for (const Shown& s : frames) {
            if (s.rtRendered < 0) {
                nMissing++;
                continue;
            }
            timesShown[s.rtRendered]++;
            REFERENCE_TIME rtOff = std::abs(s.rtRendered - s.rtFrame);
            rtWorst = std::max(rtWorst, rtOff);
            if (rtOff > kTolerance) {
                nOff++;
            }
        }
        EXPECT_EQ(nMissing, 0) << "frames inside the segment without a subpic";
        EXPECT_EQ(nOff, 0) << "frames shown a picture rendered more than 2 ms from their time, the worst by "
                           << rtWorst / double(kMs) << " ms";

        int nTwice = 0;
        for (const auto& [rt, n] : timesShown) {
            nTwice += n > 1;
        }
        EXPECT_EQ(nTwice, 0) << "pictures shown at two frames";

        int nRendered = 0;
        for (REFERENCE_TIME rt : p.pProvider->RenderTimes()) {
            nRendered += segment.start <= rt && rt < segment.stop;
        }
        // the thread may have a picture or two ready for frames past the last one played
        EXPECT_LE(nRendered, (int)frames.size() + 2) << "renders for " << frames.size() << " frames";
        EXPECT_GE(nRendered, (int)frames.size());
    }

    // Frames, from the given one on, with no picture or one rendered more than 2 ms from their time
    int CountOffTime(const std::vector<Shown>& frames, size_t first)
    {
        int n = 0;
        for (size_t i = first; i < frames.size(); i++) {
            n += frames[i].rtRendered < 0 || std::abs(frames[i].rtRendered - frames[i].rtFrame) > kTolerance;
        }
        return n;
    }

    const Segment kMove = { 12000 * kMs, 20000 * kMs, true };
}

class SubPicQueueFps : public ::testing::TestWithParam<double> {};

TEST_P(SubPicQueueFps, BufferedQueueRendersEachAnimatedFrameOnceAtItsTime)
{
    Playback p({ kMove }, 10, GetParam());
    p.Play(11500 * kMs, 20500 * kMs);
    ExpectOneRenderPerFrame(p, kMove);
}

TEST_P(SubPicQueueFps, UnbufferedQueueRendersEachAnimatedFrameOnceAtItsTime)
{
    Playback p({ kMove }, 0, GetParam());
    p.Play(11500 * kMs, 20500 * kMs);
    ExpectOneRenderPerFrame(p, kMove);
}

// The frame after an animated line has ended shows nothing. The buffered queue
// lets a subpic stand for a frame's duration past its start, so that rounding
// cannot lose a short line, and with that the last picture of a line could
// stay up for one frame too many.
TEST_P(SubPicQueueFps, BufferedQueueShowsNothingAfterAnAnimatedSegmentEnds)
{
    Playback p({ kMove }, 10, GetParam());
    p.Play(11500 * kMs, 20500 * kMs);
    const std::vector<Shown> after = p.ShownIn(kMove.stop, 20500 * kMs);
    ASSERT_GT(after.size(), 5u);
    for (const Shown& s : after) {
        EXPECT_EQ(s.rtRendered, -1) << "frame at " << s.rtFrame / double(kMs) << " ms, the segment ended at " << kMove.stop / kMs;
    }
}

// What was rendered ahead before the frame rate was known is spaced for the
// default 25 fps and does not fit the frames
TEST_P(SubPicQueueFps, BufferedQueueRendersAgainOnceTheFrameRateIsKnown)
{
    Playback p({ kMove }, 10, GetParam(), 100, true);
    p.Play(11500 * kMs, 13000 * kMs);
    const std::vector<Shown> frames = p.ShownIn(kMove.start, 13000 * kMs);
    ASSERT_GT(frames.size(), 20u);
    EXPECT_EQ(CountOffTime(frames, 0), 0) << "of " << frames.size() << " frames";
}

INSTANTIATE_TEST_SUITE_P(Rates, SubPicQueueFps, ::testing::Values(24000.0 / 1001, 24.0, 25.0, 30000.0 / 1001, 60000.0 / 1001));

// At half the animation rate a picture is kept for two frames, so the frames
// cannot each have their own. What still holds is one render per two frames.
TEST(SubPicQueue, BufferedQueueAtHalfRateRendersEverySecondFrame)
{
    Playback p({ kMove }, 10, 24.0, 50);
    p.Play(11500 * kMs, 20500 * kMs);
    const size_t nFrames = p.ShownIn(kMove.start, kMove.stop).size();
    int nRendered = 0;
    for (REFERENCE_TIME rt : p.pProvider->RenderTimes()) {
        nRendered += kMove.start <= rt && rt < kMove.stop;
    }
    EXPECT_LE(nRendered, (int)nFrames / 2 + 2);
    EXPECT_GE(nRendered, (int)nFrames / 2);
    for (const Shown& s : p.ShownIn(kMove.start, kMove.stop)) {
        EXPECT_GE(s.rtRendered, 0) << "frame at " << s.rtFrame;
    }
}

// The first frame of a fade or a move: a segment that starts on a frame, or
// within 2 ms before it, is first rendered at its start. The buffered queue
// predicts the frame's time, to within the millisecond the times are rounded
// to, so it is not asked about the 2 ms boundary itself.
TEST(SubPicQueue, BufferedQueueRendersTheFirstFrameAtTheSegmentStart)
{
    for (REFERENCE_TIME rtBeforeFrame : { 0 * kMs, 1 * kMs }) {
        const REFERENCE_TIME rtFrame = FrameTime(288, 24.0); // 12 s
        const Segment fade = { rtFrame - rtBeforeFrame, rtFrame + 3000 * kMs, true };
        Playback p({ fade }, 10, 24.0);
        p.Play(11500 * kMs, 12500 * kMs);
        const std::vector<Shown> frames = p.ShownIn(fade.start, fade.stop);
        ASSERT_FALSE(frames.empty());
        EXPECT_EQ(frames[0].rtFrame, rtFrame);
        EXPECT_EQ(frames[0].rtRendered, fade.start) << "segment starts " << rtBeforeFrame / kMs << " ms before the frame";
    }
}

TEST(SubPicQueue, UnbufferedQueueRendersTheFirstFrameAtTheSegmentStart)
{
    for (REFERENCE_TIME rtBeforeFrame : { 0 * kMs, 1 * kMs, 2 * kMs }) {
        const REFERENCE_TIME rtFrame = FrameTime(288, 24.0);
        const Segment fade = { rtFrame - rtBeforeFrame, rtFrame + 3000 * kMs, true };
        Playback p({ fade }, 0, 24.0);
        p.Play(11500 * kMs, 12500 * kMs);
        const std::vector<Shown> frames = p.ShownIn(fade.start, fade.stop);
        ASSERT_FALSE(frames.empty());
        EXPECT_EQ(frames[0].rtRendered, fade.start) << "segment starts " << rtBeforeFrame / kMs << " ms before the frame";
    }
}

// A segment that starts further from the frame than that is rendered at the frame's time
TEST(SubPicQueue, FirstFrameFurtherFromTheStartIsRenderedAtItsOwnTime)
{
    for (int nSize : { 0, 10 }) {
        const REFERENCE_TIME rtFrame = FrameTime(288, 24.0);
        const Segment fade = { rtFrame - 10 * kMs, rtFrame + 3000 * kMs, true };
        Playback p({ fade }, nSize, 24.0);
        p.Play(11500 * kMs, 12500 * kMs);
        const std::vector<Shown> frames = p.ShownIn(fade.start, fade.stop);
        ASSERT_FALSE(frames.empty());
        EXPECT_EQ(frames[0].rtFrame, rtFrame);
        EXPECT_LE(std::abs(frames[0].rtRendered - rtFrame), kTolerance)
                << "queue size " << nSize << ": rendered " << (frames[0].rtRendered - rtFrame) / double(kMs) << " ms from the frame";
    }
}

// The last frame: within 2 ms of the end it is rendered at the last tick of the segment
TEST(SubPicQueue, LastFrameCloseToTheEndIsRenderedAtTheSegmentEnd)
{
    for (int nSize : { 0, 10 }) {
        const REFERENCE_TIME rtLastFrame = FrameTime(360, 24.0); // 15 s
        const Segment fade = { 12000 * kMs, rtLastFrame + 1 * kMs, true };
        Playback p({ fade }, nSize, 24.0);
        p.Play(11500 * kMs, 15500 * kMs);
        const std::vector<Shown> frames = p.ShownIn(fade.start, fade.stop);
        ASSERT_FALSE(frames.empty());
        EXPECT_EQ(frames.back().rtFrame, rtLastFrame);
        EXPECT_EQ(frames.back().rtRendered, fade.stop - 1) << "queue size " << nSize;
    }
}

// A line without animation is rendered once, at the configured point of its
// duration, whatever the queue. Unchanged behaviour, kept as a guard.
TEST(SubPicQueue, StaticSegmentIsRenderedOnce)
{
    for (int nSize : { 0, 10 }) {
        const Segment line = { 2000 * kMs, 5000 * kMs, false };
        // a later line keeps the buffer from running empty, which would have the thread render this one again
        Playback p({ line, { 8000 * kMs, 9000 * kMs, false } }, nSize, 24.0);
        p.Play(1500 * kMs, 5500 * kMs);
        std::vector<REFERENCE_TIME> renders;
        for (REFERENCE_TIME rt : p.pProvider->RenderTimes()) {
            if (line.start <= rt && rt < line.stop) {
                renders.push_back(rt);
            }
        }
        ASSERT_EQ(renders.size(), 1u) << "queue size " << nSize;
        EXPECT_EQ(renders[0], line.start + std::llround((line.stop - line.start - 1) * 0.5));
        for (const Shown& s : p.ShownIn(line.start, line.stop)) {
            EXPECT_EQ(s.rtRendered, renders[0]) << "frame at " << s.rtFrame;
        }
        for (const Shown& s : p.ShownIn(5000 * kMs, 5500 * kMs)) {
            EXPECT_EQ(s.rtRendered, -1) << "frame at " << s.rtFrame;
        }
    }
}

// Between two lines the render thread has the next one ready and then waits.
// A provider that reports its gaps as gaps must not make it go round: the
// libass provider used to answer every time with a segment of its own, and the
// thread rendered without pause.
TEST(SubPicQueue, BufferedQueueWaitsInAGap)
{
    Playback p({ { 2000 * kMs, 5000 * kMs, false }, kMove }, 10, 24.0);
    p.Play(1500 * kMs, 5500 * kMs);
    const int nRendersBefore = p.pProvider->m_renders;
    const int nQueriesBefore = p.pProvider->m_positionQueries;
    p.Play(5500 * kMs, 11500 * kMs); // 144 frames with nothing to show
    for (const Shown& s : p.ShownIn(5500 * kMs, 11500 * kMs)) {
        ASSERT_EQ(s.rtRendered, -1) << "frame at " << s.rtFrame;
    }
    Sleep(100);
    EXPECT_LE(p.pProvider->m_renders - nRendersBefore, 11) << "only the head of the next line may be rendered ahead";
    EXPECT_LE(p.pProvider->m_positionQueries - nQueriesBefore, 3 * 144) << "the thread is going round in the gap";
}

// A seek back invalidates what was rendered ahead; the frames after it are
// served pictures for their own times again.
TEST(SubPicQueue, BufferedQueueFollowsASeekBack)
{
    Playback p({ kMove }, 10, 24.0);
    p.Play(11500 * kMs, 18000 * kMs);
    p.shown.clear();
    p.Play(13000 * kMs, 15000 * kMs);
    const std::vector<Shown> frames = p.ShownIn(13000 * kMs, 15000 * kMs);
    ASSERT_GT(frames.size(), 40u);
    // the frame the seek lands on may be served late; the ones after must be right
    EXPECT_EQ(CountOffTime(frames, 2), 0) << "of " << frames.size() << " frames after the seek";
}

// New subtitle data for a time already rendered ahead (an embedded track
// delivering a sample) drops the stale pictures and renders them again.
TEST(SubPicQueue, BufferedQueueRendersAgainAfterInvalidate)
{
    Playback p({ kMove }, 10, 24.0);
    p.Play(11500 * kMs, 14000 * kMs);
    const int nRendersBefore = p.pProvider->m_renders;
    p.pQueue->Invalidate(14000 * kMs);
    p.shown.clear();
    p.Play(14000 * kMs, 16000 * kMs);
    const std::vector<Shown> frames = p.ShownIn(14000 * kMs, 16000 * kMs);
    ASSERT_GT(frames.size(), 40u);
    EXPECT_EQ(CountOffTime(frames, 2), 0) << "of " << frames.size() << " frames after the invalidation";
    EXPECT_GE(p.pProvider->m_renders - nRendersBefore, (int)frames.size());
}

#ifdef MPCTEST_HAVE_QUEUE_TIMING

TEST(SubPicQueueTiming, SnapsToTheSegmentStartWithinTwoMilliseconds)
{
    using SubPicQueueTiming::SnapToSegmentEdge;
    const REFERENCE_TIME rtStart = 12000 * kMs, rtStop = 20000 * kMs;
    EXPECT_EQ(SnapToSegmentEdge(rtStart, rtStart, rtStop), rtStart);
    EXPECT_EQ(SnapToSegmentEdge(rtStart + 1 * kMs, rtStart, rtStop), rtStart);
    EXPECT_EQ(SnapToSegmentEdge(rtStart + 2 * kMs, rtStart, rtStop), rtStart);
    EXPECT_EQ(SnapToSegmentEdge(rtStart + 2 * kMs + 1, rtStart, rtStop), rtStart + 2 * kMs + 1);
    EXPECT_EQ(SnapToSegmentEdge(rtStart + 15 * kMs, rtStart, rtStop), rtStart + 15 * kMs);
}

TEST(SubPicQueueTiming, SnapsToTheLastTickBeforeTheSegmentEnd)
{
    using SubPicQueueTiming::SnapToSegmentEdge;
    const REFERENCE_TIME rtStart = 12000 * kMs, rtStop = 20000 * kMs;
    EXPECT_EQ(SnapToSegmentEdge(rtStop - 1, rtStart, rtStop), rtStop - 1);
    EXPECT_EQ(SnapToSegmentEdge(rtStop - 2 * kMs, rtStart, rtStop), rtStop - 1);
    EXPECT_EQ(SnapToSegmentEdge(rtStop - 2 * kMs - 1, rtStart, rtStop), rtStop - 2 * kMs - 1);
    // a time outside the segment is left alone
    EXPECT_EQ(SnapToSegmentEdge(rtStop, rtStart, rtStop), rtStop);
    EXPECT_EQ(SnapToSegmentEdge(rtStart - 1 * kMs, rtStart, rtStop), rtStart - 1 * kMs);
}

TEST(SubPicQueueTiming, SegmentShorterThanTheToleranceSnapsToItsStart)
{
    using SubPicQueueTiming::SnapToSegmentEdge;
    EXPECT_EQ(SnapToSegmentEdge(1001 * kMs, 1000 * kMs, 1003 * kMs), 1000 * kMs);
}

TEST(SubPicQueueTiming, UnknownStopTimeDoesNotSnapToTheEnd)
{
    using SubPicQueueTiming::SnapToSegmentEdge;
    const REFERENCE_TIME rt = 5000 * kMs;
    EXPECT_EQ(SnapToSegmentEdge(rt, 1000 * kMs, ISubPicProvider::UNKNOWN_TIME), rt);
}

TEST(SubPicQueueTiming, AlignsUpToTheNextPredictedFrame)
{
    using SubPicQueueTiming::AlignToFrameGrid;
    const REFERENCE_TIME rtFrame = 10000 * kMs, rtPerFrame = 417084; // 23.976 fps
    // three quarters of a frame after a frame: where the previous subpic's range ended
    EXPECT_EQ(AlignToFrameGrid(rtFrame + 5 * rtPerFrame + rtPerFrame * 3 / 4, rtFrame, rtPerFrame), rtFrame + 6 * rtPerFrame);
    EXPECT_EQ(AlignToFrameGrid(rtFrame + 5 * rtPerFrame, rtFrame, rtPerFrame), rtFrame + 5 * rtPerFrame);
    EXPECT_EQ(AlignToFrameGrid(rtFrame + 5 * rtPerFrame + 3 * kMs, rtFrame, rtPerFrame), rtFrame + 6 * rtPerFrame);
}

TEST(SubPicQueueTiming, FrameWithinTheToleranceBeforeTheTimeCounts)
{
    using SubPicQueueTiming::AlignToFrameGrid;
    const REFERENCE_TIME rtFrame = 10000 * kMs, rtPerFrame = 417084;
    // a segment that starts 1 ms after a predicted frame is not pushed a frame on
    const REFERENCE_TIME rt = rtFrame + 5 * rtPerFrame + 1 * kMs;
    EXPECT_EQ(AlignToFrameGrid(rt, rtFrame, rtPerFrame), rt);
}

TEST(SubPicQueueTiming, AlignsATimeBeforeTheKnownFrame)
{
    using SubPicQueueTiming::AlignToFrameGrid;
    const REFERENCE_TIME rtFrame = 10000 * kMs, rtPerFrame = 400000;
    EXPECT_EQ(AlignToFrameGrid(rtFrame - 3 * rtPerFrame, rtFrame, rtPerFrame), rtFrame - 3 * rtPerFrame);
    EXPECT_EQ(AlignToFrameGrid(rtFrame - 3 * rtPerFrame + 10 * kMs, rtFrame, rtPerFrame), rtFrame - 2 * rtPerFrame);
    EXPECT_EQ(AlignToFrameGrid(rtFrame, rtFrame, rtPerFrame), rtFrame);
}

TEST(SubPicQueueTiming, NoFrameDurationLeavesTheTimeAlone)
{
    using SubPicQueueTiming::AlignToFrameGrid;
    EXPECT_EQ(AlignToFrameGrid(12345, 0, 0), 12345);
}

#endif
