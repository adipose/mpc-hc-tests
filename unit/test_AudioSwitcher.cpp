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
#include <objbase.h>
#include "../../src/filters/switcher/AudioSwitcher/AudioSwitcher.h"

// CStreamSwitcherFilter::Enable (ledger 150, patch797) paused the graph before
// looking the stream index up and returned E_INVALIDARG without resuming it, so
// a running file stayed paused. The switcher needs no connected pins to reach
// that return: a graph holding only the filter runs, and has no stream to match.

namespace
{
    class ScopedCom
    {
    public:
        ScopedCom() : m_hr(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {}
        ~ScopedCom() {
            if (SUCCEEDED(m_hr)) {
                CoUninitialize();
            }
        }
    private:
        HRESULT m_hr;
    };
}

TEST(AudioSwitcher, EnableBadIndexLeavesGraphRunning)
{
    ScopedCom com;

    CComPtr<IGraphBuilder> pGB;
    ASSERT_HRESULT_SUCCEEDED(pGB.CoCreateInstance(CLSID_FilterGraph));

    HRESULT hr = S_OK;
    CComPtr<IBaseFilter> pBF = new CAudioSwitcherFilter(nullptr, &hr);
    ASSERT_HRESULT_SUCCEEDED(hr);
    ASSERT_HRESULT_SUCCEEDED(pGB->AddFilter(pBF, L"switcher"));

    CComQIPtr<IAMStreamSelect> pSS = pBF;
    CComQIPtr<IMediaControl> pMC = pGB;
    ASSERT_TRUE(pSS && pMC);

    ASSERT_HRESULT_SUCCEEDED(pMC->Run());
    OAFilterState fs = -1;
    ASSERT_HRESULT_SUCCEEDED(pMC->GetState(1000, &fs));
    ASSERT_EQ(fs, State_Running);

    EXPECT_EQ(pSS->Enable(999, AMSTREAMSELECTENABLE_ENABLE), E_INVALIDARG);

    fs = -1;
    EXPECT_HRESULT_SUCCEEDED(pMC->GetState(1000, &fs));
    EXPECT_EQ(fs, State_Running);

    pMC->Stop();
    pGB->RemoveFilter(pBF);
}
