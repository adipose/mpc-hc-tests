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
#include "../../src/mpc-hc/CrashEventLog.h"

// The event ring that goes into DrDump reports (src/mpc-hc/CrashEventLog.h,
// header-only).

namespace
{
    const wchar_t* TestName(uint16_t code)
    {
        return code == 0 ? L"A" : L"B";
    }
}

TEST(CrashEventLog, GlobalIsZeroInitializedWithTag)
{
    static CrashEventLog log = { "MPC-HC events" };
    EXPECT_STREQ(log.tag, "MPC-HC events");
    EXPECT_EQ(0u, log.total);
    EXPECT_EQ(L"", log.Format(TestName));
}

TEST(CrashEventLog, FormatsOldestFirstWithNonzeroArgs)
{
    CrashEventLog log = {};
    log.Push(1234, 0, 0);
    log.Push(65001, 1, -1);
    log.Push(70000, 1, 0);
    EXPECT_EQ(L"1.234 A; 65.001 B(-1); 70.000 B", log.Format(TestName));
}

TEST(CrashEventLog, WrapsKeepingTheNewest)
{
    CrashEventLog log = {};
    const int n = int(CrashEventLog::Capacity) + 10;
    for (int i = 0; i < n; i++) {
        log.Push(0, 1, i + 1);
    }
    const std::wstring s = log.Format(TestName);
    EXPECT_EQ(0u, s.find(L"0.000 B(11); "));
    EXPECT_EQ(s.size() - 11, s.rfind(L"0.000 B(74)"));
    EXPECT_EQ(std::wstring::npos, s.find(L"B(10)"));
}
