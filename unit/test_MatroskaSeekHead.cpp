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

// Void::Fill covers the gap between the SeekHead and Info. The loop it replaced
// computed (1 << 0) - 2 as a QWORD, so a gap of 2 to 125 bytes got no Void
// header at all, and a single minimally sized Void cannot total 129 or 16386.

namespace
{
    // the Voids Fill wrote, as their total sizes; empty if anything else was written
    std::vector<QWORD> FillAndParse(QWORD len, QWORD& written)
    {
        CComPtr<IStream> pStream;
        EXPECT_HRESULT_SUCCEEDED(CreateStreamOnHGlobal(nullptr, TRUE, &pStream));
        EXPECT_HRESULT_SUCCEEDED(Void::Fill(pStream, len));
        ULARGE_INTEGER end = {};
        pStream->Seek({}, STREAM_SEEK_CUR, &end);
        written = end.QuadPart;

        std::vector<BYTE> b((size_t)written);
        pStream->Seek({}, STREAM_SEEK_SET, nullptr);
        ULONG got = 0;
        pStream->Read(b.data(), (ULONG)b.size(), &got);

        std::vector<QWORD> voids;
        size_t at = 0;
        while (at < b.size()) {
            if (b[at] != 0xEC || at + 1 >= b.size()) {
                return {};
            }
            BYTE first = b[at + 1];
            int n = 1;
            while (n <= 8 && !(first & (0x80 >> (n - 1)))) {
                n++;
            }
            if (n > 8 || at + 1 + n > b.size()) {
                return {};
            }
            QWORD size = first & ((0x80 >> (n - 1)) - 1);
            for (int i = 1; i < n; i++) {
                size = (size << 8) | b[at + 1 + i];
            }
            QWORD total = 1 + n + size;
            if (at + total > b.size()) {
                return {};
            }
            voids.push_back(total);
            at += (size_t)total;
        }
        return voids;
    }
}

TEST(MatroskaVoidFill, EveryGapIsCoveredByVoids)
{
    for (QWORD len : { 2, 3, 125, 126, 127, 128, 129, 130, 16384, 16385, 16386, 16387, 100000, 2097154 }) {
        QWORD written = 0;
        std::vector<QWORD> voids = FillAndParse(len, written);
        EXPECT_EQ(written, len) << "gap " << len;
        EXPECT_FALSE(voids.empty()) << "gap " << len << " is not all Void elements";
        EXPECT_LE(voids.size(), 2u) << "gap " << len;
    }
}

TEST(MatroskaVoidFill, SizesOneVoidCannotTotalTakeTwo)
{
    QWORD written = 0;
    EXPECT_EQ(FillAndParse(125, written), (std::vector<QWORD> { 125 }));
    EXPECT_EQ(FillAndParse(129, written), (std::vector<QWORD> { 2, 127 }));
    EXPECT_EQ(FillAndParse(16386, written), (std::vector<QWORD> { 2, 16384 }));
}

TEST(MatroskaVoidFill, ZeroWritesNothingAndOneCannotBeFilled)
{
    QWORD written = 0;
    EXPECT_TRUE(FillAndParse(0, written).empty());
    EXPECT_EQ(written, 0u);

    CComPtr<IStream> pStream;
    ASSERT_HRESULT_SUCCEEDED(CreateStreamOnHGlobal(nullptr, TRUE, &pStream));
    EXPECT_EQ(Void::Fill(pStream, 1), E_INVALIDARG);
}

TEST(MatroskaSeekHead, ZeroSpaceDoesNotFit)
{
    Seek seek;
    Build(seek, 1);
    EXPECT_EQ(seek.FitInto(0), -1);
}
