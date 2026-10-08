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
#include "TestUtil.h"
#include "../../src/DeCSS/VobFile.h"

// CVobFile::GetTitleInfo reads the title map (TT_SRPT) of a VIDEO_TS.IFO to
// learn which VTS and title number a title lives in. #4230 (787c480d39): none
// of the lengths were checked, so on a truncated file the reads came up short
// and the out parameters were whatever was on the stack, and a TT_SRPT sector
// address past the end of the file was sought to and read anyway; both were
// reported as a successful parse. The DSM splitter half of that commit is out
// of scope here.

namespace
{
    // A minimal VIDEO_TS.IFO: the "DVDVIDEO-VMG" magic, the big-endian TT_SRPT
    // sector address at 0xC4, and two fake VTSN/TTN bytes where title 1's entry
    // puts them (sector * 2048 + 8 byte header + 6 into the 12-byte entry).
    std::vector<BYTE> VideoTsIfo(DWORD ttSrptSector, BYTE vtsn, BYTE ttn, size_t fileSize)
    {
        std::vector<BYTE> f(fileSize, 0);
        memcpy(f.data(), "DVDVIDEO-VMG", 12);
        if (fileSize >= 0xC8) {
            DWORD be = _byteswap_ulong(ttSrptSector);
            memcpy(f.data() + 0xC4, &be, 4);
        }
        size_t off = (size_t)ttSrptSector * 2048 + 8 + 6;
        if (off + 2 <= fileSize) {
            f[off] = vtsn;
            f[off + 1] = ttn;
        }
        return f;
    }
}

TEST(VobFile, TitleInfoReadsTheTitleMapping)
{
    const CStringW path = testutil::WriteTemp(L"video_ts_ok.ifo", VideoTsIfo(1, 3, 7, 4096));

    ULONG vtsn = 0, ttn = 0;
    EXPECT_TRUE(CVobFile::GetTitleInfo(path, 1, vtsn, ttn));
    EXPECT_EQ(vtsn, 3u);
    EXPECT_EQ(ttn, 7u);

    // title numbers are 1-based; 0 has no entry. Unfixed it computed the entry
    // address with (0 - 1) * 12, landed two bytes into the sector and read it
    // back as a real mapping.
    EXPECT_FALSE(CVobFile::GetTitleInfo(path, 0, vtsn, ttn));

    EXPECT_FALSE(CVobFile::GetTitleInfo(mpctest::TempDir() + L"video_ts_missing.ifo", 1, vtsn, ttn));
}

TEST(VobFile, TitleInfoRejectsTruncatedAndOutOfRangeIfo)
{
    ULONG vtsn = 0xAA, ttn = 0xAA;

    // a valid header but the file ends before the TT_SRPT sector address field:
    // unfixed the short read left the sector address uninitialized and the
    // garbage it held was still sought to and "read"
    const CStringW truncated = testutil::WriteTemp(L"video_ts_trunc.ifo", VideoTsIfo(1, 3, 7, 100));
    EXPECT_FALSE(CVobFile::GetTitleInfo(truncated, 1, vtsn, ttn));

    // TT_SRPT points past the end of the file
    const CStringW pastEnd = testutil::WriteTemp(L"video_ts_far.ifo", VideoTsIfo(10, 3, 7, 4096));
    EXPECT_FALSE(CVobFile::GetTitleInfo(pastEnd, 1, vtsn, ttn));
}
