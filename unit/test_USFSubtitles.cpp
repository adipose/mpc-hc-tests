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
#include <msxml6.h>
#include "../../src/Subtitles/USFSubtitles.h"

// CUSFSubtitles (src/Subtitles/USFSubtitles.cpp): USF is an XML subtitle
// format; the parser reads it with MSXML and converts it into a
// CSimpleTextSubtitle. #4225 (e7f72cb70f): the cue times are milliseconds, but
// ConvertToSTS passed them to CSimpleTextSubtitle::Add unconverted, so every
// cue landed in the first millisecond of the timeline (a start of 5.25 s sat
// at 0.525 ms). The fix wraps them in MS2RT.

namespace
{
    const char kUsf[] =
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n"
        "<usfsubtitles>\r\n"
        "  <metadata><language code=\"eng\">English</language></metadata>\r\n"
        "  <subtitles>\r\n"
        "    <subtitle start=\"00:00:05.250\" stop=\"00:00:07.500\"><text>first</text></subtitle>\r\n"
        "    <subtitle start=\"00:01:02.500\" duration=\"00:00:01.500\"><text>second</text></subtitle>\r\n"
        "  </subtitles>\r\n"
        "</usfsubtitles>\r\n";

    struct ComInit {
        HRESULT hr;
        ComInit() { hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED); }
        ~ComInit() { if (SUCCEEDED(hr)) { CoUninitialize(); } }
    };
}

TEST(USF, CueTimesAreMilliseconds)
{
    ComInit com;
    ASSERT_HRESULT_SUCCEEDED(com.hr);

    const CStringW path = testutil::WriteTemp(L"cues.usf", kUsf, sizeof(kUsf) - 1);

    CUSFSubtitles usf;
    ASSERT_TRUE(usf.Read(path));

    CSimpleTextSubtitle sts;
    ASSERT_TRUE(usf.ConvertToSTS(sts));
    ASSERT_EQ(sts.GetCount(), (size_t)2);

    EXPECT_EQ(sts[0].str, L"first");
    EXPECT_EQ(sts[0].start, 5250i64 * 10000);   // 5.25 s
    EXPECT_EQ(sts[0].end,   7500i64 * 10000);   // 7.5 s
    EXPECT_EQ(sts[1].str, L"second");
    EXPECT_EQ(sts[1].start, 62500i64 * 10000);  // 1 min 2.5 s
    EXPECT_EQ(sts[1].end,   64000i64 * 10000);  // start + 1.5 s duration
}
