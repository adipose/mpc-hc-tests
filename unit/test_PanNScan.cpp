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
#include "../../src/mpc-hc/PanNScan.h"

// PanNScan (src/mpc-hc/PanNScan.cpp, compiled into this project) parses the
// pan and scan presets for both the View > Pan&Scan menu and the presets
// dialog. Ledger S2: the menu handler reset the view and then assigned each
// field as it parsed, so a preset with the wrong field count, such as the
// ",0.500,0.500,1.000,1.000" the dialog writes for an empty label, changed
// the stored pan and zoom without moving the video. The next unrelated
// MoveVideoWindow (a window resize) then jumped the picture. The parser now
// fails without touching its outputs, and the handler changes nothing then.

namespace
{
    const double k4p3 = 4.0 / 3.0;
    const double k16p9 = 16.0 / 9.0;
    const double k235p1 = 2.35;
    const double kTol = 0.001; // presets are stored at %.3f, and the old parser read floats

    // The five defaults as CAppSettings::LoadSettings builds them, with the
    // labels its string table supplies.
    CString Default(LPCTSTR label, double x, double y, double zx, double zy)
    {
        CString fmt;
        fmt.Format(_T("%s,%%.3f,%%.3f,%%.3f,%%.3f"), label);
        CString str;
        str.Format(fmt, x, y, zx, zy);
        return str;
    }

    void ExpectValues(const PanNScan::Values& v, double x, double y, double zx, double zy)
    {
        EXPECT_NEAR(v.posX, x, kTol);
        EXPECT_NEAR(v.posY, y, kTol);
        EXPECT_NEAR(v.zoomX, zx, kTol);
        EXPECT_NEAR(v.zoomY, zy, kTol);
    }

    // A sentinel the parser must leave alone when it fails.
    PanNScan::Values Sentinel()
    {
        PanNScan::Values v;
        v.posX = 0.25;
        v.posY = 0.75;
        v.zoomX = 2.5;
        v.zoomY = 3.5;
        return v;
    }

    void ExpectRejected(LPCTSTR str)
    {
        CString label = _T("untouched");
        PanNScan::Values v = Sentinel();
        EXPECT_FALSE(PanNScan::ParsePreset(str, label, v)) << CStringA(str).GetString();
        EXPECT_EQ(label, CString(_T("untouched"))) << CStringA(str).GetString();
        ExpectValues(v, 0.25, 0.75, 2.5, 3.5);
    }
}

TEST(PanNScan, DefaultPresetsParse)
{
    struct {
        CString str;
        LPCTSTR label;
        double x, y, zx, zy;
    } cases[] = {
        { Default(_T("Scale to 16:9 TV"), 0.5, 0.5, 1.0, k16p9 / k4p3), _T("Scale to 16:9 TV"), 0.5, 0.5, 1.0, k16p9 / k4p3 },
        { Default(_T("Zoom to Widescreen"), 0.5, 0.5, k16p9 / k4p3, k16p9 / k4p3), _T("Zoom to Widescreen"), 0.5, 0.5, k16p9 / k4p3, k16p9 / k4p3 },
        { Default(_T("Zoom to Ultra-Widescreen"), 0.5, 0.5, k235p1 / k4p3, k235p1 / k4p3), _T("Zoom to Ultra-Widescreen"), 0.5, 0.5, k235p1 / k4p3, k235p1 / k4p3 },
        { _T("3D SBS > 2D,1.0,0.5,2.0,1.0"), _T("3D SBS > 2D"), 1.0, 0.5, 2.0, 1.0 },
        { _T("3D TB  > 2D,0.5,1.0,1.0,2.0"), _T("3D TB  > 2D"), 0.5, 1.0, 1.0, 2.0 },
    };

    for (const auto& c : cases) {
        CString label;
        PanNScan::Values v = Sentinel();
        ASSERT_TRUE(PanNScan::ParsePreset(c.str, label, v)) << CStringA(c.str).GetString();
        EXPECT_EQ(label, CString(c.label));
        ExpectValues(v, c.x, c.y, c.zx, c.zy);
    }
}

TEST(PanNScan, FormatThenParseRoundTrips)
{
    PanNScan::Values in;
    in.posX = -0.25;
    in.posY = 1.375;
    in.zoomX = 0.2;
    in.zoomY = 4.999;

    CString str = PanNScan::FormatPreset(_T("Mine"), in);
    EXPECT_EQ(str, CString(_T("Mine,-0.250,1.375,0.200,4.999")));

    CString label;
    PanNScan::Values out;
    ASSERT_TRUE(PanNScan::ParsePreset(str, label, out));
    EXPECT_EQ(label, CString(_T("Mine")));
    ExpectValues(out, in.posX, in.posY, in.zoomX, in.zoomY);

    // and once more through the formatter gives the same string
    EXPECT_EQ(PanNScan::FormatPreset(label, out), str);
}

TEST(PanNScan, EmptyLabelIsRejected)
{
    // What CPnSPresetsDlg::ParamsToString writes for an empty label. The old
    // tokenizer skipped the empty first field, counted four and returned
    // after resetting and half-assigning the view.
    ExpectRejected(_T(",0.500,0.500,1.000,1.000"));
}

TEST(PanNScan, WrongFieldCountIsRejected)
{
    ExpectRejected(_T("Four,0.4,0.6,1.5"));
    ExpectRejected(_T("Six,0.4,0.6,1.5,1.5,1.0"));
    ExpectRejected(_T("LabelOnly"));
    ExpectRejected(_T(""));
}

TEST(PanNScan, NonNumericFieldIsRejected)
{
    ExpectRejected(_T("Bad,0.4,abc,1.5,1.5"));
    ExpectRejected(_T("Bad,0.4,0.6x,1.5,1.5"));
    ExpectRejected(_T("Bad,0.4, ,1.5,1.5"));
}

TEST(PanNScan, RawValuesParseWithoutLabel)
{
    // the /pns "x,y,zx,zy" form ApplyPanNScanPresetString accepts
    PanNScan::Values v = Sentinel();
    ASSERT_TRUE(PanNScan::ParseValues(_T("0.4,0.6,1.5,2"), v));
    ExpectValues(v, 0.4, 0.6, 1.5, 2.0);

    v = Sentinel();
    EXPECT_FALSE(PanNScan::ParseValues(_T("0.4,0.6,1.5"), v));
    EXPECT_FALSE(PanNScan::ParseValues(_T("0.4,0.6,oops,2"), v));
    ExpectValues(v, 0.25, 0.75, 2.5, 3.5);
}

TEST(PanNScan, ClampAtAndBeyondBounds)
{
    PanNScan::Values v;
    v.posX = -0.5;
    v.posY = 1.5;
    v.zoomX = 0.2;
    v.zoomY = 5.0;
    PanNScan::Clamp(v);
    ExpectValues(v, -0.5, 1.5, 0.2, 5.0);

    v.posX = -0.501;
    v.posY = 1.501;
    v.zoomX = 0.199;
    v.zoomY = 5.001;
    PanNScan::Clamp(v);
    EXPECT_EQ(v.posX, -0.5);
    EXPECT_EQ(v.posY, 1.5);
    EXPECT_EQ(v.zoomX, 0.2);
    EXPECT_EQ(v.zoomY, 5.0);

    v.posX = 100;
    v.posY = -100;
    v.zoomX = 0;
    v.zoomY = -1;
    PanNScan::Clamp(v);
    EXPECT_EQ(v.posX, 1.5);
    EXPECT_EQ(v.posY, -0.5);
    EXPECT_EQ(v.zoomX, 0.2);
    EXPECT_EQ(v.zoomY, 0.2);
}
