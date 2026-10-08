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
#include "../../src/DSUtil/ISOLang.h"
#include "../../src/DSUtil/PathUtils.h"
#include "../../src/DSUtil/text.h"
#include "moreuuids.h"

// Pure helpers in src/DSUtil: language-code mapping (ISOLang.cpp), path and
// filename handling (PathUtils.cpp) and the text helpers (text.cpp, DSUtil.cpp).
// Modelled on #632/#927/#3321/#3452 (language tags), #2612/#2525 (paths) and
// #334/#591/#1376 (URL and UTF-8 decoding).

using namespace testutil;

// --- ISOLang ----------------------------------------------------------------

TEST(ISOLang, TwoAndThreeLetterCodes)
{
    EXPECT_EQ(ISOLang::ISO6391ToLanguage("en"), L"English");
    EXPECT_EQ(ISOLang::ISO6392ToLanguage("eng"), L"English");
    EXPECT_EQ(ISOLang::ISO6391ToLanguage("fr"), L"French");
    EXPECT_EQ(ISOLang::ISO6392ToLanguage("deu"), L"German"); // ISO 639-2/T
    EXPECT_EQ(ISOLang::ISO6392ToLanguage("ger"), L"German"); // ISO 639-2/B
    EXPECT_EQ(ISOLang::ISO6391ToLcid("en"), MAKELCID(MAKELANGID(LANG_ENGLISH, SUBLANG_DEFAULT), SORT_DEFAULT));
    EXPECT_EQ(ISOLang::ISO6392ToLcid("fre"), MAKELCID(MAKELANGID(LANG_FRENCH, SUBLANG_DEFAULT), SORT_DEFAULT));
}

TEST(ISOLang, UnknownCode)
{
    EXPECT_EQ(ISOLang::ISO6391ToLanguage("xx"), L"");
    // ISO6392ToLanguage echoes the input when it has no entry
    EXPECT_EQ(ISOLang::ISO6392ToLanguage("xyz"), L"xyz");
    EXPECT_EQ(ISOLang::ISO6391ToLcid("xx"), (LCID)0);
    EXPECT_EQ(ISOLang::ISO6392ToLcid("xyz"), (LCID)0);
}

// #632: a truncated BCP-47 code (639-1 with a region, e.g. "en-US") should
// fall back to the 639-1 lookup rather than fail.
TEST(ISOLang, TruncatedBcp47FallsBackTo6391)
{
    EXPECT_EQ(ISOLang::ISO6392ToLcid("en-"), MAKELCID(MAKELANGID(LANG_ENGLISH, SUBLANG_DEFAULT), SORT_DEFAULT));
    EXPECT_EQ(ISOLang::ISO639XToLanguage("en-"), L"English");
    EXPECT_EQ(ISOLang::ISO639XToLanguage("fr"), L"French");
    EXPECT_EQ(ISOLang::ISO639XToLanguage("eng"), L"English");
}

// #927: the Traditional/Simplified region tags
TEST(ISOLang, ChineseRegionTags)
{
    EXPECT_EQ(ISOLang::ISO639XToLanguage("zh-CN"), L"Chinese (Simplified)");
    EXPECT_EQ(ISOLang::ISO639XToLanguage("zh-TW"), L"Chinese (Traditional)");
    EXPECT_EQ(ISOLang::ISO639XToLanguage("pt-BR"), L"Portuguese (Brazil)");
    EXPECT_EQ(ISOLang::ISO639XToLanguage("pt-PT"), L"Portuguese");
}

// #3452: bare "zh" is just "Chinese", not "Chinese (Simplified)"
TEST(ISOLang, BareChineseIsNotSimplified)
{
    EXPECT_EQ(ISOLang::ISO6391ToLanguage("zh"), L"Chinese");
    EXPECT_EQ(ISOLang::ISO6392ToLanguage("chi"), L"Chinese");
    EXPECT_EQ(ISOLang::ISO6392ToLanguage("zho"), L"Chinese");
}

// #3321: "srp" is Serbian, not Croatian
TEST(ISOLang, SerbianAndCroatianAreDistinct)
{
    EXPECT_EQ(ISOLang::ISO6392ToLanguage("srp"), L"Serbian");
    EXPECT_EQ(ISOLang::ISO6392ToLanguage("scc"), L"Serbian");
    EXPECT_EQ(ISOLang::ISO6392ToLanguage("hrv"), L"Croatian");
    EXPECT_NE(ISOLang::ISO6392ToLcid("srp"), ISOLang::ISO6392ToLcid("hrv"));
    EXPECT_EQ(PRIMARYLANGID(LANGIDFROMLCID(ISOLang::ISO6392ToLcid("srp"))), (WORD)LANG_SERBIAN);
}

TEST(ISOLang, RoundTripThrough6391And6392)
{
    EXPECT_EQ(ISOLang::ISO6391To6392("en"), "eng");
    EXPECT_EQ(ISOLang::ISO6392To6391("eng"), L"en");
    EXPECT_TRUE(ISOLang::IsISO6391("en"));
    EXPECT_TRUE(ISOLang::IsISO6392("eng"));
    EXPECT_FALSE(ISOLang::IsISO6392("en"));
}

// #4225 (e7f72cb70f): the table's first entry with an empty 639-1 column is
// "Achinese", so an empty code matched it instead of finding nothing.
TEST(ISOLang, EmptyCodeMatchesNothing)
{
    EXPECT_EQ(ISOLang::ISO6391ToLanguage(""), L"");
    EXPECT_EQ(ISOLang::ISO6391ToLcid(""), (LCID)0);
    EXPECT_FALSE(ISOLang::IsISO6391(""));
    EXPECT_EQ(ISOLang::ISO6391To6392(""), "");
    EXPECT_EQ(ISOLang::ISO6391ToISOLang("").name, nullptr);

    // a real code still resolves, one lookup past the empty one
    EXPECT_EQ(ISOLang::ISO6391ToLanguage("en"), L"English");
    EXPECT_TRUE(ISOLang::IsISO6391("en"));
}

// --- PathUtils --------------------------------------------------------------

TEST(PathUtils, NameAndExtension)
{
    // BaseName keeps the extension, FileName drops it
    EXPECT_EQ(PathUtils::BaseName(L"C:\\movies\\clip.mkv"), L"clip.mkv");
    EXPECT_EQ(PathUtils::FileName(L"C:\\movies\\clip.mkv"), L"clip");
    EXPECT_EQ(PathUtils::FileExt(L"C:\\movies\\clip.mkv"), L".mkv");
    EXPECT_EQ(PathUtils::DirName(L"C:\\movies\\clip.mkv"), L"C:\\movies");
}

// #2612: control characters are not valid in a filename either
TEST(PathUtils, FilterInvalidChars)
{
    EXPECT_EQ(PathUtils::FilterInvalidCharsFromFileName(L"a<b>c:d\"e/f\\g|h?i*j"), L"a_b_c_d_e_f_g_h_i_j");
    EXPECT_EQ(PathUtils::FilterInvalidCharsFromFileName(L"tab\tnewline\r\nhere"), L"tab_newline__here");
    EXPECT_EQ(PathUtils::FilterInvalidCharsFromFileName(L"perfectly.valid_name"), L"perfectly.valid_name");
    EXPECT_EQ(PathUtils::FilterInvalidCharsFromFileName(L"x/y", L'-'), L"x-y");
}

// #2525: a trailing backslash must not become a double one when combined
TEST(PathUtils, CombineWithTrailingBackslash)
{
    EXPECT_EQ(PathUtils::CombinePaths(L"\\\\NAS\\share\\", L"BDMV\\index.bdmv"), L"\\\\NAS\\share\\BDMV\\index.bdmv");
    EXPECT_EQ(PathUtils::CombinePaths(L"C:\\dir", L"file.txt"), L"C:\\dir\\file.txt");
    EXPECT_EQ(PathUtils::CombinePaths(L"C:\\dir\\", L"file.txt"), L"C:\\dir\\file.txt");
}

TEST(PathUtils, UrlAndFullPathClassification)
{
    CString http = L"http://example.com/a.mkv";
    CString unc = L"\\\\server\\share\\a.mkv";
    CString drive = L"C:\\a.mkv";
    CString rel = L"sub\\a.mkv";
    CString fileUrl = L"file://server/a.mkv";
    EXPECT_TRUE(PathUtils::IsURL(http));
    EXPECT_FALSE(PathUtils::IsURL(drive));
    EXPECT_FALSE(PathUtils::IsURL(fileUrl)); // file: is a local path, not a remote URL
    EXPECT_TRUE(PathUtils::IsFullFilePath(drive));
    EXPECT_TRUE(PathUtils::IsFullFilePath(unc));
    EXPECT_FALSE(PathUtils::IsFullFilePath(rel));
    EXPECT_FALSE(PathUtils::IsFullFilePath(http));
}

// #1717, #3766, #3992: long paths get the \\?\ prefix, URLs do not
TEST(PathUtils, ExtendMaxPathLength)
{
    CString shortPath = L"C:\\short\\path.mkv";
    ExtendMaxPathLengthIfNeeded(shortPath);
    EXPECT_EQ(shortPath, L"C:\\short\\path.mkv");

    CString longPath = L"C:\\";
    longPath.Append(CString('a', 300));
    longPath += L"\\file.mkv";
    ExtendMaxPathLengthIfNeeded(longPath);
    EXPECT_EQ(longPath.Left(4), L"\\\\?\\");

    CString longUnc = L"\\\\server\\share\\";
    longUnc.Append(CString('b', 300));
    ExtendMaxPathLengthIfNeeded(longUnc);
    EXPECT_EQ(longUnc.Left(8), L"\\\\?\\UNC\\");

    CString url = L"http://example.com/";
    url.Append(CString('c', 300));
    ExtendMaxPathLengthIfNeeded(url);
    EXPECT_EQ(url.Left(4), L"http");
}

TEST(PathUtils, StripPathOrUrl)
{
    EXPECT_EQ(PathUtils::StripPathOrUrl(L"C:\\movies\\clip.mkv"), L"clip.mkv");
    EXPECT_EQ(PathUtils::StripPathOrUrl(L"http://example.com/path/clip%20one.mkv"), L"clip one.mkv");
}

// #4041 (17b48e2f94): external subtitle/audio lookup for a multi-volume rar
// needs both suffixes off, not just the last extension.
TEST(PathUtils, StripExtensionAndRarVolumeSuffix)
{
    EXPECT_EQ(PathUtils::StripExtensionAndRarVolumeSuffix(L"base.mkv"), L"base");
    EXPECT_EQ(PathUtils::StripExtensionAndRarVolumeSuffix(L"base.part01.rar"), L"base");
    EXPECT_EQ(PathUtils::StripExtensionAndRarVolumeSuffix(L"BASE.PART12.RAR"), L"BASE");
    EXPECT_EQ(PathUtils::StripExtensionAndRarVolumeSuffix(L"base.r00"), L"base");
    EXPECT_EQ(PathUtils::StripExtensionAndRarVolumeSuffix(L"no extension"), L"no extension");
    // a dot in a directory name is not an extension
    EXPECT_EQ(PathUtils::StripExtensionAndRarVolumeSuffix(L"C:\\dir.with.dot\\file"), L"C:\\dir.with.dot\\file");
    EXPECT_EQ(PathUtils::StripExtensionAndRarVolumeSuffix(L"C:\\dir.with.dot\\file.mkv"), L"C:\\dir.with.dot\\file");
}

// --- CLongPath (PR #4236) -----------------------------------------------------
//
// CPath builds its results in a MAX_PATH buffer, so past MAX_PATH Combine and
// Canonicalize leave an empty path, AddBackslash does nothing and Append,
// AddExtension and RenameExtension return FALSE -- silently for the void ones.
// CLongPath runs the CPath method whenever the result fits and only then its
// own. The tests below pair each operation with the CPath result for short
// inputs (they must agree exactly) and with the full expected string for long
// ones (each of those assertions fails if CLongPath is replaced by CPath).

TEST(LongPath, ShortPathsMatchCPath)
{
    // Combine
    for (auto* dir : { L"C:\\dir", L"C:\\dir\\", L"\\\\NAS\\share" }) {
        CLongPath lp;
        lp.Combine(dir, L"sub\\file.txt");
        CPath cp;
        cp.Combine(dir, L"sub\\file.txt");
        EXPECT_EQ(CString(lp), CString(cp));
    }
    {
        CLongPath lp;
        lp.Combine(L"C:\\dir", L"D:\\abs.txt");
        EXPECT_EQ(CString(lp), L"D:\\abs.txt"); // an absolute file wins
        lp.Combine(L"C:\\dir", L"\\rooted.txt");
        EXPECT_EQ(CString(lp), L"C:\\rooted.txt"); // rooted goes on the drive
    }

    // AddBackslash / Append
    {
        CLongPath lp(L"C:\\dir");
        CPath cp(L"C:\\dir");
        lp.AddBackslash();
        cp.AddBackslash();
        EXPECT_EQ(CString(lp), CString(cp));
        EXPECT_TRUE(lp.Append(L"more.txt"));
        EXPECT_TRUE(cp.Append(L"more.txt"));
        EXPECT_EQ(CString(lp), CString(cp));
        EXPECT_EQ(CString(lp), L"C:\\dir\\more.txt");
    }

    // AddExtension / RenameExtension
    {
        CLongPath lp(L"C:\\dir\\file");
        CPath cp(L"C:\\dir\\file");
        EXPECT_EQ(lp.AddExtension(L".txt"), cp.AddExtension(L".txt"));
        EXPECT_EQ(CString(lp), CString(cp));
        EXPECT_EQ(CString(lp), L"C:\\dir\\file.txt");
        EXPECT_EQ(lp.RenameExtension(L".mkv"), cp.RenameExtension(L".mkv"));
        EXPECT_EQ(CString(lp), L"C:\\dir\\file.mkv");
    }

    // Canonicalize: "." and ".." resolved, never above the root
    {
        CLongPath lp(L"C:\\a\\.\\b\\..\\c");
        CPath cp(L"C:\\a\\.\\b\\..\\c");
        lp.Canonicalize();
        cp.Canonicalize();
        EXPECT_EQ(CString(lp), CString(cp));
        EXPECT_EQ(CString(lp), L"C:\\a\\c");
    }
    {
        CLongPath lp(L"C:\\..\\..\\x");
        CPath cp(L"C:\\..\\..\\x");
        lp.Canonicalize();
        cp.Canonicalize();
        EXPECT_EQ(CString(lp), CString(cp));
        EXPECT_EQ(CString(lp), L"C:\\x");
    }
}

TEST(LongPath, CombinePastMaxPath)
{
    const CString dir = CString(L"C:\\") + CString(L'd', 300);
    CLongPath lp;
    lp.Combine(dir, L"file.txt");
    // CPath::Combine leaves m_strPath empty here
    EXPECT_EQ(CString(lp), dir + L"\\file.txt");

    CLongPath abs;
    abs.Combine(dir, CString(L"D:\\") + CString(L'e', 300) + L".txt");
    EXPECT_EQ(CString(abs), CString(L"D:\\") + CString(L'e', 300) + L".txt");
}

TEST(LongPath, AppendPastMaxPath)
{
    const CString dir = CString(L"C:\\") + CString(L'd', 300);
    CLongPath lp(dir);
    // CPath::Append returns FALSE and leaves the path short
    EXPECT_TRUE(lp.Append(L"more.txt"));
    EXPECT_EQ(CString(lp), dir + L"\\more.txt");

    // operator+= goes through the same code
    CLongPath lp2(dir);
    lp2 += L"more.txt";
    EXPECT_EQ(CString(lp2), dir + L"\\more.txt");
}

TEST(LongPath, AddBackslashPastMaxPath)
{
    const CString dir = CString(L"C:\\") + CString(L'd', 300);
    CLongPath lp(dir);
    lp.AddBackslash(); // a no-op in CPath past MAX_PATH
    EXPECT_EQ(CString(lp), dir + L"\\");
}

TEST(LongPath, AddAndRenameExtensionPastMaxPath)
{
    const CString dir = CString(L"C:\\") + CString(L'd', 300);
    CLongPath lp(dir);
    // CPath::AddExtension returns FALSE here
    EXPECT_TRUE(lp.AddExtension(L".srt"));
    EXPECT_EQ(CString(lp), dir + L".srt");

    CLongPath rp(dir + L".old");
    EXPECT_TRUE(rp.RenameExtension(L".new"));
    EXPECT_EQ(CString(rp), dir + L".new");
}

TEST(LongPath, CanonicalizePastMaxPath)
{
    const CString dir = CString(L"C:\\") + CString(L'd', 300);
    CLongPath lp(dir + L"\\sub\\..\\file.txt");
    lp.Canonicalize(); // CPath::Canonicalize leaves the path empty here
    EXPECT_EQ(CString(lp), dir + L"\\file.txt");
}

// ".." must never climb above the root: not above a drive, not out of a
// share, not past the long-path prefix. Long inputs so CLongPath's own
// canonicalization, not the CPath fallback, is what runs.
TEST(LongPath, DotDotNeverClimbsAboveTheRoot)
{
    const CString name(L'n', 300);
    {
        CLongPath lp(CString(L"C:\\..\\..\\") + name);
        lp.Canonicalize();
        EXPECT_EQ(CString(lp), CString(L"C:\\") + name);
    }
    {
        CLongPath lp(CString(L"\\\\server\\share\\..\\..\\") + name);
        lp.Canonicalize();
        EXPECT_EQ(CString(lp), CString(L"\\\\server\\share\\") + name);
    }
    {
        CLongPath lp(CString(L"\\\\server\\share\\a\\..\\..\\") + name);
        lp.Canonicalize();
        EXPECT_EQ(CString(lp), CString(L"\\\\server\\share\\") + name);
    }
    {
        CLongPath lp(CString(L"\\\\?\\C:\\..\\") + name);
        lp.Canonicalize();
        EXPECT_EQ(CString(lp), CString(L"\\\\?\\C:\\") + name);
    }
    {
        // a relative path climbing above where it starts cannot be resolved,
        // so it comes back empty rather than guessed
        CLongPath lp(CString(L"..\\") + name);
        lp.Canonicalize();
        EXPECT_TRUE(CString(lp).IsEmpty());
    }
}

// --- text.cpp / DSUtil.cpp --------------------------------------------------

TEST(Text, UrlEncodeDecodeRoundTrip)
{
    CStringA plain = "a b&c=d/e?f";
    CStringA encoded = UrlEncode(plain);
    EXPECT_TRUE(encoded.Find(' ') < 0);
    EXPECT_EQ(UrlDecode(encoded), plain);
    EXPECT_EQ(UrlDecode("%20%26%3D"), " &=");
}

// #591: '+' means space, and the result is decoded as UTF-8
TEST(Text, UrlDecodeWithUtf8)
{
    EXPECT_EQ(UrlDecodeWithUTF8(L"one+two"), L"one two");
    EXPECT_EQ(UrlDecodeWithUTF8(L"caf%C3%A9"), L"caf\x00e9");
    EXPECT_EQ(UrlDecodeWithUTF8(L"%E6%97%A5%E6%9C%AC"), L"\x65e5\x672c");
}

TEST(Text, UrlGetHostName)
{
    EXPECT_EQ(URLGetHostName(L"https://www.example.com/path/to/x"), L"example.com");
    EXPECT_EQ(URLGetHostName(L"http://host.local:8080/a"), L"host.local:8080");
}

// #334, #1376: UTF-8 to UTF-16, including sequences beyond the BMP
TEST(Text, Utf8To16)
{
    EXPECT_EQ(UTF8To16("plain ascii"), L"plain ascii");
    EXPECT_EQ(UTF8To16("caf\xC3\xA9"), L"caf\x00e9");
    EXPECT_EQ(UTF8To16("\xE6\x97\xA5\xE6\x9C\xAC\xE8\xAA\x9E"), L"\x65e5\x672c\x8a9e");
    EXPECT_EQ(UTF8To16("emoji \xF0\x9F\x98\x80"), L"emoji \xd83d\xde00");
    EXPECT_EQ(UTF8To16(""), L"");
}

TEST(Text, HtmlSpecialCharsDecode)
{
    EXPECT_EQ(HtmlSpecialCharsDecode("Tom &amp; Jerry &lt;3 &gt; 2 &quot;q&quot;"), "Tom & Jerry <3 > 2 \"q\"");
}

TEST(Text, StartsEndsWith)
{
    EXPECT_TRUE(StartsWith(L"hello world", L"hello"));
    EXPECT_FALSE(StartsWith(L"hello", L"world"));
    EXPECT_TRUE(EndsWith(L"clip.mkv", L".mkv"));
    EXPECT_TRUE(EndsWithNoCase(L"CLIP.MKV", L".mkv"));
    EXPECT_FALSE(EndsWith(L"CLIP.MKV", L".mkv"));
}

// 0ecbf5bea8 (#3796): trims up to two leading BOMs from the first line of a
// subtitle; CTextFile already removes one duplicate, so one or two is what a
// parser can still see.
TEST(Text, TrimLeadingUTF16BOM)
{
    CStringW s;

    s = L"\xFEFF\xFEFF" L"text";
    TrimLeadingUTF16BOM(s);
    EXPECT_EQ(s, L"text");

    s = L"\xFEFF" L"text";
    TrimLeadingUTF16BOM(s);
    EXPECT_EQ(s, L"text");

    // the byteswapped BOM counts too, and the two can mix
    s = L"\xFFEF\xFEFF" L"text";
    TrimLeadingUTF16BOM(s);
    EXPECT_EQ(s, L"text");

    // two at most
    s = L"\xFEFF\xFEFF\xFEFF" L"text";
    TrimLeadingUTF16BOM(s);
    EXPECT_EQ(s, L"\xFEFF" L"text");

    // only leading ones
    s = L"a\xFEFF" L"b";
    TrimLeadingUTF16BOM(s);
    EXPECT_EQ(s, L"a\xFEFF" L"b");

    // a lone BOM is left alone
    s = L"\xFEFF";
    TrimLeadingUTF16BOM(s);
    EXPECT_EQ(s, L"\xFEFF");
}

TEST(Text, ExplodeRespectsLimitAndTrims)
{
    CAtlList<CString> parts;
    Explode(CString(L" a , b , c "), parts, L',');
    ASSERT_EQ(parts.GetCount(), (size_t)3);
    EXPECT_EQ(parts.GetHead(), L"a");
    EXPECT_EQ(parts.GetTail(), L"c");

    CAtlList<CString> limited;
    Explode(CString(L"a=b=c"), limited, L'=', 2);
    ASSERT_EQ(limited.GetCount(), (size_t)2);
    EXPECT_EQ(limited.GetHead(), L"a");
    EXPECT_EQ(limited.GetTail(), L"b=c"); // the rest is left intact
}

// #4130: menu labels made from untrusted names
TEST(Text, SanitizeMenuLabel)
{
    EXPECT_EQ(SanitizeMenuLabel(L"Fish & Chips"), L"Fish && Chips");
    EXPECT_EQ(SanitizeMenuLabel(L"tab\tseparated"), L"tab separated");
    EXPECT_EQ(SanitizeMenuLabel(L"  spaced  "), L"spaced");
    EXPECT_EQ(SanitizeMenuLabel(L""), L" "); // never empty: an item needs something to measure

    CStringW longName(L'x', 400);
    CStringW label = SanitizeMenuLabel(longName);
    EXPECT_TRUE(label.GetLength() <= MENU_NAME_MAX);
    EXPECT_EQ(label.Right(1), L"\x2026"); // truncated with a horizontal-ellipsis character
}

// #4039 (1717e6cd75): the recent-files list hides the file entry when its
// title says the same thing, but a title with characters that are illegal in
// file names never matched the sanitized name a downloader saved it as.
// youtube-dl turns '/' into '_', deletes '?', expands ':' to " -" and turns
// '"' into '\''.
TEST(Text, NameSimilarWhenSanitizedByDownloader)
{
    EXPECT_TRUE(IsNameSimilar(L"AC/DC Live At Donington", L"AC_DC Live At Donington.mkv"));
    EXPECT_TRUE(IsNameSimilar(L"Who Framed Roger Rabbit?", L"Who Framed Roger Rabbit.mkv"));
    EXPECT_TRUE(IsNameSimilar(L"Movie Title: The Sequel?", L"Movie Title - The Sequel.mkv"));
    EXPECT_TRUE(IsNameSimilar(L"The \"Best\" Of 1999 Rock", L"The 'Best' Of 1999 Rock.mkv"));
    // and the "ReleaseGroup | FileName" title shape contains the file name
    EXPECT_TRUE(IsNameSimilar(L"SomeGroup | A Movie About Trains", L"A Movie About Trains.mkv"));
}

TEST(Text, NameSimilarRejectsShortOrUnrelatedTitles)
{
    // a handful of stripped characters must not be enough
    EXPECT_FALSE(IsNameSimilar(L"Hi?", L"Hi.mkv"));
    EXPECT_FALSE(IsNameSimilar(L"Short: Film?", L"Short - Film.mkv")); // stripped to 9 chars
    EXPECT_FALSE(IsNameSimilar(L"Documentary Part 1?", L"Another Film 2.mkv"));
    // ...but the same name with the illegal character dropped must be
    EXPECT_TRUE(IsNameSimilar(L"Documentary Part 1?", L"Documentary Part 1.mkv"));
}

// 16ccbeeb1c: AC4 was only recognised under one of its two GUID spellings,
// ALAC not at all, and a printable FourCC subtype came out as a hex dump
// ("74786574" instead of "text").
TEST(MediaTypeNames, ShortAudioNames)
{
    AM_MEDIA_TYPE mt = {};
    mt.majortype = MEDIATYPE_Audio;

    mt.subtype = MEDIASUBTYPE_DOLBY_AC4;
    EXPECT_EQ(GetShortAudioNameFromMediaType(&mt), L"AC4");
    // the lower-case spelling of the same codec id
    mt.subtype = MEDIASUBTYPE_DOLBY_AC4_lc;
    EXPECT_EQ(GetShortAudioNameFromMediaType(&mt), L"AC4");
    mt.subtype = MEDIASUBTYPE_ALAC;
    EXPECT_EQ(GetShortAudioNameFromMediaType(&mt), L"ALAC");
}

TEST(MediaTypeNames, FourCCSubtypeNames)
{
    AM_MEDIA_TYPE mt = {};
    mt.majortype = MEDIATYPE_Audio;
    // a FourCC is stored little-endian in Data1: 'text'
    mt.subtype = { 0x74786574, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };
    EXPECT_EQ(GetShortAudioNameFromMediaType(&mt), L"text");
    // a non-printable one still comes out as hex (b is 0x02, so all four bytes)
    mt.subtype = { 0x00020001, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };
    EXPECT_EQ(GetShortAudioNameFromMediaType(&mt), L"00020001");
}
