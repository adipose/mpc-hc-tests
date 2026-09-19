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

// GoogleTest, plus the little the player's tests need on top of it:
//
//   TEST(Suite, Name) { EXPECT_TRUE(x); EXPECT_EQ(a, b); ASSERT_NE(p, nullptr); }
//       is plain GoogleTest. CStringW and CStringA print as quoted strings
//       with their code units escaped, so a failing EXPECT_EQ shows exactly
//       which characters differ whatever the console code page.
//
//   TEST_EXPECTED_FAILURE(Suite, Name, "issue, what is wrong") { ... }
//       documents a bug that exists today. The body runs with its failures
//       captured; at least one is the expected outcome and the test passes,
//       carrying the reason as the test property "expected_failure". No
//       failure is an unexpected pass, which fails the test and says to
//       remove the marker, so the marker goes together with the fix.
//
//   TEST_ISOLATED(Suite, Name) { ... }
//   TEST_ISOLATED_EXPECTED_FAILURE(Suite, Name, "...") { ... }
//       run the body in a child process (a GoogleTest death test) with a
//       timeout, for input that may crash, hang, or corrupt the heap: none
//       of those can be survived in-process, and each would otherwise take
//       every other result with it. A body that crashes in-process cannot be
//       an expected failure, because the crash unwinds past the capture;
//       use the isolated form for those.
//
// Inside a test, a structured exception (GoogleTest reports it and, when
// the PDB is there, the frames it happened in are printed after), a C++
// exception, a CRT invalid-parameter report and an AfxMessageBox are each a
// failure of that test rather than the end of the run.
//
// The executable's own options are documented in mpctest::Main.

#pragma once

#include <atlstr.h>
#include <ostream>
#include <string>

#include "gtest/gtest.h"
#include "gtest/gtest-spi.h"

namespace mpctest
{
    // Directory holding the fixture files, with a trailing backslash.
    const CStringW& FixtureDir();
    // A scratch directory private to this process, with a trailing backslash.
    const CStringW& TempDir();

    // Number of message boxes the code under test tried to show in this test.
    // They are swallowed and recorded as failures; a test that provokes one on
    // purpose calls ExpectMessageBox() first.
    int MessageBoxCount();
    void ExpectMessageBox();
    // For the application object: returns the button to "press".
    int OnMessageBox(const wchar_t* prompt);

    std::string ToUtf8(const wchar_t* s, int len = -1);
    // Control characters and non-ASCII escaped, in quotes.
    std::string Quote(const wchar_t* s, int len);
    std::string Quote(const char* s, int len);

    // Parses the options, hands the rest to GoogleTest and runs the tests.
    int Main(int argc, wchar_t** argv);

    // Used by the macros below.
    void RunIsolatedBody(void (*body)());
    void RecordExpectedFailure(const char* reason, const ::testing::TestPartResultArray& captured);
}

namespace ATL
{
    inline void PrintTo(const CStringW& s, std::ostream* os) { *os << mpctest::Quote((LPCWSTR)s, s.GetLength()); }
    inline void PrintTo(const CStringA& s, std::ostream* os) { *os << mpctest::Quote((LPCSTR)s, s.GetLength()); }
}

#define MPCTEST_BODY_(suite, name) MpcTest_##suite##_##name##_Body

#define MPCTEST_CAPTURED_(statement, reason)                                                          \
    ::testing::TestPartResultArray mpctest_captured;                                                  \
    {                                                                                                 \
        ::testing::ScopedFakeTestPartResultReporter mpctest_intercept(                                \
            ::testing::ScopedFakeTestPartResultReporter::INTERCEPT_ONLY_CURRENT_THREAD, &mpctest_captured); \
        statement;                                                                                    \
    }                                                                                                 \
    ::mpctest::RecordExpectedFailure(reason, mpctest_captured)

#define TEST_EXPECTED_FAILURE(suite, name, reason)                                                    \
    static void MPCTEST_BODY_(suite, name)();                                                         \
    TEST(suite, name) { MPCTEST_CAPTURED_(MPCTEST_BODY_(suite, name)(), reason); }                    \
    static void MPCTEST_BODY_(suite, name)()

#define MPCTEST_IN_CHILD_(suite, name) \
    EXPECT_EXIT(::mpctest::RunIsolatedBody(&MPCTEST_BODY_(suite, name)), ::testing::ExitedWithCode(0), "")

#define TEST_ISOLATED(suite, name)                                                                    \
    static void MPCTEST_BODY_(suite, name)();                                                         \
    TEST(suite, name) { MPCTEST_IN_CHILD_(suite, name); }                                             \
    static void MPCTEST_BODY_(suite, name)()

#define TEST_ISOLATED_EXPECTED_FAILURE(suite, name, reason)                                           \
    static void MPCTEST_BODY_(suite, name)();                                                         \
    TEST(suite, name) { MPCTEST_CAPTURED_(MPCTEST_IN_CHILD_(suite, name), reason); }                  \
    static void MPCTEST_BODY_(suite, name)()
