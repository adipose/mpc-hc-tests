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
#include "../../src/DSUtil/HdmvClipInfo.h"

// Blu-ray disc structure: the .mpls playlists and .clpi clip information the
// player reads to pick the main movie, list its streams and place chapters.
// The fixtures are built here byte by byte, in the layout the parser walks,
// and written as a small BDMV tree under the run's scratch directory.

namespace
{
    using testutil::Bytes;

    constexpr DWORD kTicksPerSecond = 45000;          // mpls timestamps
    constexpr REFERENCE_TIME kSecond = 10000000i64;   // REFERENCE_TIME

    Bytes FirstBytes(const Bytes& b, size_t n)
    {
        Bytes out;
        out.insert(out.end(), b.begin(), b.begin() + n);
        return out;
    }

    // --- STN table (the streams a PlayItem carries) ---------------------------

    Bytes StnStream(WORD pid, BYTE codingType, const Bytes& attributes)
    {
        Bytes entry;
        entry.u8(1).u16(pid);                      // stream_entry: type 1 = PID of the main clip
        Bytes attrs;
        attrs.u8(codingType).add(attributes);      // stream_attributes
        Bytes s;
        s.u8((BYTE)entry.size()).add(entry).u8((BYTE)attrs.size()).add(attrs);
        return s;
    }

    Bytes VideoAttrs(BDVM_VideoFormat format, BDVM_FrameRate rate) { return Bytes().u8((BYTE)(format << 4 | rate)); }
    Bytes AudioAttrs(BDVM_ChannelLayout layout, BDVM_SampleRate rate, const char* lang) { return Bytes().u8((BYTE)(layout << 4 | rate)).str(lang); }
    Bytes PgAttrs(const char* lang) { return Bytes().str(lang); }

    Bytes StnTable(const std::vector<Bytes>& video, const std::vector<Bytes>& audio, const std::vector<Bytes>& pg)
    {
        Bytes body;
        body.u16(0)                                 // reserved
            .u8((BYTE)video.size()).u8((BYTE)audio.size()).u8((BYTE)pg.size())
            .u8(0).u8(0).u8(0).u8(0)                // ig, secondary audio, secondary video, pip pg
            .fill(5);                               // reserved
        for (const auto& s : video) { body.add(s); }
        for (const auto& s : audio) { body.add(s); }
        for (const auto& s : pg)    { body.add(s); }
        Bytes t;
        t.u16((WORD)body.size()).add(body);
        return t;
    }

    Bytes Hd1080Stn(WORD videoPid = 0x1011)
    {
        return StnTable({ StnStream(videoPid, VIDEO_STREAM_H264, VideoAttrs(BDVM_VideoFormat_1080p, BDVM_FrameRate_23_976)) },
                        { StnStream(0x1100, AUDIO_STREAM_AC3, AudioAttrs(BDVM_ChannelLayout_MULTI, BDVM_SampleRate_48, "eng")) },
                        { StnStream(0x1200, PRESENTATION_GRAPHICS_STREAM, PgAttrs("fra")) });
    }

    Bytes Sd480Stn(WORD videoPid = 0x1012)
    {
        return StnTable({ StnStream(videoPid, VIDEO_STREAM_MPEG2, VideoAttrs(BDVM_VideoFormat_480i, BDVM_FrameRate_29_97)) },
                        { StnStream(0x1100, AUDIO_STREAM_AC3, AudioAttrs(BDVM_ChannelLayout_STEREO, BDVM_SampleRate_48, "eng")) },
                        {});
    }

    // --- PlayItem, PlayListMark, and the .mpls file around them ----------------

    Bytes PlayItem(const char* clip, DWORD inSeconds, DWORD outSeconds, const Bytes& stn, const char* magic = "M2TS")
    {
        Bytes body;
        body.str(clip).str(magic)                   // Clip_Information_file_name, Clip_codec_identifier
            .u8(0).u8(0)                            // reserved(11) is_multi_angle(1) connection_condition(4)
            .u8(0)                                  // ref_to_STC_id
            .u32(inSeconds * kTicksPerSecond).u32(outSeconds * kTicksPerSecond)
            .fill(8)                                // UO_mask_table
            .u8(0).u8(0).u16(0)                     // random access flag, still_mode, still_time
            .add(stn);
        Bytes item;
        item.u16((WORD)body.size()).add(body);
        return item;
    }

    Bytes Mark(CHdmvClipInfo::PlaylistMarkType type, WORD playItem, DWORD seconds, WORD entryPid = 0x1011, DWORD durationSeconds = 0)
    {
        return Bytes().u8(0).u8((BYTE)type).u16(playItem).u32(seconds * kTicksPerSecond).u16(entryPid).u32(durationSeconds * kTicksPerSecond);
    }

    Bytes Mpls(const std::vector<Bytes>& items, const std::vector<Bytes>& marks = {})
    {
        Bytes playlist;
        playlist.u16(0).u16((WORD)items.size()).u16(0); // reserved, number_of_PlayItems, number_of_SubPaths
        for (const auto& i : items) { playlist.add(i); }
        Bytes markTable;
        markTable.u16((WORD)marks.size());
        for (const auto& m : marks) { markTable.add(m); }

        const DWORD playlistStart = 40;
        const DWORD markStart = playlistStart + 4 + (DWORD)playlist.size();
        Bytes f;
        f.str("MPLS").str("0200")
         .u32(playlistStart).u32(markStart).u32(0)   // PlayList, PlayListMark, ExtensionData start addresses
         .fill(playlistStart - 20)                    // AppInfoPlayList, not read
         .u32((DWORD)playlist.size()).add(playlist)
         .u32((DWORD)markTable.size()).add(markTable);
        return f;
    }

    // --- .clpi ------------------------------------------------------------------

    Bytes ClpiStream(WORD pid, BYTE codingType, const Bytes& attributes)
    {
        Bytes info;
        info.u8(codingType).add(attributes);
        Bytes s;
        s.u16(pid).u8((BYTE)info.size()).add(info);
        return s;
    }

    Bytes Clpi(const std::vector<Bytes>& streams)
    {
        Bytes programInfo;
        programInfo.u8(0).u8(1)                     // reserved, number_of_program_sequences
                   .u32(0).u16(0x0100)              // SPN_program_sequence_start, program_map_PID
                   .u8((BYTE)streams.size()).u8(0); // number_of_streams_in_ps, reserved
        for (const auto& s : streams) { programInfo.add(s); }

        const DWORD programInfoStart = 40;
        Bytes f;
        f.str("HDMV").str("0200")
         .u32(0).u32(programInfoStart)              // SequenceInfo (not read), ProgramInfo start addresses
         .fill(programInfoStart - 16)
         .u32((DWORD)programInfo.size()).add(programInfo);
        return f;
    }

    // --- a disc under the scratch directory ------------------------------------

    void EnsureDir(const CStringW& dir)
    {
        int from = 3; // past "C:\"
        for (;;) {
            int slash = dir.Find(L'\\', from);
            CreateDirectoryW(slash < 0 ? dir : dir.Left(slash), nullptr);
            if (slash < 0) {
                break;
            }
            from = slash + 1;
        }
    }

    // Returns the disc root (no trailing backslash). Files are given as
    // "PLAYLIST\\00000.mpls" style paths under BDMV.
    CStringW MakeDisc(LPCWSTR name, const std::vector<std::pair<CStringW, Bytes>>& files)
    {
        CStringW root = mpctest::TempDir() + name;
        for (const auto& f : files) {
            CStringW path = root + L"\\BDMV\\" + f.first;
            EnsureDir(path.Left(path.ReverseFind(L'\\')));
            HANDLE h = CreateFileW(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (h == INVALID_HANDLE_VALUE) {
                throw std::runtime_error("cannot create " + mpctest::ToUtf8(path));
            }
            DWORD written = 0;
            WriteFile(h, f.second.data(), (DWORD)f.second.size(), &written, nullptr);
            CloseHandle(h);
        }
        return root;
    }
}

// --- .clpi: the streams of a clip --------------------------------------------

TEST(Hdmv, ClipInfoListsTheStreamsWithTheirAttributes)
{
    CStringW root = MakeDisc(L"bd-clpi", {
        { L"CLIPINF\\00000.clpi", Clpi({
            ClpiStream(0x1011, VIDEO_STREAM_H264, Bytes().u8(BDVM_VideoFormat_1080p << 4 | BDVM_FrameRate_23_976).u8(BDVM_AspectRatio_16_9 << 4)),
            ClpiStream(0x1100, AUDIO_STREAM_AC3, AudioAttrs(BDVM_ChannelLayout_MULTI, BDVM_SampleRate_48, "eng")),
            ClpiStream(0x1200, PRESENTATION_GRAPHICS_STREAM, PgAttrs("fra")),
            ClpiStream(0x1201, SUBTITLE_STREAM, Bytes().u8(0x12 /* bd_char_code */).str("deu")),
        }) },
    });

    CHdmvClipInfo info;
    ASSERT_EQ(info.ReadInfo(root + L"\\BDMV\\CLIPINF\\00000.clpi"), S_OK);
    EXPECT_TRUE(info.IsHdmv());
    ASSERT_EQ(info.GetStreamNumber(), (size_t)4);

    auto* video = info.FindStream(0x1011);
    ASSERT_NE(video, nullptr);
    EXPECT_EQ(video->m_Type, VIDEO_STREAM_H264);
    EXPECT_EQ(video->m_VideoFormat, BDVM_VideoFormat_1080p);
    EXPECT_EQ(video->m_FrameRate, BDVM_FrameRate_23_976);
    EXPECT_EQ(video->m_AspectRatio, BDVM_AspectRatio_16_9);
    EXPECT_EQ(CString(video->Format()), L"H264");

    auto* audio = info.FindStream(0x1100);
    ASSERT_NE(audio, nullptr);
    EXPECT_EQ(audio->m_ChannelLayout, BDVM_ChannelLayout_MULTI);
    EXPECT_EQ(audio->m_SampleRate, BDVM_SampleRate_48);
    EXPECT_EQ(std::string(audio->m_LanguageCode), "eng");
    EXPECT_EQ(PRIMARYLANGID(LANGIDFROMLCID(audio->m_LCID)), LANG_ENGLISH);
    EXPECT_EQ(CString(audio->Format()), L"AC3");

    auto* pg = info.FindStream(0x1200);
    ASSERT_NE(pg, nullptr);
    EXPECT_EQ(std::string(pg->m_LanguageCode), "fra");
    EXPECT_EQ(PRIMARYLANGID(LANGIDFROMLCID(pg->m_LCID)), LANG_FRENCH);

    auto* text = info.FindStream(0x1201);
    ASSERT_NE(text, nullptr);
    EXPECT_EQ(std::string(text->m_LanguageCode), "deu");
    EXPECT_EQ(PRIMARYLANGID(LANGIDFROMLCID(text->m_LCID)), LANG_GERMAN);

    EXPECT_EQ(info.FindStream(0x1FFF), nullptr);
    EXPECT_EQ(info.GetStreamByIndex(4), nullptr);
}

TEST(Hdmv, ClipInfoRejectsWrongMagicAndVersion)
{
    CStringW root = MakeDisc(L"bd-clpi-bad", {
        { L"CLIPINF\\mpls.clpi",    Bytes().str("MPLS").str("0200").fill(32) },
        { L"CLIPINF\\version.clpi", Bytes().str("HDMV").str("0400").fill(32) },
        { L"CLIPINF\\empty.clpi",   Bytes() },
    });

    CHdmvClipInfo info;
    EXPECT_EQ(info.ReadInfo(root + L"\\BDMV\\CLIPINF\\mpls.clpi"), VFW_E_INVALID_FILE_FORMAT);
    EXPECT_FALSE(info.IsHdmv());
    EXPECT_EQ(info.ReadInfo(root + L"\\BDMV\\CLIPINF\\version.clpi"), VFW_E_INVALID_FILE_FORMAT);
    EXPECT_EQ(info.ReadInfo(root + L"\\BDMV\\CLIPINF\\empty.clpi"), VFW_E_INVALID_FILE_FORMAT);
    EXPECT_TRUE(FAILED(info.ReadInfo(root + L"\\BDMV\\CLIPINF\\missing.clpi")));
    EXPECT_FALSE(info.IsHdmv());
}

// A clip whose ProgramInfo claims more streams than the file holds: the
// reads past the end come back as zeros and the parser stops at the end of
// what it was told, so the result is bounded and the run carries on.
TEST(Hdmv, TruncatedClipInfoIsBounded)
{
    Bytes full = Clpi({
        ClpiStream(0x1011, VIDEO_STREAM_H264, VideoAttrs(BDVM_VideoFormat_1080p, BDVM_FrameRate_23_976).u8(BDVM_AspectRatio_16_9 << 4)),
        ClpiStream(0x1100, AUDIO_STREAM_AC3, AudioAttrs(BDVM_ChannelLayout_MULTI, BDVM_SampleRate_48, "eng")),
    });
    Bytes cut = FirstBytes(full, full.size() - 6); // ends inside the second stream

    CStringW root = MakeDisc(L"bd-clpi-cut", { { L"CLIPINF\\00000.clpi", cut } });

    CHdmvClipInfo info;
    EXPECT_EQ(info.ReadInfo(root + L"\\BDMV\\CLIPINF\\00000.clpi"), S_OK);
    EXPECT_EQ(info.GetStreamNumber(), (size_t)2);
    ASSERT_NE(info.FindStream(0x1011), nullptr);
    EXPECT_EQ(info.FindStream(0x1011)->m_VideoFormat, BDVM_VideoFormat_1080p);
}

// --- .mpls: items, duration, chapters ------------------------------------------

TEST(Hdmv, PlaylistItemsAndDuration)
{
    CStringW root = MakeDisc(L"bd-mpls", {
        { L"PLAYLIST\\00000.mpls", Mpls({ PlayItem("00001", 0, 60, Hd1080Stn()), PlayItem("00002", 10, 40, Hd1080Stn()) }) },
    });

    CHdmvClipInfo info;
    REFERENCE_TIME duration = -1;
    CHdmvClipInfo::HdmvPlaylist playlist;
    ASSERT_EQ(info.ReadPlaylist(root + L"\\BDMV\\PLAYLIST\\00000.mpls", duration, playlist), S_OK);

    ASSERT_EQ(playlist.size(), (size_t)2);
    EXPECT_EQ(playlist[0].m_strFileName, root + L"\\BDMV\\STREAM\\00001.M2TS");
    EXPECT_EQ(playlist[1].m_strFileName, root + L"\\BDMV\\STREAM\\00002.M2TS");
    EXPECT_EQ(playlist[0].m_rtIn, 0);
    EXPECT_EQ(playlist[0].m_rtOut, 60 * kSecond);
    EXPECT_EQ(playlist[1].m_rtIn, 10 * kSecond);
    EXPECT_EQ(playlist[1].m_rtOut, 40 * kSecond);
    EXPECT_EQ(duration, 90 * kSecond);
    EXPECT_EQ(playlist.m_max_video_res, 1080u);
    EXPECT_GT(playlist.m_mpls_size, 0);
}

// The same clip twice in one playlist is how menus and loops are built; the
// main-movie search uses S_FALSE to pass those over.
TEST(Hdmv, PlaylistRepeatingAClipIsSFalse)
{
    CStringW root = MakeDisc(L"bd-mpls-dup", {
        { L"PLAYLIST\\00000.mpls", Mpls({ PlayItem("00001", 0, 5, Hd1080Stn()), PlayItem("00001", 0, 5, Hd1080Stn()) }) },
    });

    CHdmvClipInfo info;
    REFERENCE_TIME duration = 0;
    CHdmvClipInfo::HdmvPlaylist playlist;
    EXPECT_EQ(info.ReadPlaylist(root + L"\\BDMV\\PLAYLIST\\00000.mpls", duration, playlist), S_FALSE);
    EXPECT_EQ(playlist.size(), (size_t)2);
    EXPECT_EQ(duration, 10 * kSecond);
}

TEST(Hdmv, PlaylistRejectsBadMagicAndBadItem)
{
    CStringW root = MakeDisc(L"bd-mpls-bad", {
        { L"PLAYLIST\\hdmv.mpls",  Bytes().str("HDMV").str("0200").fill(32) },
        { L"PLAYLIST\\item.mpls",  Mpls({ PlayItem("00001", 0, 60, Hd1080Stn(), "M2TX") }) },
        // Two items announced, file ends inside the first: the fields past the
        // end read as zeros and fail the clip codec check.
        { L"PLAYLIST\\short.mpls", FirstBytes(Mpls({ PlayItem("00001", 0, 60, Hd1080Stn()), PlayItem("00002", 0, 60, Hd1080Stn()) }), 60) },
    });

    CHdmvClipInfo info;
    REFERENCE_TIME duration = 0;
    CHdmvClipInfo::HdmvPlaylist playlist;
    EXPECT_EQ(info.ReadPlaylist(root + L"\\BDMV\\PLAYLIST\\hdmv.mpls", duration, playlist), VFW_E_INVALID_FILE_FORMAT);
    EXPECT_EQ(info.ReadPlaylist(root + L"\\BDMV\\PLAYLIST\\item.mpls", duration, playlist), VFW_E_INVALID_FILE_FORMAT);
    EXPECT_EQ(info.ReadPlaylist(root + L"\\BDMV\\PLAYLIST\\short.mpls", duration, playlist), VFW_E_INVALID_FILE_FORMAT);
    EXPECT_TRUE(FAILED(info.ReadPlaylist(root + L"\\BDMV\\PLAYLIST\\missing.mpls", duration, playlist)));
}

// Chapter marks are per PlayItem, timed from that clip's own zero; the player
// wants them on the concatenated timeline of the whole playlist.
TEST(Hdmv, ChaptersAreOffsetOntoThePlaylistTimeline)
{
    CStringW root = MakeDisc(L"bd-chapters", {
        { L"PLAYLIST\\00000.mpls", Mpls(
            { PlayItem("00001", 0, 60, Hd1080Stn()), PlayItem("00002", 10, 40, Hd1080Stn()) },
            { Mark(CHdmvClipInfo::EntryMark, 0, 0), Mark(CHdmvClipInfo::EntryMark, 0, 30), Mark(CHdmvClipInfo::LinkPoint, 1, 20, 0x1011, 5), Mark(CHdmvClipInfo::EntryMark, 1, 25) }) },
    });
    CStringW mpls = root + L"\\BDMV\\PLAYLIST\\00000.mpls";

    CHdmvClipInfo info;
    REFERENCE_TIME duration = 0;
    CHdmvClipInfo::HdmvPlaylist playlist;
    ASSERT_EQ(info.ReadPlaylist(mpls, duration, playlist), S_OK);

    CAtlList<CHdmvClipInfo::PlaylistItem> items;
    for (const auto& i : playlist) {
        items.AddTail(i);
    }
    CAtlList<CHdmvClipInfo::PlaylistChapter> chapters;
    ASSERT_EQ(info.ReadChapters(mpls, items, chapters), S_OK);
    ASSERT_EQ(chapters.GetCount(), (size_t)4);

    std::vector<CHdmvClipInfo::PlaylistChapter> c;
    for (POSITION pos = chapters.GetHeadPosition(); pos;) {
        c.push_back(chapters.GetNext(pos));
    }
    EXPECT_EQ(c[0].m_rtTimestamp, 0);
    EXPECT_EQ(c[1].m_rtTimestamp, 30 * kSecond);
    EXPECT_EQ(c[2].m_rtTimestamp, (60 + 20 - 10) * kSecond); // second clip starts at 60 s, its own zero is 10 s in
    EXPECT_EQ(c[2].m_nMarkType, CHdmvClipInfo::LinkPoint);
    EXPECT_EQ(c[2].m_rtDuration, 5 * kSecond);
    EXPECT_EQ(c[2].m_nEntryPID, 0x1011);
    EXPECT_EQ(c[3].m_rtTimestamp, (60 + 25 - 10) * kSecond);
    EXPECT_EQ(c[3].m_nPlayItemId, 1);
}

// A mark that refers to a PlayItem the playlist does not have has nowhere to
// go on the timeline. Isolated because the current code reads past an array
// to place it.
TEST_ISOLATED_EXPECTED_FAILURE(Hdmv, ChapterForAMissingPlayItemIsDropped,
                               "ReadChapters indexes rtOffset[] with ref_to_PlayItem_id straight from the file, with no check against the "
                               "number of PlayItems: a mark for PlayItem 7 of a two-item playlist reads past the array and is kept with a garbage timestamp")
{
    CStringW root = MakeDisc(L"bd-chapters-oob", {
        { L"PLAYLIST\\00000.mpls", Mpls(
            { PlayItem("00001", 0, 60, Hd1080Stn()), PlayItem("00002", 0, 30, Hd1080Stn()) },
            { Mark(CHdmvClipInfo::EntryMark, 0, 30), Mark(CHdmvClipInfo::EntryMark, 7, 1) }) },
    });
    CStringW mpls = root + L"\\BDMV\\PLAYLIST\\00000.mpls";

    CHdmvClipInfo info;
    REFERENCE_TIME duration = 0;
    CHdmvClipInfo::HdmvPlaylist playlist;
    ASSERT_EQ(info.ReadPlaylist(mpls, duration, playlist), S_OK);
    CAtlList<CHdmvClipInfo::PlaylistItem> items;
    for (const auto& i : playlist) {
        items.AddTail(i);
    }
    CAtlList<CHdmvClipInfo::PlaylistChapter> chapters;
    ASSERT_EQ(info.ReadChapters(mpls, items, chapters), S_OK);
    ASSERT_EQ(chapters.GetCount(), (size_t)1);
    EXPECT_EQ(chapters.GetHead().m_rtTimestamp, 30 * kSecond);
}

// --- the main movie -------------------------------------------------------------

TEST(Hdmv, FindMainMovieTakesTheLongestPlaylistAndListsTheFeatureLength)
{
    CStringW root = MakeDisc(L"bd-main", {
        { L"PLAYLIST\\00000.mpls", Mpls({ PlayItem("00000", 0, 120, Hd1080Stn()) }) },                                         // 2 min: menu, below the listing limit
        { L"PLAYLIST\\00001.mpls", Mpls({ PlayItem("00001", 0, 3600, Hd1080Stn()), PlayItem("00002", 0, 1800, Hd1080Stn()) }) }, // 90 min: the feature
        { L"PLAYLIST\\00002.mpls", Mpls({ PlayItem("00003", 0, 600, Sd480Stn()) }) },                                          // 10 min extra
        { L"PLAYLIST\\00003.mpls", Mpls({ PlayItem("00001", 0, 3600, Hd1080Stn()), PlayItem("00002", 0, 1800, Hd1080Stn()) }) }, // the feature again: a duplicate
    });

    CHdmvClipInfo info;
    CString mainFile;
    CHdmvClipInfo::HdmvPlaylist main, all;
    ASSERT_EQ(info.FindMainMovie(root, mainFile, main, all), S_OK);

    EXPECT_EQ(mainFile, root + L"\\BDMV\\PLAYLIST\\00001.mpls");
    ASSERT_EQ(main.size(), (size_t)2);
    EXPECT_EQ(main[0].m_strFileName, root + L"\\BDMV\\STREAM\\00001.M2TS");
    EXPECT_EQ(main[1].m_rtOut, 1800 * kSecond);

    // Playlists of three minutes or more, longest first, the duplicate folded.
    ASSERT_EQ(all.size(), (size_t)2);
    EXPECT_EQ(all[0].m_strFileName, root + L"\\BDMV\\PLAYLIST\\00001.mpls");
    EXPECT_EQ(all[0].m_rtOut, 5400 * kSecond);
    EXPECT_EQ(all[1].m_strFileName, root + L"\\BDMV\\PLAYLIST\\00002.mpls");
    EXPECT_EQ(all[1].m_rtOut, 600 * kSecond);
}

TEST(Hdmv, FindMainMovieAcceptsTheFolderInAnyOfItsSpellings)
{
    CStringW root = MakeDisc(L"bd-spellings", {
        { L"PLAYLIST\\00000.mpls", Mpls({ PlayItem("00000", 0, 300, Hd1080Stn()) }) },
    });

    // OpenBD strips "\BDMV" and passes the disc root, with or without a slash.
    for (CStringW folder : { root, root + L"\\" }) {
        CHdmvClipInfo info;
        CString mainFile;
        CHdmvClipInfo::HdmvPlaylist main, all;
        EXPECT_EQ(info.FindMainMovie(folder, mainFile, main, all), S_OK) << mpctest::ToUtf8(folder);
        EXPECT_EQ(mainFile, root + L"\\BDMV\\PLAYLIST\\00000.mpls") << mpctest::ToUtf8(folder);
    }

    CHdmvClipInfo info;
    CString mainFile;
    CHdmvClipInfo::HdmvPlaylist main, all;
    EXPECT_EQ(info.FindMainMovie(mpctest::TempDir() + L"bd-nowhere", mainFile, main, all), E_FAIL);
    EXPECT_TRUE(main.empty());
}

// FindMainMovie reads every playlist through one CHdmvClipInfo, and prefers
// the higher resolution when durations are close. That only works if each
// playlist's resolution is its own.
TEST_EXPECTED_FAILURE(Hdmv, PlaylistVideoResolutionIsItsOwn,
                      "the STN stream table (stn.m_Streams) is never cleared between ReadPlaylist calls, so a 480i playlist read after a "
                      "1080p one on the same CHdmvClipInfo reports m_max_video_res 1080")
{
    CStringW root = MakeDisc(L"bd-res", {
        { L"PLAYLIST\\00000.mpls", Mpls({ PlayItem("00000", 0, 300, Hd1080Stn()) }) },
        { L"PLAYLIST\\00001.mpls", Mpls({ PlayItem("00001", 0, 300, Sd480Stn()) }) },
    });

    CHdmvClipInfo info;
    REFERENCE_TIME duration = 0;
    CHdmvClipInfo::HdmvPlaylist hd, sd;
    ASSERT_EQ(info.ReadPlaylist(root + L"\\BDMV\\PLAYLIST\\00000.mpls", duration, hd), S_OK);
    EXPECT_EQ(hd.m_max_video_res, 1080u);
    ASSERT_EQ(info.ReadPlaylist(root + L"\\BDMV\\PLAYLIST\\00001.mpls", duration, sd), S_OK);
    EXPECT_EQ(sd.m_max_video_res, 480u);
}
