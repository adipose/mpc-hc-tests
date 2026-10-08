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
#include "../../src/mpc-hc/CoverArt.h"

// CoverArt::FindExternal (src/mpc-hc/CoverArt.cpp, compiled into this project)
// picks the external cover art for a playing file. 00904b77b4: after the exact
// names it fell back to "* front.*" and "* cover.*" wildcards, so any image
// whose name ended in " cover.jpg" or " front.jpg" - a scan of the back of a
// release, a track whose title ends in "cover" - was shown as the cover. The
// fix drops the wildcards; only the exact names (and the per-file and author
// matches) count.

namespace
{
    CStringW MakeArtDir(LPCWSTR name, std::initializer_list<LPCWSTR> files)
    {
        CStringW dir = mpctest::TempDir() + name;
        if (!CreateDirectoryW(dir, nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) {
            throw std::runtime_error("cannot create " + mpctest::ToUtf8(dir));
        }
        for (LPCWSTR f : files) {
            HANDLE h = CreateFileW(dir + L"\\" + f, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (h == INVALID_HANDLE_VALUE) {
                throw std::runtime_error("cannot create fixture in " + mpctest::ToUtf8(dir));
            }
            CloseHandle(h);
        }
        return dir;
    }
}

TEST(CoverArt, ExactNamesAreFound)
{
    bool isFileArt = true;

    const CStringW dir = MakeArtDir(L"art-exact", { L"cover.jpg" });
    EXPECT_EQ(CoverArt::FindExternal(dir + L"\\song", dir, L"", isFileArt), dir + L"\\cover.jpg");
    EXPECT_FALSE(isFileArt);

    // the wildcard fallback is gone, so a name that merely ends in " cover.jpg"
    // is not the album cover anymore; unfixed it was the match
    const CStringW dirWild = MakeArtDir(L"art-wildcard", { L"Artist - Album - Cover.jpg" });
    EXPECT_EQ(CoverArt::FindExternal(dirWild + L"\\song", dirWild, L"", isFileArt), L"");
}

TEST(CoverArt, FrontWildcardIsGoneToo)
{
    bool isFileArt = true;

    const CStringW dir = MakeArtDir(L"art-front", { L"front.png" });
    EXPECT_EQ(CoverArt::FindExternal(dir + L"\\song", dir, L"", isFileArt), dir + L"\\front.png");

    const CStringW dirWild = MakeArtDir(L"art-front-wildcard", { L"Artist - Album - Front.jpg" });
    EXPECT_EQ(CoverArt::FindExternal(dirWild + L"\\song", dirWild, L"", isFileArt), L"");
}

TEST(CoverArt, FileMatchIsPerPlayingFile)
{
    bool isFileArt = false;

    // an image named after the playing file is its own art, whatever else the
    // folder holds
    const CStringW dir = MakeArtDir(L"art-file", { L"song.jpg", L"Some Release - Back Cover.jpg" });
    EXPECT_EQ(CoverArt::FindExternal(dir + L"\\song", dir, L"", isFileArt), dir + L"\\song.jpg");
    EXPECT_TRUE(isFileArt);

    // and with no per-file image the " cover" name still does not match
    const CStringW dirWild = MakeArtDir(L"art-file-wildcard", { L"Some Release - Back Cover.jpg" });
    EXPECT_EQ(CoverArt::FindExternal(dirWild + L"\\other", dirWild, L"", isFileArt), L"");
}
