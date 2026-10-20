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
#include "../../src/filters/muxer/MatroskaMuxer/MatroskaFile.h"

// The Matroska muxer reserves a Void near the start of the file and writes the
// SeekHead over it when recording stops. Seek::FitInto decides what of the
// SeekHead goes there: everything if it fits, without the Cluster entries if
// not, nothing if even that is too big. Before it, a SeekHead larger than the
// reservation was written anyway, over the Info and Tracks that follow it.

using namespace MatroskaWriter;

namespace
{
    const DWORD kInfo = 0x1549A966, kTracks = 0x1654AE6B, kCluster = 0x1F43B675, kCues = 0x1C53BB6B, kTags = 0x1254C367;

    void Add(Seek& seek, DWORD id, UINT64 pos)
    {
        CAutoPtr<SeekHead> sh(DEBUG_NEW SeekHead());
        sh->ID.Set(id);
        sh->Position.Set(pos);
        seek.SeekHeads.AddTail(sh);
    }

    // the layout ThreadProc builds: Info, Tracks, one entry per cluster, Cues, Tags
    void Build(Seek& seek, int clusters)
    {
        Add(seek, kInfo, 0x80);
        Add(seek, kTracks, 0x100);
        for (int i = 0; i < clusters; i++) {
            Add(seek, kCluster, 0x200 + (UINT64)i * 0x10000);
        }
        Add(seek, kCues, 0x7000000);
        Add(seek, kTags, 0x7100000);
    }

    std::vector<DWORD> Ids(Seek& seek)
    {
        std::vector<DWORD> ids;
        POSITION pos = seek.SeekHeads.GetHeadPosition();
        while (pos) {
            ids.push_back(seek.SeekHeads.GetNext(pos)->ID.GetSeekID());
        }
        return ids;
    }

    QWORD Written(Seek& seek)
    {
        CComPtr<IStream> pStream;
        EXPECT_HRESULT_SUCCEEDED(CreateStreamOnHGlobal(nullptr, TRUE, &pStream));
        seek.Write(pStream);
        ULARGE_INTEGER pos = {};
        pStream->Seek({}, STREAM_SEEK_CUR, &pos);
        return pos.QuadPart;
    }

    QWORD SizeWithout(int clusters)
    {
        Seek seek;
        Build(seek, clusters);
        return seek.Size();
    }
}

TEST(MatroskaSeekHead, FitsAndKeepsEveryEntry)
{
    Seek seek;
    Build(seek, 10);
    QWORD size = seek.Size();
    EXPECT_EQ(seek.FitInto(size + 100), 100);
    EXPECT_EQ(seek.SeekHeads.GetCount(), 14u);
    EXPECT_EQ(Written(seek), size);
}

TEST(MatroskaSeekHead, ExactFitLeavesNoGap)
{
    Seek seek;
    Build(seek, 10);
    EXPECT_EQ(seek.FitInto(seek.Size()), 0);
    EXPECT_EQ(seek.SeekHeads.GetCount(), 14u);
}

TEST(MatroskaSeekHead, TooManyClustersDropsOnlyTheClusterEntries)
{
    Seek seek;
    Build(seek, 5000);
    QWORD space = SizeWithout(0) + 50;
    ASSERT_GT(seek.Size(), space);
    INT64 fit = seek.FitInto(space);
    EXPECT_EQ(fit, 50);
    EXPECT_EQ(Ids(seek), (std::vector<DWORD> { kInfo, kTracks, kCues, kTags }));
    // what is written stays inside the reservation
    EXPECT_EQ(Written(seek), space - (QWORD)fit);
}

TEST(MatroskaSeekHead, OneByteGapCountsAsNotFitting)
{
    // a one byte gap cannot hold a Void, so the cluster entries go
    Seek seek;
    Build(seek, 3);
    EXPECT_EQ(seek.FitInto(seek.Size() + 1), (INT64)(SizeWithout(3) + 1 - SizeWithout(0)));
    EXPECT_EQ(Ids(seek), (std::vector<DWORD> { kInfo, kTracks, kCues, kTags }));
}

TEST(MatroskaSeekHead, OneByteGapWithoutClustersDoesNotFit)
{
    Seek seek;
    Build(seek, 0);
    EXPECT_EQ(seek.FitInto(seek.Size() + 1), -1);
}

TEST(MatroskaSeekHead, TooSmallEvenWithoutClustersDoesNotFit)
{
    Seek seek;
    Build(seek, 100);
    EXPECT_EQ(seek.FitInto(SizeWithout(0) - 1), -1);
}

TEST(MatroskaSeekHead, ZeroSpaceDoesNotFit)
{
    Seek seek;
    Build(seek, 1);
    EXPECT_EQ(seek.FitInto(0), -1);
}
