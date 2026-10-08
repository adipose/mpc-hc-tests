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
#include "../../src/Subtitles/STS.h"
#include "../../src/Subtitles/LibassContext.h"
#include <vector>

// LibassContext::AssFlattenSSE2 (src/Subtitles/LibassContext.cpp) composites
// libass's alpha bitmaps into one buffer in the subpic's own format:
// premultiplied colour and inverted alpha (0xff transparent, 0x00 opaque),
// which RenderFrame then copies straight into the subpic. #4009 (7a8dcdc67d)
// made it so: the buffer now starts transparent (it used to start zeroed,
// which in inverted alpha is opaque black), and the SSE2 alpha multiply no
// longer wraps 256 * 256 to zero.
//
// The images are synthetic ASS_Image records, so no font or renderer is
// involved, and 8 pixels wide so the four-pixel SSE2 path runs, not only the
// scalar tail. Expected values follow the C reference in that commit:
//   srcA = ((bitmap + 1) * (255 - colour alpha)) >> 8
//   A'   = ((A + 1) * (256 - srcA) - 1) >> 8
//   C'   = (C * (256 - srcA) + c * (srcA + 1)) >> 8

namespace
{
    struct FlattenProbe : LibassContext {
        using LibassContext::LibassContext;
        const uint32_t* Pixels() const { return m_pixels.get(); }
    };

    struct Image {
        std::vector<unsigned char> bitmap;
        ASS_Image img{};
        Image(int x, int y, int w, int h, uint32_t rgba, std::vector<unsigned char> bits) : bitmap(std::move(bits)) {
            img.w = w;
            img.h = h;
            img.stride = w;
            img.bitmap = bitmap.data();
            img.color = rgba;   // libass: 0xRRGGBBAA, AA = transparency
            img.dst_x = x;
            img.dst_y = y;
            img.next = nullptr;
        }
    };

    struct Flattened {
        CSimpleTextSubtitle sts;
        FlattenProbe ctx{ &sts };
        CRect dirty;
        Flattened(ASS_Image* first) {
            sts.m_subtitleType = Subtitle::ASS;
            SubPicDesc spd;
            spd.w = 64;
            spd.h = 32;
            spd.vidrect = { 0, 0, 64, 32 };   // the same rect whether relative to window or video
            ctx.AssFlattenSSE2(first, spd, dirty);
        }
        // 0xAARRGGBB of the buffer, which spans the union of the images
        uint32_t At(int x, int y) const { return ctx.Pixels()[y * dirty.Width() + x]; }
    };

    int A(uint32_t p) { return p >> 24; }
    int R(uint32_t p) { return (p >> 16) & 0xff; }
    int G(uint32_t p) { return (p >> 8) & 0xff; }
    int B(uint32_t p) { return p & 0xff; }
}

TEST(LibassFlatten, UncoveredPixelsStayTransparent)
{
    // Opaque red; the second row's first half has no coverage.
    std::vector<unsigned char> bits(16, 255);
    for (int x = 0; x < 4; x++) {
        bits[8 + x] = 0;
    }
    Image red(4, 4, 8, 2, 0xFF000000u, bits);
    Flattened f(&red.img);
    ASSERT_EQ(f.dirty, CRect(4, 4, 12, 6));
    for (int x = 0; x < 4; x++) {
        EXPECT_EQ(f.At(x, 1), 0xFF000000u) << "x=" << x << ": no coverage must be fully transparent (inverted alpha 0xff)";
    }
}

TEST(LibassFlatten, FullCoverageIsOpaqueColour)
{
    Image red(0, 0, 8, 1, 0xFF000000u, std::vector<unsigned char>(8, 255));
    Flattened f(&red.img);
    for (int x = 0; x < 8; x++) {
        uint32_t p = f.At(x, 0);
        EXPECT_LE(A(p), 1) << "x=" << x;
        EXPECT_GE(R(p), 254) << "x=" << x;
        EXPECT_EQ(G(p), 0) << "x=" << x;
        EXPECT_EQ(B(p), 0) << "x=" << x;
    }
}

TEST(LibassFlatten, HalfTransparentColour)
{
    // Green at colour alpha 0x80: srcA = (256 * 127) >> 8 = 127,
    // A' = (256 * 129 - 1) >> 8 = 128, G' = (255 * 128) >> 8 = 127.
    Image green(0, 0, 8, 1, 0x00FF0080u, std::vector<unsigned char>(8, 255));
    Flattened f(&green.img);
    for (int x = 0; x < 8; x++) {
        uint32_t p = f.At(x, 0);
        EXPECT_NEAR(A(p), 128, 1) << "x=" << x;
        EXPECT_NEAR(G(p), 127, 1) << "x=" << x;
        EXPECT_EQ(R(p), 0) << "x=" << x;
    }
}

TEST(LibassFlatten, OpaqueOverOpaqueStaysOpaque)
{
    // Blue over red, both fully covering: the top image's colour, alpha still opaque.
    Image red(0, 0, 8, 1, 0xFF000000u, std::vector<unsigned char>(8, 255));
    Image blue(0, 0, 8, 1, 0x0000FF00u, std::vector<unsigned char>(8, 255));
    red.img.next = &blue.img;
    Flattened f(&red.img);
    for (int x = 0; x < 8; x++) {
        uint32_t p = f.At(x, 0);
        EXPECT_LE(A(p), 1) << "x=" << x;
        EXPECT_GE(B(p), 254) << "x=" << x;
        EXPECT_LE(R(p), 1) << "x=" << x;
    }
}
