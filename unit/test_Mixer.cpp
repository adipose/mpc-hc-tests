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
#include "../../src/thirdparty/AudioTools/Mixer.h"

// CMixer (src/thirdparty/AudioTools/Mixer.cpp) remixes audio through a
// swresample matrix. 8366e3d833: upmixing to 7.1 only handled an input with
// side but no back channels (the sides were divided over both); a 5.1(back)
// input, whose surround channels sit in the back pair, left the 7.1 side
// channels silent. The fix adds the mirror case: back but no side divides the
// back channels over back and side.

namespace
{
    // ffmpeg's AV_CH_* bit values (libavutil/channel_layout.h) are a fixed ABI;
    // naming the layouts here saves pulling the ffmpeg headers into this project
    constexpr uint64_t LAYOUT_5POINT1_BACK = 0x0000003F; // FL FR FC LFE BL BR
    constexpr uint64_t LAYOUT_7POINT1      = 0x0000063F; // + SL SR

    // mixes `frames` of 5.1(back) s16 in which only the back pair sounds
    std::vector<int16_t> MixBackPair(CMixer& mixer, int frames, int16_t bl, int16_t br)
    {
        std::vector<int16_t> in((size_t)frames * 6, 0);
        for (int f = 0; f < frames; f++) {
            in[(size_t)f * 6 + 4] = bl;
            in[(size_t)f * 6 + 5] = br;
        }
        std::vector<int16_t> out((size_t)frames * 8, 0);
        int got = mixer.Mixing((BYTE*)out.data(), frames, (BYTE*)in.data(), frames);
        EXPECT_EQ(got, frames);
        return out;
    }
}

TEST(Mixer, FiveOneBackToSevenOneFeedsTheSideChannels)
{
    const int frames = 480;
    CMixer mixer;
    mixer.SetOptions(1.0, 1.0, false, false);
    mixer.UpdateInput(SAMPLE_FMT_S16, LAYOUT_5POINT1_BACK, 48000);
    mixer.UpdateOutput(SAMPLE_FMT_S16, LAYOUT_7POINT1, 48000);

    std::vector<int16_t> out = MixBackPair(mixer, frames, 10000, -8000);

    // 7.1 channel order: FL FR FC LFE BL BR SL SR; look at a middle frame
    const int16_t* f = &out[(size_t)(frames / 2) * 8];
    EXPECT_EQ(f[0], 0); // nothing was playing in the fronts
    // the back energy is divided over back and side (1/sqrt(2) each), so the
    // sides carry what the backs carry; unfixed the sides stayed at 0
    EXPECT_NEAR(f[4], 7071, 200);  // BL = 10000 / sqrt(2)
    EXPECT_NEAR(f[6], 7071, 200);  // SL
    EXPECT_NEAR(f[5], -5657, 200); // BR = -8000 / sqrt(2)
    EXPECT_NEAR(f[7], -5657, 200); // SR
}
