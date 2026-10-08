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
#include "../../src/SubPic/SubPicAllocatorPresenterImpl.h"
#include <dvdmedia.h>   // VIDEOINFOHEADER2, AMCONTROL_COLORINFO_PRESENT
#include <dxva2api.h>   // DXVA2_ExtendedFormat and its enum values

// #4298 (68d1bfd20d): GetString("yuvMatrix") guesses the YCbCr matrix from the
// frame size when the media type carries no transfer matrix. The guess tested
// biWidth twice (biWidth <= 1024 && abs(biWidth) <= 576), so the height was
// never looked at: 720x576 PAL came out BT.709 and a 1024x768 frame BT.601.
// The guess is fed here through SetVideoMediaType with a FORMAT_VideoInfo2
// media type, and both of its branches are exercised: the plain one (no
// AMCONTROL_COLORINFO_PRESENT) and the one inside the extended colour info
// for VideoTransferMatrix == 0.
//
// The class wants a valid window handle (the constructor rejects anything
// IsWindow refuses); the desktop window is one, and nothing of it is used by
// the code under test.

namespace
{
    // The pure virtuals as no-ops: CreateRenderer and Paint are all that
    // stands between CSubPicAllocatorPresenterImpl and being constructible.
    class CMatrixAllocatorPresenter : public CSubPicAllocatorPresenterImpl
    {
    public:
        CMatrixAllocatorPresenter(HWND hWnd, HRESULT& hr)
            : CSubPicAllocatorPresenterImpl(hWnd, hr, nullptr) {}
        STDMETHODIMP CreateRenderer(IUnknown** ppRenderer) { return E_NOTIMPL; }
        STDMETHODIMP_(bool) Paint(bool bAll) { return false; }
    };

    DWORD ColorInfoFlags(int nominalRange, int transferMatrix)
    {
        DXVA2_ExtendedFormat fmt = {};
        fmt.NominalRange = nominalRange;
        fmt.VideoTransferMatrix = transferMatrix;
        // The 8.1 SDK's DXVA2_ExtendedFormat has no Value member, so read the
        // bitfields back the same way the player does: by reinterpretation.
        return AMCONTROL_COLORINFO_PRESENT | reinterpret_cast<UINT&>(fmt);
    }

    // The matrix GetString("yuvMatrix") reports for a width x height
    // FORMAT_VideoInfo2 media type with the given dwControlFlags (0: no
    // extended colour info). CStringW() on a call the function rejected.
    CStringW YuvMatrixFor(LONG width, LONG height, DWORD controlFlags = 0)
    {
        VIDEOINFOHEADER2 vih2 = {};
        vih2.bmiHeader.biSize = sizeof(vih2.bmiHeader);
        vih2.bmiHeader.biWidth = width;
        vih2.bmiHeader.biHeight = height;
        vih2.dwControlFlags = controlFlags;

        CMediaType mt;
        mt.SetType(&MEDIATYPE_Video);
        mt.SetSubtype(&MEDIASUBTYPE_RGB24);
        mt.SetFormatType(&FORMAT_VideoInfo2);
        if (!mt.SetFormat((BYTE*)&vih2, sizeof(vih2))) {
            return CStringW();
        }

        HRESULT hr = E_FAIL;
        CMatrixAllocatorPresenter ap(GetDesktopWindow(), hr);
        EXPECT_HRESULT_SUCCEEDED(hr);
        ap.SetVideoMediaType(mt);

        LPWSTR value = nullptr;
        int chars = 0;
        const HRESULT hrGet = ap.GetString("yuvMatrix", &value, &chars);
        EXPECT_HRESULT_SUCCEEDED(hrGet);
        CStringW result;
        if (SUCCEEDED(hrGet)) {
            result = value;
            EXPECT_EQ(chars, result.GetLength());
            LocalFree(value);
        }
        return result;
    }
}

// #4298: SD PAL is BT.601. The old condition never read the height, so this
// came out BT.709.
TEST(SubPicMatrix, SdPalVideoIsGuessedBt601)
{
    EXPECT_EQ(YuvMatrixFor(720, 576), L"TV.601");
}

// #4298: SD NTSC is BT.601.
TEST(SubPicMatrix, SdNtscVideoIsGuessedBt601)
{
    EXPECT_EQ(YuvMatrixFor(720, 480), L"TV.601");
}

// #4298: HD is BT.709 (over both limits; passes before and after the fix, so
// a pass cannot be a guess that always says 601).
TEST(SubPicMatrix, HdVideoIsGuessedBt709)
{
    EXPECT_EQ(YuvMatrixFor(1920, 1080), L"TV.709");
}

// #4298: 1024 wide but 768 high: the height is what puts it over the SD
// limit. The old condition (abs(biWidth) <= 576, false here) said BT.601.
TEST(SubPicMatrix, WideButTallFrameIsGuessedBt709)
{
    EXPECT_EQ(YuvMatrixFor(1024, 768), L"TV.709");
}

// A top-down frame carries a negative biHeight; the guess must judge its
// magnitude.
TEST(SubPicMatrix, TopDownHeightIsGuessedByItsMagnitude)
{
    EXPECT_EQ(YuvMatrixFor(720, -576), L"TV.601");
}

// #4298, the other branch: extended colour info present but with
// VideoTransferMatrix == 0 falls into the same size guess, prefixed by the
// nominal range. The height matters here too.
TEST(SubPicMatrix, GuessInsideColourInfoChecksHeightToo)
{
    EXPECT_EQ(YuvMatrixFor(720, 576, ColorInfoFlags(DXVA2_NominalRange_Unknown, DXVA2_VideoTransferMatrix_Unknown)), L"TV.601");
    EXPECT_EQ(YuvMatrixFor(1024, 768, ColorInfoFlags(DXVA2_NominalRange_Unknown, DXVA2_VideoTransferMatrix_Unknown)), L"TV.709");
}

// An explicit matrix wins over the guess, whatever the frame size, and a
// normal (full) nominal range prefixes PC. instead of TV.
TEST(SubPicMatrix, ExplicitColourInfoBeatsTheGuess)
{
    EXPECT_EQ(YuvMatrixFor(1920, 1080, ColorInfoFlags(DXVA2_NominalRange_Normal, DXVA2_VideoTransferMatrix_BT601)), L"PC.601");
    EXPECT_EQ(YuvMatrixFor(720, 576, ColorInfoFlags(DXVA2_NominalRange_Unknown, DXVA2_VideoTransferMatrix_BT709)), L"TV.709");
}
