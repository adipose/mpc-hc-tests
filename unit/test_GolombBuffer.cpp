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
#include "../../src/DSUtil/GolombBuffer.h"

// CGolombBuffer is the bit reader under the PGS, DVB and VobSub parsers and
// the DVB section tables. Its contract at the end of its buffer is what keeps
// a truncated segment from becoming an over-read in all of them. The
// Exp-Golomb, escape-removal and start-code parts have no caller in the
// player and are not covered.

using testutil::Bytes;
using testutil::GuardedBuffer;

TEST(Golomb, BitsAcrossByteBoundaries)
{
    const BYTE data[] = { 0xA5, 0x3C, 0xFF, 0x00 }; // 1010 0101 0011 1100 1111 1111 0000 0000
    CGolombBuffer gb(data, sizeof(data));
    EXPECT_EQ(gb.BitRead(3), 5u);      // 101
    EXPECT_EQ(gb.BitRead(7), 0x14u);   // 0 0101 00
    EXPECT_EQ(gb.BitsLeft(), 22);
    EXPECT_EQ(gb.BitRead(12), 0xF3Fu); // 11 1100 1111 11
    EXPECT_EQ(gb.BitRead(10), 0x300u);  // 11 0000 0000
    EXPECT_TRUE(gb.IsEOF());
    EXPECT_EQ(gb.BitsLeft(), 0);
}

TEST(Golomb, WholeWordsBigAndLittleEndian)
{
    const BYTE data[] = { 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    CGolombBuffer gb(data, sizeof(data));
    EXPECT_EQ(gb.ReadShort(), (SHORT)0x1234);
    EXPECT_EQ(gb.ReadShortLE(), (SHORT)0x7856);
    EXPECT_EQ(gb.ReadDword(), 0x9ABCDEF0u);
    EXPECT_EQ(gb.ReadDwordLE(), 0x44332211u);
    EXPECT_EQ(gb.BitRead(64), 0u);     // only four bytes left: the read is short and returns 0
}

TEST(Golomb, SixtyFourBitReadIsNotUndefined)
{
    const BYTE data[] = { 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01 };
    CGolombBuffer gb(data, sizeof(data));
    EXPECT_EQ(gb.BitRead(64), 0x8000000000000001ui64);
    EXPECT_TRUE(gb.IsEOF());
}

TEST(Golomb, PeekDoesNotAdvance)
{
    const BYTE data[] = { 0xC3, 0x00 };
    CGolombBuffer gb(data, sizeof(data));
    EXPECT_EQ(gb.BitRead(2, true), 3u);
    EXPECT_EQ(gb.BitRead(2, true), 3u);
    EXPECT_EQ(gb.GetPos(), 0);
    EXPECT_EQ(gb.BitRead(4), 0xCu);
    EXPECT_EQ(gb.BitRead(4, true), 3u);
    EXPECT_EQ(gb.BitRead(4), 3u);
    EXPECT_EQ(gb.GetPos(), 1);
}

TEST(Golomb, AlignSkipSeekAndPosition)
{
    const BYTE data[] = { 0xFF, 0x01, 0x02, 0x03, 0x04 };
    CGolombBuffer gb(data, sizeof(data));
    gb.BitRead(3);
    EXPECT_EQ(gb.GetPos(), 1);        // a byte with bits taken from it counts as consumed
    gb.BitByteAlign();
    EXPECT_EQ(gb.GetPos(), 1);
    EXPECT_EQ(gb.ReadByte(), 0x01);
    gb.SkipBytes(1);
    EXPECT_EQ(gb.ReadByte(), 0x03);
    EXPECT_EQ(gb.RemainingSize(), 1);
    gb.Seek(1);
    EXPECT_EQ(gb.ReadByte(), 0x01);
    gb.Reset();
    EXPECT_EQ(gb.ReadByte(), 0xFF);
    EXPECT_EQ(gb.GetSize(), 5);
}

// Every read past the end returns 0, and the reader never touches the byte
// after its buffer: with the guard page right behind the data, an over-read
// would be an access violation, not a wrong number.
TEST(Golomb, ReadsPastTheEndReturnZeroAndStayInBounds)
{
    GuardedBuffer g(Bytes({ 0xAB, 0xCD }));
    CGolombBuffer gb(g.data(), (int)g.size());
    EXPECT_EQ(gb.BitRead(12), 0xABCu);
    EXPECT_EQ(gb.BitsLeft(), 4);
    EXPECT_EQ(gb.BitRead(8), 0u);      // only 4 left: short read
    EXPECT_TRUE(gb.IsEOF());
    EXPECT_EQ(gb.BitRead(32), 0u);
    EXPECT_EQ(gb.ReadDword(), 0u);

    BYTE out[8] = { 1, 2, 3, 4, 5, 6, 7, 8 };
    gb.Seek(1);
    gb.ReadBuffer(out, 8);             // asks for more than is left: gets what is left
    EXPECT_EQ(out[0], 0xCD);
    EXPECT_EQ(out[1], 2);
    EXPECT_TRUE(gb.IsEOF());
}

