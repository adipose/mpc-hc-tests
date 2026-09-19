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
#include "../../src/DSUtil/AudioParser.h"
#include <ks.h>
#include <ksmedia.h>

// GetDefChannelMask is what the audio renderer assumes when a WAVEFORMATEX
// arrives without a channel mask: the layout the sound card is told to
// expect. The rest of AudioParser.cpp (the frame header parsers) has no
// caller in the player and is not tested.

TEST(ChannelMask, DefaultLayoutsAreTheKsAudioStandardOnes)
{
    EXPECT_EQ(GetDefChannelMask(1), KSAUDIO_SPEAKER_MONO);
    EXPECT_EQ(GetDefChannelMask(2), KSAUDIO_SPEAKER_STEREO);
    EXPECT_EQ(GetDefChannelMask(3), KSAUDIO_SPEAKER_STEREO | SPEAKER_LOW_FREQUENCY); // 2.1
    EXPECT_EQ(GetDefChannelMask(4), KSAUDIO_SPEAKER_QUAD);
    EXPECT_EQ(GetDefChannelMask(8), KSAUDIO_SPEAKER_7POINT1_SURROUND);
}

// Six channels without a mask is taken as 5.1 with *side* surrounds, the
// layout Windows (and LAV Audio) use for 5.1, not the older back-surround
// KSAUDIO_SPEAKER_5POINT1. Getting this wrong swaps the rear pair to the
// wrong speakers on a 7.1 system.
TEST(ChannelMask, SixChannelsIsFivePointOneSide)
{
    EXPECT_EQ(GetDefChannelMask(6), KSAUDIO_SPEAKER_5POINT1_SURROUND);
    EXPECT_NE(GetDefChannelMask(6), KSAUDIO_SPEAKER_5POINT1);
}

TEST(ChannelMask, EveryDefaultMaskHasAsManyBitsAsChannels)
{
    for (WORD n : { 1, 2, 3, 4, 5, 6, 7, 8, 10, 12 }) {
        const DWORD mask = GetDefChannelMask(n);
        int bits = 0;
        for (DWORD m = mask; m; m &= m - 1) {
            bits++;
        }
        EXPECT_EQ(bits, n) << "channels " << n << " mask 0x" << std::hex << mask;
    }
    for (WORD n : { 0, 9, 11, 13, 16 }) {
        EXPECT_EQ(GetDefChannelMask(n), 0u) << "channels " << n;
    }
}

// Vorbis and FLAC order 5.1 as L C R Ls Rs LFE with back surrounds; the mask
// says which speakers, the decoder's channel order is a separate matter.
TEST(ChannelMask, VorbisMasksUseBackSurrounds)
{
    EXPECT_EQ(GetVorbisChannelMask(2), KSAUDIO_SPEAKER_STEREO);
    EXPECT_EQ(GetVorbisChannelMask(3), SPEAKER_FRONT_LEFT | SPEAKER_FRONT_CENTER | SPEAKER_FRONT_RIGHT);
    EXPECT_EQ(GetVorbisChannelMask(6), KSAUDIO_SPEAKER_5POINT1);
    EXPECT_EQ(GetVorbisChannelMask(8), KSAUDIO_SPEAKER_7POINT1_SURROUND);
    EXPECT_EQ(GetVorbisChannelMask(9), 0u);
}
