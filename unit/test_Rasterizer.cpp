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
#include "../../src/Subtitles/Rasterizer.h"
#include "../../src/SubPic/ISubPic.h"

// The rasterizer (src/Subtitles/Rasterizer.cpp): outline sizing for bezier and
// b-spline path segments (60544135a5), the 128 MB overlay cap (eb0db38518) and
// the AVX2 solid-fill blend (c53a64dec2). Paths are fed straight into the
// protected members through a subclass -- what GDI's GetPath would have
// returned, without a device context or a font. Path coordinates are 1/8
// pixel, as ScanConvert expects them.

using namespace testutil;

namespace
{
    class CTestRasterizer : public Rasterizer
    {
    public:
        void SetPath(const POINT* pts, const BYTE* types, int n)
        {
            // _TrashPath frees these with delete[], so allocate the same way
            mpPathPoints = new POINT[n];
            mpPathTypes = new BYTE[n];
            memcpy(mpPathPoints, pts, n * sizeof(POINT));
            memcpy(mpPathTypes, types, n * sizeof(BYTE));
            mPathPoints = n;
        }
        bool UsingAVX2() const { return m_bUseAVX2; }
        const COutlineDataSharedPtr& Outline() const { return m_pOutlineData; }
        const COverlayDataSharedPtr& Overlay() const { return m_pOverlayData; }
    };

    // Scalar reference for the blend FillSolidRect performs (alpha 0x40), one
    // DWORD pixel (A<<24|R<<16|G<<8|B) at a time. Mirrors pix_mix_row.
    DWORD MixSolidRef(DWORD dst, DWORD color)
    {
        const DWORD a = (0x40 * (color >> 24) + 32) >> 6;
        const DWORD inv = 0x100 - a, fwd = a + 1;
        const DWORD b = ((dst & 0xff) * inv + (color & 0xff) * fwd) >> 8;
        const DWORD g = (((dst >> 8) & 0xff) * inv + ((color >> 8) & 0xff) * fwd) >> 8;
        const DWORD r = (((dst >> 16) & 0xff) * inv + ((color >> 16) & 0xff) * fwd) >> 8;
        const DWORD al = ((dst >> 24) * inv) >> 8;
        return (al << 24) | (r << 16) | (g << 8) | b;
    }
}

// 60544135a5: ScanConvert used to size the outline from the raw path points,
// so a bezier's control points -- which the curve only leans toward -- blew
// the bounding box up to the control polygon. The curve's real extremes are
// computed now (AnalyzeBezierMinMax). Here a cubic from (0,0) to (100,0) px
// with both control points at y = -90000 px: the curve bottoms out at exactly
// -67500 px, so the outline must be sized for that, not for -90000. Isolated:
// an outline sized too small is an out-of-bounds write during scan conversion.
TEST_ISOLATED(Rasterizer, BezierOutlineSizedFromTheCurveNotTheControlPoints)
{
    const POINT pts[] = { {0, 0}, {0, -720000}, {800, -720000}, {800, 0} };
    const BYTE types[] = { PT_MOVETO, PT_BEZIERTO, PT_BEZIERTO, PT_BEZIERTO };
    CTestRasterizer r;
    r.SetPath(pts, types, 4);
    ASSERT_TRUE(r.ScanConvert());
    ASSERT_TRUE(r.Outline() != nullptr);
    // the unfixed code reports mPathOffsetY -90000 and mHeight 90001 here;
    // the curve's own extremes give -67504 (rounded out to a multiple of 8)
    // and 67505
    EXPECT_NEAR(r.Outline()->mPathOffsetY, -67504, 16);
    EXPECT_NEAR(r.Outline()->mHeight, 67505, 16);
}

// 60544135a5 again, for a b-spline: the curve does not even pass through its
// control points. The same four points as a spline keep the curve between
// y = -86250 and y = -75000 px and x = 16 and 84 px, so the outline must sit
// far inside the control polygon -- which is also where the moveto point
// (0,0) pulls the top and left edges.
TEST_ISOLATED(Rasterizer, BSplineOutlineSizedFromTheCurveNotTheControlPoints)
{
    const POINT pts[] = { {0, 0}, {0, -720000}, {800, -720000}, {800, 0} };
    const BYTE types[] = { PT_MOVETO, PT_BSPLINETO, PT_BSPLINETO, PT_BSPLINETO };
    CTestRasterizer r;
    r.SetPath(pts, types, 4);
    ASSERT_TRUE(r.ScanConvert());
    ASSERT_TRUE(r.Outline() != nullptr);
    // the unfixed code reports offsetY -90000, height 90001 and width 101
    EXPECT_NEAR(r.Outline()->mPathOffsetY, -86256, 16);
    EXPECT_NEAR(r.Outline()->mHeight, 86257, 16);
    EXPECT_NEAR(r.Outline()->mWidth, 85, 8);
}

// #4471: the closing segments of an ASS spline (`m 0 0 s A B C c`) were left
// out of the outline size. `c` appends the first three spline points again as
// PT_BSPLINEPATCHTO, and ScanConvert draws a b-spline segment from points
// i-3..i for each of them, but sized the outline from the patch point alone,
// while the controls before it were skipped as spline points. So a closing
// segment that reaches past the other points runs off the outline. In each
// case below C pulls the closed spline out to the knot (B + 4C + P0) / 6,
// while the unfixed sizing stops at the first segment's end, (A + 4B + C) / 6.
// Clamping the scanline index at the bottom (the first patch proposed on the
// issue) only stops the first case crashing: the shape is then cut off at the
// bottom of the outline, and the other two cases still write out of bounds.
static void SetClosedSpline(CTestRasterizer& r, POINT a, POINT b, POINT c)
{
    const POINT pts[] = {
        {0, 0},                                  // m 0 0
        a, b, c,                                 // s A B C
        {0, 0}, a, b,                            // c
    };
    const BYTE types[] = {
        PT_MOVETO,
        PT_BSPLINETO, PT_BSPLINETO, PT_BSPLINETO,
        PT_BSPLINEPATCHTO, PT_BSPLINEPATCHTO, PT_BSPLINEPATCHTO,
    };
    r.SetPath(pts, types, _countof(pts));
}

// Down: the knot is at y = 4133, the unfixed sizing stops at 1533, and the
// scan conversion writes about 325 rows past the end of the scanline buffer,
// the heap corruption (0xc0000374) of the report.
TEST_ISOLATED(Rasterizer, ClosedSplineOutlineCoversTheClosingSegments)
{
    CTestRasterizer r;
    SetClosedSpline(r, {800, 0}, {800, 800}, {0, 6000});
    ASSERT_TRUE(r.ScanConvert());
    ASSERT_TRUE(r.Outline() != nullptr);
    // the unfixed code reports offsetY 0 and height 193
    EXPECT_GE(r.Outline()->mPathOffsetY + r.Outline()->mHeight, 4133 / 8 + 1);
}

// The same shape filled: it must be drawn down to the knot. With only the
// index clamped, the scan stops at the outline's last row, 192, and nothing
// is drawn below overlay row 24, about 40 rows short of the shape.
TEST_ISOLATED(Rasterizer, ClosedSplineIsDrawnDownToItsClosingSegments)
{
    CTestRasterizer r;
    SetClosedSpline(r, {800, 0}, {800, 800}, {0, 6000});
    ASSERT_TRUE(r.ScanConvert());
    ASSERT_TRUE(r.Rasterize(0, 0, false, 0.0));
    const auto& o = r.Overlay();
    ASSERT_TRUE(o != nullptr && o->mpOverlayBufferBody != nullptr);
    int lastRow = -1;
    for (int y = 0; y < o->mOverlayHeight; y++) {
        const byte* row = o->mpOverlayBufferBody + (size_t)y * o->mOverlayPitch;
        for (int x = 0; x < o->mOverlayWidth; x++) {
            if (row[x]) {
                lastRow = y;
                break;
            }
        }
    }
    // the knot is outline row 516, overlay row 64; allow a few rows for the
    // thin tip of the shape
    EXPECT_GE(o->mOffsetY + lastRow, 60) << "last drawn overlay row " << lastRow << ", offset " << o->mOffsetY;
}

// Up: the mirror image. The knot is at y = -4133 and the unfixed sizing
// stops at -1533, so the scan writes about 325 rows before the start of the
// scanline buffer, which a clamp on the bottom row does not touch.
TEST_ISOLATED(Rasterizer, ClosedSplineAboveTheOutlineStaysInTheScanBuffer)
{
    CTestRasterizer r;
    SetClosedSpline(r, {800, 0}, {800, -800}, {0, -6000});
    ASSERT_TRUE(r.ScanConvert());
    ASSERT_TRUE(r.Outline() != nullptr);
    EXPECT_LE(r.Outline()->mPathOffsetY, -4133 / 8);
    EXPECT_TRUE(r.Rasterize(0, 0, false, 0.0));
}

// Left: the knot is at x = -3867, inside the outline's rows, and the unfixed
// sizing stops at x = -334. The scan buffer is not overrun, but the spans
// start left of the outline, and Rasterize turns those negative x positions
// into huge unsigned offsets into the overlay buffer.
TEST_ISOLATED(Rasterizer, ClosedSplineLeftOfTheOutlineStaysInTheOverlay)
{
    CTestRasterizer r;
    SetClosedSpline(r, {800, 0}, {800, 800}, {-6000, 400});
    ASSERT_TRUE(r.ScanConvert());
    ASSERT_TRUE(r.Outline() != nullptr);
    EXPECT_LE(r.Outline()->mPathOffsetX, -3867 / 8);
    EXPECT_TRUE(r.Rasterize(0, 0, false, 0.0));
}

// eb0db38518: the overlay buffers were allocated with no cap on their size,
// pitch times height computed in 32-bit int. A drawing scaled past that (an
// ASS \fscx/\fscy or a huge {\p1} shape) either allocated gigabytes for one
// subtitle or overflowed the int into a small allocation the rasterizer then
// wrote past. Rasterize now refuses an overlay past 128 MB. Here a
// 130000 x 130000 px rectangle, an overlay of ~252 MB: the unfixed code
// allocates two such buffers and rasterizes into them, and returns true.
TEST_ISOLATED(Rasterizer, RasterizeRefusesAnOverlayPast128MB)
{
    const LONG m = 1040000; // 130000 px in 1/8 units
    const POINT pts[] = { {0, 0}, {m, 0}, {m, m}, {0, m} };
    const BYTE types[] = { PT_MOVETO, PT_LINETO, PT_LINETO, PT_LINETO | PT_CLOSEFIGURE };
    CTestRasterizer r;
    r.SetPath(pts, types, 4);
    ASSERT_TRUE(r.ScanConvert());
    EXPECT_FALSE(r.Rasterize(0, 0, false, 0.0));
    EXPECT_TRUE(r.Overlay() == nullptr);
}

// c53a64dec2: the 16-pixel SSE tail of the AVX2 pix_mix_row read its fourth
// 16-byte block at dst+64 instead of dst+48, so the last four pixels of the
// tail were blended from the wrong source pixels (and from past the row when
// the tail ends the row). FillSolidRect is the public entry into that blend.
// Widths 48 and 80 put a 16-pixel tail after the 32-pixel AVX2 main loop; the
// padding past each row keeps the misread in bounds so the wrong values are
// what is checked.
TEST(RasterizerAvx2, SolidFillTailBlendsTheRightPixels)
{
    CTestRasterizer probe;
    if (!probe.UsingAVX2()) {
        GTEST_SKIP() << "the AVX2 blend path needs an AVX2 CPU";
    }
    const DWORD color = 0x80112233;
    for (int w : {48, 80}) {
        const int h = 3, pitch = w * 4 + 64;
        std::vector<BYTE> buf(pitch * h);
        for (size_t i = 0; i < buf.size(); i++) {
            buf[i] = (BYTE)(i * 37 + 11);
        }
        const std::vector<BYTE> orig = buf;

        SubPicDesc spd;
        spd.w = w;
        spd.h = h;
        spd.bpp = 32;
        spd.pitch = pitch;
        spd.bits = buf.data();
        probe.FillSolidRect(spd, 0, 0, w, h, color);

        for (int y = 0; y < h; y++) {
            const DWORD* row = (const DWORD*)(buf.data() + y * pitch);
            const DWORD* src = (const DWORD*)(orig.data() + y * pitch);
            for (int x = 0; x < w; x++) {
                EXPECT_EQ(row[x], MixSolidRef(src[x], color)) << "w=" << w << " x=" << x << " y=" << y;
            }
        }
    }
}

// Written out rather than TEST_ISOLATED so the AVX2 check can skip in the
// parent instead of running the child at all.
static void MPCTEST_BODY_(RasterizerAvx2, SolidFillTailDoesNotReadPastTheRow)();
TEST(RasterizerAvx2, SolidFillTailDoesNotReadPastTheRow)
{
    CTestRasterizer probe;
    if (!probe.UsingAVX2()) {
        GTEST_SKIP() << "the AVX2 blend path needs an AVX2 CPU";
    }
    MPCTEST_IN_CHILD_(RasterizerAvx2, SolidFillTailDoesNotReadPastTheRow);
}
static void MPCTEST_BODY_(RasterizerAvx2, SolidFillTailDoesNotReadPastTheRow)()
{
    // c53a64dec2: one 48-pixel row whose last byte is the last byte of a
    // page, so the unfixed tail's dst+64 read -- 16 bytes past the row --
    // is an access violation instead of a silent misblend.
    const int w = 48, pitch = w * 4;
    std::vector<BYTE> bytes(pitch, 0x5A);
    GuardedBuffer buf(bytes);
    SubPicDesc spd;
    spd.w = w;
    spd.h = 1;
    spd.bpp = 32;
    spd.pitch = pitch;
    spd.bits = buf.data();
    CTestRasterizer r;
    r.FillSolidRect(spd, 0, 0, w, 1, 0x80112233);
}
