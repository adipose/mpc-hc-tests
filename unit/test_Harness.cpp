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

// The framework checking itself: the printing the other files lean on, and
// the two macros this file adds to GoogleTest.

TEST(Harness, StringComparisonsCompareContent)
{
    CStringW w = L"abc";
    CStringA a = "abc";
    EXPECT_EQ(w, L"abc");
    EXPECT_EQ(a, "abc");
    EXPECT_NE(w, L"abd");
    EXPECT_EQ(std::string("x"), "x");
}

TEST(Harness, StringsPrintAsEscapedCodeUnits)
{
    EXPECT_EQ(::testing::PrintToString(CStringW(L"a\tb\x00e9")), "L\"a\\tb\\x00e9\"");
    EXPECT_EQ(::testing::PrintToString(CStringA("a\"b\xff")), "\"a\\\"b\\xff\"");
}

TEST(Harness, FixtureAndTempDirsExist)
{
    EXPECT_TRUE(GetFileAttributesW(mpctest::FixtureDir()) != INVALID_FILE_ATTRIBUTES);
    CStringW p = testutil::WriteTemp(L"harness.bin", std::string("\x01\x02\x03"));
    auto bytes = testutil::ReadAll(p);
    ASSERT_EQ(bytes.size(), (size_t)3);
    EXPECT_EQ(bytes[2], 3);
}

// A failing body is what the marker expects: the test passes and carries
// the reason as a property.
TEST_EXPECTED_FAILURE(Harness, ExpectedFailurePassesWhenTheBodyFails, "the harness's own check that a marked failure is not a failure")
{
    EXPECT_EQ(1, 2);
    ASSERT_TRUE(false) << "and a fatal one after it";
}

// A passing body under the marker is the failure, and says so.
TEST(Harness, ExpectedFailureFailsWhenTheBodyPasses)
{
    EXPECT_NONFATAL_FAILURE({
        MPCTEST_CAPTURED_(EXPECT_EQ(1, 1), "a marker on a test that no longer fails");
    }, "remove the marker");
}

// The isolated body runs in a child process: a crash there is a failure of
// this test, reported with the exit status, and the run carries on.
TEST_ISOLATED(Harness, IsolatedBodyThatPassesPasses)
{
    EXPECT_EQ(2 + 2, 4);
}

TEST(Harness, IsolatedBodyThatFailsFails)
{
    EXPECT_NONFATAL_FAILURE(
        EXPECT_EXIT(::mpctest::RunIsolatedBody([] { EXPECT_EQ(1, 2); }), ::testing::ExitedWithCode(0), ""),
        "Exited with exit status 1");
}

TEST(Harness, IsolatedBodyThatCrashesFails)
{
    EXPECT_NONFATAL_FAILURE(
        EXPECT_EXIT(::mpctest::RunIsolatedBody([] { *(volatile int*)nullptr = 1; }), ::testing::ExitedWithCode(0), ""),
        "structured exception 0xc0000005");
}

TEST_ISOLATED_EXPECTED_FAILURE(Harness, IsolatedExpectedFailureCoversACrash, "the harness's own check that an isolated marked crash is not a failure")
{
    *(volatile int*)nullptr = 1;
}
