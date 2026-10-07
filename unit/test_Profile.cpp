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
#include "../../src/mpc-hc/Profile.h"

// CProfile, the settings store (src/mpc-hc/Profile.cpp, compiled into this
// project: it lives in the exe project, and everything it needs to link -
// GetModulePath, the StrTo* parsers, StartsWithNoCase - is already in
// DSUtil.lib). Only the explicit-INI-path constructor is exercised here, with
// files in the run's scratch directory: the registry is never touched.

using namespace testutil;

// #3979 (228ac386ab): every value type must survive a write, a flush and a
// fresh reader on the same ini.
TEST(Profile, RoundTripThroughASecondInstance)
{
    const CStringW path = mpctest::TempDir() + L"profile-roundtrip.ini";
    const BYTE blob[] = { 0x00, 0xFF, 0x01 }; // the 0x00 matters: it is "AA" in the A-P encoding

    {
        CProfile p(path);
        EXPECT_TRUE(p.WriteInt(L"Numbers", L"Negative", -12345));
        EXPECT_TRUE(p.WriteUInt(L"Numbers", L"Big", 4000000000u));
        EXPECT_TRUE(p.WriteInt64(L"Numbers", L"Big64", -9000000000ll));
        EXPECT_TRUE(p.WriteDouble(L"Numbers", L"Real", 2.5));
        EXPECT_TRUE(p.WriteString(L"Strings", L"Empty", L""));
        EXPECT_TRUE(p.WriteString(L"Strings", L"Padded", L"  leading = and = equals"));
        EXPECT_TRUE(p.WriteBinary(L"Strings", L"Blob", blob, (unsigned)sizeof(blob)));
        p.Flush(false);
    }

    CProfile q(path);

    int i = 0;
    EXPECT_TRUE(q.ReadInt(L"Numbers", L"Negative", i));
    EXPECT_EQ(i, -12345);

    unsigned u = 0;
    EXPECT_TRUE(q.ReadUInt(L"Numbers", L"Big", u));
    EXPECT_EQ(u, 4000000000u);

    __int64 i64 = 0;
    EXPECT_TRUE(q.ReadInt64(L"Numbers", L"Big64", i64));
    EXPECT_EQ(i64, -9000000000ll);

    double d = 0.0;
    EXPECT_TRUE(q.ReadDouble(L"Numbers", L"Real", d));
    EXPECT_DOUBLE_EQ(d, 2.5);

    CStringW s;
    EXPECT_TRUE(q.ReadString(L"Strings", L"Empty", s));
    EXPECT_EQ(s, L"");
    // The ini parser does not trim and splits on the first '=' only.
    EXPECT_TRUE(q.ReadString(L"Strings", L"Padded", s));
    EXPECT_EQ(s, L"  leading = and = equals");

    BYTE* data = nullptr;
    unsigned nbytes = 0;
    ASSERT_TRUE(q.ReadBinary(L"Strings", L"Blob", &data, nbytes));
    std::unique_ptr<BYTE[]> guard(data);
    ASSERT_EQ(nbytes, (unsigned)sizeof(blob));
    EXPECT_EQ(memcmp(data, blob, nbytes), 0);

    // #3979: binary values are written in the legacy A-P encoding, byte
    // compatible with stock MPC-HC inis (two chars 'A'..'P' per byte,
    // low nibble first: 0x00 0xFF 0x01 -> "AAPPBA").
    const auto bytes = ReadAll(path);
    const std::string text(bytes.begin(), bytes.end());
    EXPECT_NE(text.find("Blob=AAPPBA"), std::string::npos);
}

// #3979: values written by the old CMPlayerCApp::WriteProfileBinary (the A-P
// encoding) are still read. Write such an ini by hand and read it back.
TEST(Profile, ReadsLegacyApEncodedBinary)
{
    const CStringW path = WriteTemp(L"profile-legacy.ini",
        std::string("[Misc]\r\nBlob=AAPPBA\r\n"));

    CProfile p(path);
    BYTE* data = nullptr;
    unsigned nbytes = 0;
    ASSERT_TRUE(p.ReadBinary(L"Misc", L"Blob", &data, nbytes));
    std::unique_ptr<BYTE[]> guard(data);
    ASSERT_EQ(nbytes, 3u);
    EXPECT_EQ(data[0], 0x00);
    EXPECT_EQ(data[1], 0xFF);
    EXPECT_EQ(data[2], 0x01);
}

// #3979: EnumSectionNames lists the immediate children that were written, and
// DeleteSection removes one section (and nothing else), durably.
TEST(Profile, SectionEnumerationAndDeleteSurviveAFlush)
{
    const CStringW path = mpctest::TempDir() + L"profile-sections.ini";

    {
        CProfile p(path);
        p.WriteString(L"Main", L"RootKey", L"root");
        p.WriteString(L"Main\\Sub1", L"k", L"1");
        p.WriteString(L"Main\\Sub2", L"k", L"2");
        p.WriteString(L"Main\\Sub2\\Deep", L"k", L"3");
        p.WriteString(L"Other", L"k", L"4");
        p.Flush(false);
    }

    CProfile p(path);

    std::vector<CStringW> roots;
    p.EnumRootSectionNames(roots);
    ASSERT_EQ(roots.size(), (size_t)2);
    EXPECT_EQ(roots[0], L"Main");
    EXPECT_EQ(roots[1], L"Other");

    // Immediate children only: "Main\Sub2\Deep" is not listed under "Main".
    std::vector<CStringW> subs;
    p.EnumSectionNames(L"Main", subs);
    ASSERT_EQ(subs.size(), (size_t)2);
    EXPECT_EQ(subs[0], L"Sub1");
    EXPECT_EQ(subs[1], L"Sub2");

    EXPECT_TRUE(p.DeleteSection(L"Main\\Sub1"));
    p.EnumSectionNames(L"Main", subs);
    ASSERT_EQ(subs.size(), (size_t)1);
    EXPECT_EQ(subs[0], L"Sub2");
    EXPECT_FALSE(p.HasEntry(L"Main\\Sub1", L"k"));
    EXPECT_TRUE(p.HasEntry(L"Main", L"RootKey"));
    EXPECT_TRUE(p.HasEntry(L"Main\\Sub2", L"k"));
    EXPECT_TRUE(p.HasEntry(L"Main\\Sub2\\Deep", L"k"));
    EXPECT_TRUE(p.HasEntry(L"Other", L"k"));

    p.Flush(false);

    CProfile q(path);
    q.EnumSectionNames(L"Main", subs);
    ASSERT_EQ(subs.size(), (size_t)1);
    EXPECT_EQ(subs[0], L"Sub2");
    EXPECT_FALSE(q.HasEntry(L"Main\\Sub1", L"k"));
    CStringW s;
    EXPECT_TRUE(q.ReadString(L"Main\\Sub2\\Deep", L"k", s));
    EXPECT_EQ(s, L"3");
    EXPECT_TRUE(q.ReadString(L"Other", L"k", s));
    EXPECT_EQ(s, L"4");
}

// #4000 (cf59651f37): ReadSectionTree iterates the whole map instead of
// walking subsections level by level, because an intermediate section with no
// values of its own has no map entry and would hide everything below it.
TEST(Profile, SectionTreeCopiesSectionsUnderAValuelessParent)
{
    const CStringW srcPath = mpctest::TempDir() + L"profile-tree-src.ini";
    const CStringW dstPath = mpctest::TempDir() + L"profile-tree-dst.ini";

    CProfile src(srcPath);
    src.WriteInt(L"Internal Filters", L"Enabled", 1);
    src.WriteString(L"Internal Filters\\LAV Video", L"Decoder", L"D3D11");
    src.WriteInt(L"Internal Filters\\LAV Video\\Hardware", L"CUVID", 0);
    // "Internal Filters\Audio" never gets a value of its own, so it has no
    // map entry; only the leaf below it exists.
    src.WriteInt(L"Internal Filters\\Audio\\Bitstream", L"AC3", 1);
    // A sibling whose name merely shares a prefix must not be copied.
    src.WriteString(L"Internal Filters2", L"X", L"y");
    src.Flush(false);

    ProfileMap tree;
    src.ReadSectionTree(L"Internal Filters", tree);
    ASSERT_EQ(tree.size(), (size_t)4);
    EXPECT_TRUE(tree.count(L"Internal Filters"));
    EXPECT_TRUE(tree.count(L"Internal Filters\\LAV Video"));
    EXPECT_TRUE(tree.count(L"Internal Filters\\LAV Video\\Hardware"));
    // The leaf under the valueless intermediate must arrive.
    EXPECT_TRUE(tree.count(L"Internal Filters\\Audio\\Bitstream"));
    EXPECT_FALSE(tree.count(L"Internal Filters2"));

    {
        CProfile dst(dstPath);
        dst.WriteSectionTree(tree);
        dst.Flush(false);
    }

    CProfile r(dstPath);
    int iv = -1;
    CStringW sv;
    EXPECT_TRUE(r.ReadInt(L"Internal Filters", L"Enabled", iv));
    EXPECT_EQ(iv, 1);
    EXPECT_TRUE(r.ReadString(L"Internal Filters\\LAV Video", L"Decoder", sv));
    EXPECT_EQ(sv, L"D3D11");
    EXPECT_TRUE(r.ReadInt(L"Internal Filters\\LAV Video\\Hardware", L"CUVID", iv));
    EXPECT_EQ(iv, 0);
    EXPECT_TRUE(r.ReadInt(L"Internal Filters\\Audio\\Bitstream", L"AC3", iv));
    EXPECT_EQ(iv, 1);
    EXPECT_FALSE(r.HasEntry(L"Internal Filters2", L"X"));
}

// #4193 (959b6478dd; issue #4182): an ini that could not be read was replaced
// by an empty one on exit. A failed first read marks the store read-failed,
// and Flush refuses to overwrite a file it never read for the whole session.
TEST(Profile, AFailedFirstReadNeverOverwritesTheFile)
{
    const std::string original =
        "[Player]\r\nVolume=75\r\n"
        "[Internal Filters]\r\nEnabled=1\r\n"
        "[Internal Filters\\LAV Video]\r\nDecoder=D3D11\r\n";
    const CStringW path = WriteTemp(L"profile-locked.ini", original);

    {
        // Hold the ini with an exclusive share, the way an AV scanner or sync
        // client does. The reader retries a sharing violation (20 x 100 ms in
        // OpenIniWithRetry) before giving up; keeping the handle for the whole
        // construction and read is what makes the read fail, no thread needed.
        HANDLE hold = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        ASSERT_NE(hold, INVALID_HANDLE_VALUE);

        CProfile p(path);
        int volume = -1;
        EXPECT_FALSE(p.ReadInt(L"Player", L"Volume", volume)); // blocked by the lock
        CloseHandle(hold);

        // The lock is gone, but this session never saw the settings: it runs on
        // defaults and must never write them back, not even on a forced flush.
        EXPECT_TRUE(p.WriteInt(L"Player", L"Volume", 42));
        p.Flush(false);
        p.Flush(true);
    }

    // p is destroyed, and ~CProfile did not write either. The file must be
    // byte for byte what the test wrote.
    const auto bytes = ReadAll(path);
    ASSERT_EQ(bytes.size(), original.size());
    EXPECT_EQ(std::string(bytes.begin(), bytes.end()), original);

    // And the untouched file still reads in a new session.
    CProfile q(path);
    int v2 = 0;
    EXPECT_TRUE(q.ReadInt(L"Player", L"Volume", v2));
    EXPECT_EQ(v2, 75);
}
