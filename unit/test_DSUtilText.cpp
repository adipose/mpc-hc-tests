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
