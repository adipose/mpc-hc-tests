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
#include "../../src/Subtitles/TextFile.h"

// A guard on the resource script rather than on compiled code: with
// DS_SETFONT also set, DS_FIXEDSYS changes how the dialog manager sizes a
// dialog (#3674, #3913). PR #3717 (707cd273aa) removed it from every dialog
// in mpc-hc.rc, but the .rc is edited constantly, often by the resource
// editor, which can put it back. Set MPC_TEST_RC_PATH to check a single .rc
// file instead of the working tree's -- used to prove the test against the
// pre-fix resource without touching the source.

using namespace testutil;

namespace
{
    struct BadDialog
    {
        CStringW id;
        CStringW file;
        int line;
    };

    bool IsIdent(wchar_t c)
    {
        return iswalnum(c) || c == L'_';
    }

    // Whole-word search: DS_FIXEDSYS must not match inside another identifier.
    bool HasToken(const CStringW& text, LPCWSTR token)
    {
        const int len = (int)wcslen(token);
        int pos = 0;
        for (;;) {
            pos = text.Find(token, pos);
            if (pos < 0) {
                return false;
            }
            const bool leftOk = pos == 0 || !IsIdent(text[pos - 1]);
            const bool rightOk = pos + len >= text.GetLength() || !IsIdent(text[pos + len]);
            if (leftOk && rightOk) {
                return true;
            }
            pos += len;
        }
    }

    CStringW StripComment(const CStringW& line)
    {
        const int p = line.Find(L"//");
        return p < 0 ? line : line.Left(p);
    }

    // Next whitespace-delimited token starting at pos; pos ends past it.
    CStringW NextToken(const CStringW& line, int& pos)
    {
        while (pos < line.GetLength() && iswspace(line[pos])) {
            pos++;
        }
        const int start = pos;
        while (pos < line.GetLength() && !iswspace(line[pos])) {
            pos++;
        }
        return line.Mid(start, pos - start);
    }

    bool IsIdentifier(const CStringW& s)
    {
        if (s.IsEmpty()) {
            return false;
        }
        for (int i = 0; i < s.GetLength(); i++) {
            if (!IsIdent(s[i])) {
                return false;
            }
        }
        return true;
    }

    // Returns the number of dialog resources seen; those whose STYLE combines
    // DS_FIXEDSYS with DS_SETFONT are appended to bad.
    int ScanRcFile(const CStringW& path, std::vector<BadDialog>& bad)
    {
        CTextFile f; // BOM detection covers the UTF-16 .rc in the tree and a UTF-8 MPC_TEST_RC_PATH copy alike
        if (!f.Open(path)) {
            ADD_FAILURE() << "cannot open " << mpctest::ToUtf8(path);
            return 0;
        }
        std::vector<CStringW> lines;
        CStringW line;
        while (f.ReadString(line)) {
            lines.push_back(StripComment(line));
        }

        int dialogs = 0;
        for (size_t i = 0; i < lines.size(); i++) {
            int pos = 0;
            const CStringW id = NextToken(lines[i], pos);
            const CStringW keyword = NextToken(lines[i], pos);
            if (!IsIdentifier(id) || (keyword != L"DIALOG" && keyword != L"DIALOGEX")) {
                continue;
            }
            dialogs++;

            // The STYLE statement sits between the header and BEGIN, and may
            // continue on the next line after a trailing '|'.
            CStringW style;
            for (size_t j = i + 1; j < lines.size(); j++) {
                const CStringW trimmed = CStringW(lines[j]).Trim();
                if (trimmed == L"BEGIN") {
                    break;
                }
                int tpos = 0;
                if (NextToken(trimmed, tpos) != L"STYLE") {
                    continue;
                }
                style = trimmed.Mid(tpos).Trim();
                while (style.Right(1) == L"|" && j + 1 < lines.size()) {
                    style += L" " + CStringW(lines[++j]).Trim();
                }
                break;
            }
            if (HasToken(style, L"DS_FIXEDSYS") && HasToken(style, L"DS_SETFONT")) {
                bad.push_back({ id, path, (int)i + 1 });
            }
        }
        return dialogs;
    }

    // The exe lives in <repo>\bin\tests_x64; walk up until src\mpc-hc appears.
    CStringW FindSourceDir()
    {
        WCHAR path[MAX_PATH * 4] = {};
        GetModuleFileNameW(nullptr, path, _countof(path));
        CStringW dir(path);
        for (int i = 0; i < 8; i++) {
            int slash = dir.ReverseFind(L'\\');
            if (slash <= 0) {
                break;
            }
            dir.Truncate(slash);
            CStringW candidate = dir + L"\\src\\mpc-hc";
            if (GetFileAttributesW(candidate + L"\\mpc-hc.rc") != INVALID_FILE_ATTRIBUTES) {
                return candidate;
            }
        }
        return L"";
    }

    // Every .rc under src\mpc-hc except mpcresources\, whose per-language
    // files are gitignored build output.
    void CollectRcFiles(const CStringW& dir, std::vector<CStringW>& out)
    {
        WIN32_FIND_DATAW fd;
        HANDLE h = FindFirstFileW(dir + L"\\*", &fd);
        if (h == INVALID_HANDLE_VALUE) {
            return;
        }
        do {
            if (!wcscmp(fd.cFileName, L".") || !wcscmp(fd.cFileName, L"..")) {
                continue;
            }
            const CStringW path = dir + L"\\" + fd.cFileName;
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                if (wcscmp(fd.cFileName, L"mpcresources")) {
                    CollectRcFiles(path, out);
                }
            } else if (wcsstr(fd.cFileName, L".rc") == fd.cFileName + wcslen(fd.cFileName) - 3) {
                out.push_back(path);
            }
        } while (FindNextFileW(h, &fd));
        FindClose(h);
    }
}

TEST(Resources, NoDialogCombinesFixedSysWithSetFont)
{
    std::vector<CStringW> files;
    WCHAR envPath[MAX_PATH * 4] = {};
    if (GetEnvironmentVariableW(L"MPC_TEST_RC_PATH", envPath, _countof(envPath))) {
        files.push_back(envPath);
    } else {
        const CStringW srcDir = FindSourceDir();
        ASSERT_FALSE(srcDir.IsEmpty()) << "src\\mpc-hc not found above the test executable";
        CollectRcFiles(srcDir, files);
        ASSERT_FALSE(files.empty());
    }

    std::vector<BadDialog> bad;
    int dialogs = 0;
    for (const CStringW& file : files) {
        dialogs += ScanRcFile(file, bad);
    }

    // A parse that finds nothing must not pass.
    EXPECT_GE(dialogs, 50) << "only " << dialogs << " dialog resource(s) seen in " << files.size() << " .rc file(s)";

    std::string list;
    for (const BadDialog& d : bad) {
        list += "    " + mpctest::ToUtf8(d.id) + " (" + mpctest::ToUtf8(d.file) + ":" + std::to_string(d.line) + ")\n";
    }
    EXPECT_TRUE(bad.empty()) << "DS_FIXEDSYS with DS_SETFONT changes dialog sizing (#3674, #3913); removed by #3717. "
                                "Drop DS_FIXEDSYS from:\n" << list;
}
