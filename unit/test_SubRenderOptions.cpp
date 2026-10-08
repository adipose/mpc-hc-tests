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
#include <dvdmedia.h>
#include <dxva2api.h>
#include "../../src/SubPic/SubPicAllocatorPresenterImpl.h"

// The "yuvMatrix" the internal renderers report through ISubRenderOptions.
// The main frame hands it to the text and bitmap subtitle renderers, which
// pick the colour conversion from it. When the decoder gives no transfer
// matrix it is guessed from the frame size: SD is BT.601, anything larger
// BT.709. The guess used to test the width twice, so 720x576 PAL and 720x480
// NTSC came out as 709.

namespace
{
    // The presenter base with its two pure members filled in. It needs a
    // window only for its rectangle; the desktop will do.
    class TestPresenter : public CSubPicAllocatorPresenterImpl
    {
    public:
        explicit TestPresenter(HRESULT& hr)
            : CSubPicAllocatorPresenterImpl(GetDesktopWindow(), hr, nullptr) {}
        STDMETHODIMP CreateRenderer(IUnknown** ppRenderer) override { return E_NOTIMPL; }
        STDMETHODIMP_(bool) Paint(bool bAll) override { return false; }
    };

    // biHeight is negative for a top-down frame. withColorInfo sets the
    // DXVA2 extended format flags with the given matrix and range; without
    // it the flags carry nothing and the whole string is a guess.
    std::wstring YuvMatrix(LONG width, LONG height, bool withColorInfo = false,
                           UINT matrix = DXVA2_VideoTransferMatrix_Unknown,
                           UINT range = DXVA2_NominalRange_16_235)
    {
        CMediaType mt;
        mt.majortype = MEDIATYPE_Video;
        mt.subtype = MEDIASUBTYPE_NV12;
        mt.formattype = FORMAT_VideoInfo2;
        auto vih2 = (VIDEOINFOHEADER2*)mt.AllocFormatBuffer(sizeof(VIDEOINFOHEADER2));
        ZeroMemory(vih2, sizeof(VIDEOINFOHEADER2));
        vih2->bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        vih2->bmiHeader.biWidth = width;
        vih2->bmiHeader.biHeight = height;
        if (withColorInfo) {
            DXVA2_ExtendedFormat& flags = (DXVA2_ExtendedFormat&)vih2->dwControlFlags;
            flags.VideoTransferMatrix = matrix;
            flags.NominalRange = range;
            vih2->dwControlFlags |= AMCONTROL_USED | AMCONTROL_COLORINFO_PRESENT;
        }

        HRESULT hr = E_FAIL;
        TestPresenter presenter(hr);
        EXPECT_EQ(S_OK, hr);
        presenter.SetVideoMediaType(mt);

        LPWSTR value = nullptr;
        int chars = 0;
        EXPECT_EQ(S_OK, presenter.GetString("yuvMatrix", &value, &chars));
        std::wstring ret = value ? value : L"";
        LocalFree(value);
        return ret;
    }
}

TEST(SubRenderOptions, YuvMatrixGuessedFromSizeWithoutColorInfo)
{
    EXPECT_EQ(L"TV.601", YuvMatrix(720, 576));      // PAL
    EXPECT_EQ(L"TV.601", YuvMatrix(720, 480));      // NTSC
    EXPECT_EQ(L"TV.601", YuvMatrix(720, -576));     // top-down
    EXPECT_EQ(L"TV.601", YuvMatrix(1024, 576));     // anamorphic PAL widened
    EXPECT_EQ(L"TV.601", YuvMatrix(352, 288));      // CIF
    EXPECT_EQ(L"TV.709", YuvMatrix(1280, 720));
    EXPECT_EQ(L"TV.709", YuvMatrix(1920, 1080));
    EXPECT_EQ(L"TV.709", YuvMatrix(1920, -1080));
    EXPECT_EQ(L"TV.709", YuvMatrix(480, 720));      // portrait, taller than SD
}

TEST(SubRenderOptions, YuvMatrixGuessedFromSizeWhenMatrixUnknown)
{
    EXPECT_EQ(L"TV.601", YuvMatrix(720, 576, true));
    EXPECT_EQ(L"PC.601", YuvMatrix(720, 480, true, DXVA2_VideoTransferMatrix_Unknown, DXVA2_NominalRange_0_255));
    EXPECT_EQ(L"TV.709", YuvMatrix(1920, 1080, true));
}

TEST(SubRenderOptions, YuvMatrixFromColorInfoIgnoresSize)
{
    EXPECT_EQ(L"TV.709", YuvMatrix(720, 576, true, DXVA2_VideoTransferMatrix_BT709));
    EXPECT_EQ(L"TV.601", YuvMatrix(1920, 1080, true, DXVA2_VideoTransferMatrix_BT601));
    EXPECT_EQ(L"PC.2020", YuvMatrix(3840, 2160, true, 4, DXVA2_NominalRange_0_255));
}
