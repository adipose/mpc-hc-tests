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
#include "HostHooks.h"
#include "mpc-hc/VersionInfo.h"
#include "filters/renderer/VideoRenderers/RenderersSettings.h"

// What the static libraries expect their host executable to provide. In the
// player these live in src/mpc-hc; here they return what a test set up.
// Nothing in this file stands in for code under test.

SubRendererSettings& testutil::HostSubRendererSettings()
{
    static SubRendererSettings settings;
    return settings;
}

// Subtitles.lib: declared extern in SubRendererSettings.h, defined by the
// player in AppSettings.cpp. Read once by every CSimpleTextSubtitle constructor.
SubRendererSettings GetSubRendererSettings()
{
    return testutil::HostSubRendererSettings();
}

// SubPic.lib: GetString("version") on CSubPicAllocatorPresenterImpl answers
// with this; the player defines it in VersionInfo.cpp. The matrix guess under
// test never calls it.
namespace VersionInfo
{
    CString GetVersionString() { return CString(L"1.0.0.0-test"); }
}

// SubPic.lib: CSubPicAllocatorPresenterImpl reads the renderer settings in
// SetVideoSize and AlphaBltSubPic; the player defines this in AppSettings.cpp.
// The matrix guess under test never calls it.
CRenderersSettings& GetRenderersSettings()
{
    static CRenderersSettings settings;
    return settings;
}

// CRenderersSettings' constructor calls this; the player defines it in the
// renderer project's RenderersSettings.cpp, not linked here. The tests never
// read the settings, so the defaults it would set are immaterial.
void CRenderersSettings::CAdvRendererSettings::SetDefault()
{
}
