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
#include "MpcGtest.h"

#include <crtdbg.h>
#include <DbgHelp.h>
#include <cstdio>
#include <string>
#include <vector>
#pragma comment(lib, "dbghelp.lib")

namespace mpctest
{
    static CStringW g_fixtureDir;
    static CStringW g_tempDir;
    static int g_messageBoxes = 0;
    static bool g_messageBoxExpected = false;
    static DWORD g_timeoutMs = 30000;

    const CStringW& FixtureDir() { return g_fixtureDir; }
    const CStringW& TempDir() { return g_tempDir; }
    int MessageBoxCount() { return g_messageBoxes; }
    void ExpectMessageBox() { g_messageBoxExpected = true; }

    // --- text ---------------------------------------------------------------

    std::string ToUtf8(const wchar_t* s, int len)
    {
        if (!s) {
            return "(null)";
        }
        if (len < 0) {
            len = (int)wcslen(s);
        }
        std::string out;
        if (len > 0) {
            int n = WideCharToMultiByte(CP_UTF8, 0, s, len, nullptr, 0, nullptr, nullptr);
            out.resize(n);
            WideCharToMultiByte(CP_UTF8, 0, s, len, &out[0], n, nullptr, nullptr);
        }
        return out;
    }

    std::string Quote(const wchar_t* s, int len)
    {
        std::string out = "L\"";
        char buf[16];
        for (int i = 0; i < len; i++) {
            wchar_t c = s[i];
            if (c == L'\n') {
                out += "\\n";
            } else if (c == L'\r') {
                out += "\\r";
            } else if (c == L'\t') {
                out += "\\t";
            } else if (c == L'"' || c == L'\\') {
                out += '\\';
                out += (char)c;
            } else if (c >= 0x20 && c < 0x7f) {
                out += (char)c;
            } else {
                sprintf_s(buf, "\\x%04x", (unsigned)c);
                out += buf;
            }
        }
        return out + "\"";
    }

    std::string Quote(const char* s, int len)
    {
        std::string out = "\"";
        char buf[16];
        for (int i = 0; i < len; i++) {
            unsigned char c = (unsigned char)s[i];
            if (c == '"' || c == '\\') {
                out += '\\';
                out += (char)c;
            } else if (c >= 0x20 && c < 0x7f) {
                out += (char)c;
            } else {
                sprintf_s(buf, "\\x%02x", (unsigned)c);
                out += buf;
            }
        }
        return out + "\"";
    }

    // --- things the code under test does that must become failures ---------

    int OnMessageBox(const wchar_t* prompt)
    {
        g_messageBoxes++;
        if (!g_messageBoxExpected) {
            ADD_FAILURE() << "the code under test showed a message box: " << ToUtf8(prompt);
        }
        return IDOK;
    }

    static void InvalidParameterHandler(const wchar_t*, const wchar_t*, const wchar_t*, unsigned int, uintptr_t)
    {
        // The release CRT passes no detail. Without a handler this is a
        // fast-fail that ends the process; with one the CRT function returns
        // its error code and the test carries on, one failure richer.
        ADD_FAILURE() << "CRT invalid parameter (a secure CRT function was given a buffer too small for its input)";
    }

    // Where a structured exception came from, resolved through the PDB when
    // there is one. GoogleTest reports the exception itself; "parser crashed"
    // is a result, "crashed in CVobSubImage::GetNibble" is a lead. Gathered
    // first-chance by a vectored handler, printed only when GoogleTest goes
    // on to record the exception as a failure.
    static std::string g_crashSite;

    static LONG WINAPI OnFirstChanceException(EXCEPTION_POINTERS* ep)
    {
        const DWORD code = ep->ExceptionRecord->ExceptionCode;
        const bool isError = (code & 0xC0000000) == 0xC0000000;
        if (!isError || code == 0xE06D7363 /* C++ throw */ || code == EXCEPTION_STACK_OVERFLOW /* no stack to walk with */) {
            return EXCEPTION_CONTINUE_SEARCH;
        }

        static bool symbolsReady = false;
        HANDLE process = GetCurrentProcess();
        if (!symbolsReady) {
            SymSetOptions(SYMOPT_LOAD_LINES | SYMOPT_UNDNAME | SYMOPT_DEFERRED_LOADS);
            symbolsReady = !!SymInitialize(process, nullptr, TRUE);
        }

        CONTEXT ctx = *ep->ContextRecord;
        STACKFRAME64 frame = {};
        frame.AddrPC.Offset = ctx.Rip;
        frame.AddrFrame.Offset = ctx.Rbp;
        frame.AddrStack.Offset = ctx.Rsp;
        frame.AddrPC.Mode = frame.AddrFrame.Mode = frame.AddrStack.Mode = AddrModeFlat;

        std::string site;
        for (int i = 0; i < 8; i++) {
            if (!StackWalk64(IMAGE_FILE_MACHINE_AMD64, process, GetCurrentThread(), &frame, &ctx, nullptr,
                             SymFunctionTableAccess64, SymGetModuleBase64, nullptr) || !frame.AddrPC.Offset) {
                break;
            }
            char symbolBuffer[sizeof(SYMBOL_INFO) + 512] = {};
            SYMBOL_INFO* symbol = (SYMBOL_INFO*)symbolBuffer;
            symbol->SizeOfStruct = sizeof(SYMBOL_INFO);
            symbol->MaxNameLen = 511;
            DWORD64 displacement = 0;
            char line[768];
            if (symbolsReady && SymFromAddr(process, frame.AddrPC.Offset, &displacement, symbol)) {
                if (strstr(symbol->Name, "testing::internal::HandleSehExceptionsInMethodIfSupported") ||
                        strstr(symbol->Name, "mpctest::RunIsolatedBody")) {
                    break; // the framework itself: nothing of interest below
                }
                IMAGEHLP_LINE64 lineInfo = { sizeof(lineInfo) };
                DWORD lineDisplacement = 0;
                if (SymGetLineFromAddr64(process, frame.AddrPC.Offset, &lineDisplacement, &lineInfo)) {
                    sprintf_s(line, "      at %s (%s:%lu)\n", symbol->Name, lineInfo.FileName, lineInfo.LineNumber);
                } else {
                    sprintf_s(line, "      at %s\n", symbol->Name);
                }
            } else {
                sprintf_s(line, "      at 0x%llx\n", (unsigned long long)frame.AddrPC.Offset);
            }
            site += line;
        }
        g_crashSite = site;
        if (::testing::internal::InDeathTestChild()) {
            // The child dies of this; its stderr is what the parent reports.
            fprintf(stderr, "structured exception 0x%08lx in the isolated body\n%s", code, site.c_str());
            fflush(stderr);
        }
        return EXCEPTION_CONTINUE_SEARCH;
    }

    // A captured failure as one indented block: GoogleTest's summaries span lines.
    static std::string Describe(const ::testing::TestPartResult& r, const char* indent)
    {
        char where[32];
        sprintf_s(where, "(%d): ", r.line_number());
        std::string out = indent + std::string(r.file_name() ? r.file_name() : "") + where;
        for (const char* p = r.summary(); *p; p++) {
            out += *p;
            if (*p == '\n' && p[1]) {
                out += indent;
            }
        }
        return out + '\n';
    }

    // --- per-test bookkeeping and the run summary ---------------------------

    static bool HasProperty(const ::testing::TestResult& r, const char* key)
    {
        for (int i = 0; i < r.test_property_count(); i++) {
            if (!strcmp(r.GetTestProperty(i).key(), key)) {
                return true;
            }
        }
        return false;
    }

    class Listener : public ::testing::EmptyTestEventListener
    {
        int m_expectedFailures = 0;
        int m_unexpectedPasses = 0;

        void OnTestStart(const ::testing::TestInfo&) override
        {
            g_messageBoxes = 0;
            g_messageBoxExpected = false;
            g_crashSite.clear();
        }

        void OnTestPartResult(const ::testing::TestPartResult& result) override
        {
            if (result.failed() && !g_crashSite.empty() && strstr(result.message(), "SEH exception")) {
                printf("%s", g_crashSite.c_str());
                g_crashSite.clear();
            }
        }

        // The same rule Invoke-UnitTests.ps1 applies to the JSON: an expected
        // failure is a marked test that passed because failures were captured,
        // an unexpected pass is a marked test that failed (there were none).
        void OnTestEnd(const ::testing::TestInfo& info) override
        {
            const auto& r = *info.result();
            if (r.Passed() && HasProperty(r, "captured_failures")) {
                m_expectedFailures++;
            } else if (r.Failed() && HasProperty(r, "expected_failure")) {
                m_unexpectedPasses++;
            }
        }

        void OnTestIterationEnd(const ::testing::UnitTest&, int) override
        {
            if (m_expectedFailures || m_unexpectedPasses) {
                printf("%d expected failure(s), %d unexpected pass(es)\n", m_expectedFailures, m_unexpectedPasses);
            }
        }
    };

    void RecordExpectedFailure(const char* reason, const ::testing::TestPartResultArray& captured)
    {
        int failed = 0;
        for (int i = 0; i < captured.size(); i++) {
            if (captured.GetTestPartResult(i).failed()) {
                failed++;
            }
        }
        ::testing::Test::RecordProperty("expected_failure", reason);
        if (failed == 0) {
            ADD_FAILURE() << "marked as an expected failure but passed -- remove the marker:\n    " << reason;
            return;
        }
        ::testing::Test::RecordProperty("captured_failures", failed);
        printf("    expected failure: %s\n", reason);
        for (int i = 0; i < captured.size(); i++) {
            const auto& r = captured.GetTestPartResult(i);
            if (r.failed()) {
                printf("%s", Describe(r, "    ").c_str());
            }
        }
    }

    // --- the child side of an isolated test ---------------------------------

    static DWORD WINAPI Watchdog(LPVOID)
    {
        Sleep(g_timeoutMs);
        fprintf(stderr, "hung: no result after %lu s, isolated body killed\n", g_timeoutMs / 1000);
        fflush(stderr);
        TerminateProcess(GetCurrentProcess(), 3);
        return 0;
    }

    void RunIsolatedBody(void (*body)())
    {
        CloseHandle(CreateThread(nullptr, 0, Watchdog, nullptr, 0, nullptr));

        // Failures are gathered here rather than in the child's own test
        // result, whose fate is to be thrown away with the process: what the
        // parent sees is the exit code and stderr. Per thread, because
        // GoogleTest consults the thread's reporter before the global one, so
        // an enclosing per-thread capture would otherwise take these.
        ::testing::TestPartResultArray captured;
        int failed = 0;
        {
            ::testing::ScopedFakeTestPartResultReporter intercept(
                ::testing::ScopedFakeTestPartResultReporter::INTERCEPT_ONLY_CURRENT_THREAD, &captured);
            body();
        }
        for (int i = 0; i < captured.size(); i++) {
            const auto& r = captured.GetTestPartResult(i);
            if (r.failed()) {
                failed++;
                fprintf(stderr, "%s", Describe(r, "").c_str());
            }
        }
        fflush(stdout);
        fflush(stderr);
        _exit(failed ? 1 : 0);
    }

    // --- directories --------------------------------------------------------

    static CStringW WithBackslash(CStringW dir)
    {
        // "dir\." is how a path ending in a backslash survives command-line quoting
        if (dir.Right(2) == L"\\.") {
            dir.Truncate(dir.GetLength() - 1);
        }
        if (dir.Right(1) != L"\\") {
            dir += L"\\";
        }
        return dir;
    }

    static CStringW FindFixtureDir()
    {
        // The exe lives under <repo>\bin\...; walk up until tests\unit\fixtures appears.
        WCHAR path[MAX_PATH * 4] = {};
        GetModuleFileNameW(nullptr, path, _countof(path));
        CStringW dir(path);
        for (int i = 0; i < 8; i++) {
            int slash = dir.ReverseFind(L'\\');
            if (slash <= 0) {
                break;
            }
            dir.Truncate(slash);
            CStringW candidate = dir + L"\\tests\\unit\\fixtures\\";
            if (GetFileAttributesW(candidate) != INVALID_FILE_ATTRIBUTES) {
                return candidate;
            }
        }
        return L"";
    }

    static void RemoveTree(const CStringW& dir)
    {
        WIN32_FIND_DATAW fd;
        HANDLE h = FindFirstFileW(dir + L"*", &fd);
        if (h != INVALID_HANDLE_VALUE) {
            do {
                if (!wcscmp(fd.cFileName, L".") || !wcscmp(fd.cFileName, L"..")) {
                    continue;
                }
                if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                    RemoveTree(dir + fd.cFileName + L"\\");
                } else {
                    SetFileAttributesW(dir + fd.cFileName, FILE_ATTRIBUTE_NORMAL);
                    DeleteFileW(dir + fd.cFileName);
                }
            } while (FindNextFileW(h, &fd));
            FindClose(h);
        }
        RemoveDirectoryW(dir);
    }

    // --- entry point ----------------------------------------------------------

    int Main(int argc, wchar_t** argv)
    {
        // The result file is wired up inside InitGoogleTest, so --json has to
        // be a --gtest_output before the call. Not in a death-test child: it
        // gets the parent's command line, and the file is the parent's.
        bool inChild = false;
        for (int i = 1; i < argc; i++) {
            inChild = inChild || wcsncmp(argv[i], L"--gtest_internal_run_death_test", 31) == 0;
        }
        std::vector<std::wstring> args;
        for (int i = 0; i < argc; i++) {
            if (!wcscmp(argv[i], L"--json") && i + 1 < argc) {
                if (!inChild) {
                    args.push_back(L"--gtest_output=json:" + std::wstring(argv[i + 1]));
                }
                i++;
            } else {
                args.push_back(argv[i]);
            }
        }
        std::vector<wchar_t*> argp;
        for (auto& a : args) {
            argp.push_back(&a[0]);
        }
        argc = (int)argp.size();
        argv = argp.data();

        // GoogleTest takes its own --gtest_* options out of argv; what is left
        // is ours. A death-test child parses these too.
        ::testing::InitGoogleTest(&argc, argv);

        bool keepTemp = false;
        std::string filter;
        for (int i = 1; i < argc; i++) {
            std::wstring a = argv[i];
            if (a == L"--list") {
                GTEST_FLAG_SET(list_tests, true);
            } else if (a == L"--keep-temp") {
                keepTemp = true;
            } else if (a == L"--fixtures" && i + 1 < argc) {
                g_fixtureDir = WithBackslash(argv[++i]);
            } else if (a == L"--timeout" && i + 1 < argc) {
                g_timeoutMs = (DWORD)_wtoi(argv[++i]) * 1000;
            } else if (a == L"--help" || a == L"-h" || a == L"/?") {
                printf("usage: MpcUnitTests [--list] [--json <file>] [--fixtures <dir>] [--timeout <seconds>] [--keep-temp] [filter ...] [--gtest_*]\n"
                       "  filter     run only tests whose Suite.Name contains the text (case-sensitive); several are OR-ed\n"
                       "  --timeout  limit for a test that runs in a child process (default 30)\n"
                       "  --gtest_*  any GoogleTest option, e.g. --gtest_filter=WebVTT.* or --gtest_output=xml:r.xml (--gtest_help lists them)\n"
                       "exit code: 0 all passed, 1 failures or unexpected passes, 2 usage or setup error\n");
                return 0;
            } else if (a.size() > 1 && a[0] == L'-' && a[1] == L'-') {
                fprintf(stderr, "unknown option %s\n", ToUtf8(a.c_str()).c_str());
                return 2;
            } else if (!inChild) { // the child's filter is the one test it was started for
                filter += (filter.empty() ? "*" : ":*") + ToUtf8(a.c_str()) + "*";
            }
        }
        if (!filter.empty()) {
            GTEST_FLAG_SET(filter, filter);
        }

        if (g_fixtureDir.IsEmpty()) {
            g_fixtureDir = FindFixtureDir();
        }
        if (!GTEST_FLAG_GET(list_tests) && (g_fixtureDir.IsEmpty() || GetFileAttributesW(g_fixtureDir) == INVALID_FILE_ATTRIBUTES)) {
            fprintf(stderr, "fixture directory not found; pass --fixtures <dir>\n");
            return 2;
        }

        // A crash must end a child quietly, not raise a dialog.
        SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
        _set_abort_behavior(0, _WRITE_ABORT_MSG | _CALL_REPORTFAULT);
        _set_invalid_parameter_handler(InvalidParameterHandler);
        _CrtSetReportMode(_CRT_ASSERT, _CRTDBG_MODE_FILE);
        _CrtSetReportFile(_CRT_ASSERT, _CRTDBG_FILE_STDERR);
        AddVectoredExceptionHandler(1, OnFirstChanceException);

        // The scratch directory is the parent's, handed down through the
        // environment: a child exits from inside its test and would never
        // get to clean one of its own up.
        WCHAR inherited[MAX_PATH * 2] = {};
        if (inChild && GetEnvironmentVariableW(L"MPCTEST_TEMP", inherited, _countof(inherited))) {
            g_tempDir = inherited;
        } else {
            WCHAR tmp[MAX_PATH] = {};
            GetTempPathW(_countof(tmp), tmp);
            g_tempDir.Format(L"%sMpcUnitTests-%lu\\", tmp, GetCurrentProcessId());
            CreateDirectoryW(g_tempDir, nullptr);
            SetEnvironmentVariableW(L"MPCTEST_TEMP", g_tempDir);
        }

        auto& listeners = ::testing::UnitTest::GetInstance()->listeners();
        if (inChild) {
            // The child's job is to run one body and exit; the parent reports
            // it. Let a crash in the body reach the top rather than be caught
            // as a failure, so the exit code says what happened.
            delete listeners.Release(listeners.default_result_printer());
            GTEST_FLAG_SET(catch_exceptions, false);
        }
        listeners.Append(new Listener);

        int rc = RUN_ALL_TESTS();

        if (!keepTemp && !inChild) {
            RemoveTree(g_tempDir);
        }
        if (!GTEST_FLAG_GET(list_tests) && ::testing::UnitTest::GetInstance()->test_to_run_count() == 0) {
            fprintf(stderr, "no test matched\n");
            return 2;
        }
        return rc;
    }
}
