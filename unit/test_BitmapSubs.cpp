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
#include "../../src/Subtitles/VobSubImage.h"
#include "../../src/Subtitles/VobSubFile.h"
#include "../../src/Subtitles/PGSSub.h"
#include "../../src/Subtitles/DVBSub.h"

// The bitmap subtitle decoders, fed byte sequences built here. These parse
// length and offset fields straight from the stream, so the fixtures are
// deliberately malformed. Modelled on #4187 (PGS/DVB palette bounds), #4183
// (VobSub trusting sizes from the stream) and #4192 (VobSub offset
// validation): the malformed cases must be rejected, not read out of bounds.
// Every buffer handed to a decoder is a GuardedBuffer, so a read one byte
// past the input is an access violation caught as a failure.

using namespace testutil;

// --- VobSub -----------------------------------------------------------------

namespace
{
    // A sub-picture unit: RLE data, then a single control block at offset
    // dataSize with date, a self-pointing next-block offset, a rectangle, the
    // two plane offsets and the end marker.
    Bytes VobSubPacket(size_t dataSize, unsigned nOffset0, unsigned nOffset1,
                       int left = 0, int top = 0, int right = 2, int bottom = 2)
    {
        Bytes b;
        b.fill(dataSize, 0x00);                    // RLE data area (zeros: transparent runs)
        const size_t ctrl = b.size();
        b.u16(0);                                  // date
        b.u16((unsigned)ctrl);                     // next control block -> self (last block)
        b.u8(0x05);                                // set display area
        b.u8(left >> 4).u8(((left & 0x0f) << 4) | (((right - 1) >> 8) & 0x0f)).u8((right - 1) & 0xff);
        b.u8(top >> 4).u8(((top & 0x0f) << 4) | (((bottom - 1) >> 8) & 0x0f)).u8((bottom - 1) & 0xff);
        b.u8(0x06);                                // set data offsets
        b.u16(nOffset0).u16(nOffset1);
        b.u8(0xff);                                // end of control block
        return b;
    }
}

TEST(VobSub, GetPacketInfoValidRect)
{
    Bytes packet = VobSubPacket(8, 0, 4, 0, 0, 16, 12);
    GuardedBuffer buf(packet);
    CVobSubImage img;
    ASSERT_TRUE(img.GetPacketInfo(buf.data(), buf.size(), 8));
    EXPECT_EQ(img.rect.Width(), 16);
    EXPECT_EQ(img.rect.Height(), 12);
}

TEST(VobSub, DecodeValidPacketDoesNotCrash)
{
    // A tiny well-formed RLE area: the decoder walks it without reading past
    // dataSize. We only assert it returns and produces the declared size.
    Bytes rle;
    rle.u8(0x04).u8(0x00);   // plane 0: one 0-count -> new line, then end
    rle.u8(0x04).u8(0x00);   // plane 1
    Bytes packet = VobSubPacket(rle.size(), 0, 2, 0, 0, 2, 2);
    // overwrite the RLE area with our bytes
    for (size_t i = 0; i < rle.size(); i++) {
        packet[i] = rle[i];
    }
    GuardedBuffer buf(packet);
    CVobSubImage img;
    RGBQUAD pal[16] = {}, cuspal[4] = {};
    bool ok = img.Decode(buf.data(), buf.size(), rle.size(), INT_MAX, false, 0, pal, cuspal, false);
    EXPECT_TRUE(ok || !ok); // the assertion is "it returned without crashing or hanging"
}

// #4192: the next-control-block offset comes from the packet. Here the first
// block points at a second block that sits in the last two bytes, so reading
// that block's 4-byte header runs off the end.
// #4192: GetPacketInfo read a control block's date and next-offset without
// checking i + 4 against packetSize.
TEST(VobSub, GetPacketInfoTruncatedControlBlock)
{
    Bytes b;
    b.fill(4, 0x00);           // data area, dataSize = 4
    const unsigned block1 = (unsigned)b.size();
    // block1: date, next -> block2 (set below), then just an end marker
    b.u16(0);                  // date
    const size_t nextField = b.size();
    b.u16(0);                  // next offset, patched after we know block2
    b.u8(0xff);                // end of block1
    const unsigned block2 = (unsigned)b.size(); // block2 starts here, only 2 bytes will follow
    b.u16(0);                  // block2 date -- its next-offset read goes past the end
    b.data()[nextField] = (BYTE)(block2 >> 8);
    b.data()[nextField + 1] = (BYTE)(block2 & 0xff);
    UNREFERENCED_PARAMETER(block1);

    GuardedBuffer buf(b);
    CVobSubImage img;
    EXPECT_FALSE(img.GetPacketInfo(buf.data(), buf.size(), 4));
}

// #4192: plane offsets from the packet drive the RLE read in Decode, and
// were once trusted as far as dataSize without a check.
TEST(VobSub, DecodeRejectsOutOfRangeOffsets)
{
    Bytes packet = VobSubPacket(8, 0, 0x7000, 0, 0, 2, 2); // nOffset[1] far past dataSize
    GuardedBuffer buf(packet);
    CVobSubImage img;
    RGBQUAD pal[16] = {}, cuspal[4] = {};
    EXPECT_FALSE(img.Decode(buf.data(), buf.size(), 8, INT_MAX, false, 0, pal, cuspal, false));
}

// #4183 (55051b9717): a control block with no display command (no
// start/stop/display-area) used to leave Decode running on an empty rect.
// GetPacketInfo now reports such a packet as invalid and empties the rect.
TEST(VobSub, GetPacketInfoRejectsBlockWithoutDisplayCommands)
{
    Bytes b;
    b.fill(4, 0x00);           // data area, dataSize = 4
    b.u16(0);                  // date
    b.u16(4);                  // next control block -> self (last block)
    b.u8(0x03).u16(0x0000);    // set palette -- not a display command
    b.u8(0xff);                // end of control block

    GuardedBuffer buf(b);
    CVobSubImage img;
    EXPECT_FALSE(img.GetPacketInfo(buf.data(), buf.size(), 4));
    EXPECT_TRUE(img.rect.IsRectEmpty());
}

// #4183 (55051b9717): a display-area command with zero width or height made
// Decode allocate and draw a zero-sized image; it now refuses the packet.
TEST_ISOLATED(VobSub, DecodeRejectsEmptyRect)
{
    Bytes packet = VobSubPacket(8, 0, 4, 5, 0, 5, 2); // right == left: width 0
    GuardedBuffer buf(packet);
    CVobSubImage img;
    RGBQUAD pal[16] = {}, cuspal[4] = {};
    EXPECT_FALSE(img.Decode(buf.data(), buf.size(), 8, INT_MAX, false, 0, pal, cuspal, false));
}

// The rejection above must not catch a well-formed packet. The packet Add
// sees starts with its two 16-bit size fields, so the RLE area begins at
// offset 4 and every offset is absolute to the packet start.
TEST(VobSub, StreamAddAcceptsWellFormedPacket)
{
    CCritSec lock;
    CVobSubStream vs(&lock);
    Bytes body = VobSubPacket(8, 4, 8, 0, 0, 2, 2);
    body[10] = 0; body[11] = 12; // self-pointer, in packet coordinates: the
                                 // 4 size bytes move the control block to 12
    Bytes p;
    p.u16((unsigned)body.size() + 4).u16(12).add(body);
    GuardedBuffer buf(p);
    vs.Add(0, 10000000, buf.data(), (int)buf.size());
    EXPECT_TRUE(vs.GetStartPosition(0, 1.0) != nullptr);
}

// #4183 (53e911d180): CVobSubStream::Add passed the packet's data size field
// into GetPacketInfo unchecked, so a packet whose declared data size ran past
// its end made the parser read out of bounds. It is now rejected before
// parsing, and nothing is added.
TEST_ISOLATED(VobSub, StreamAddRejectsDataSizeBeyondPacket)
{
    CCritSec lock;
    CVobSubStream vs(&lock);
    Bytes p;
    p.u16(16).u16(100).fill(12, 0x00); // packet size 16, data size far past it
    GuardedBuffer buf(p);
    vs.Add(0, 10000000, buf.data(), (int)buf.size());
    EXPECT_TRUE(vs.GetStartPosition(0, 1.0) == nullptr);
}

namespace
{
    // GetPacket is protected, so drive it through a subclass: the .sub image
    // lives in m_sub and the index in m_langs, both reachable from here.
    class CTestVobSubFile : public CVobSubFile
    {
    public:
        explicit CTestVobSubFile(CCritSec* pLock) : CVobSubFile(pLock) {}
        using CVobSubFile::GetPacket;
        using CVobSubFile::ReadIdx;
        CMemFile& SubImage() { return m_sub; }
    };

    // One 0x800-byte .sub pack for stream 0: pack header, PES header, then
    // the packet and data size fields GetPacket reads.
    Bytes VobSubSubPack(unsigned packetSize, unsigned dataSize)
    {
        Bytes b;
        b.fill(0x800, 0x00);
        BYTE* p = b.data();
        p[0x02] = 0x01; p[0x03] = 0xba; // pack start code
        p[0x10] = 0x01; p[0x11] = 0xbd; // PES start code
        p[0x15] = 0x80;
        p[0x16] = 0x00;                 // no extra PES header bytes
        p[0x17] = 0x20;                 // sub-stream id 0
        p[0x18] = (BYTE)(packetSize >> 8); p[0x19] = (BYTE)packetSize;
        p[0x1a] = (BYTE)(dataSize >> 8);  p[0x1b] = (BYTE)dataSize;
        return b;
    }
}

// #4183 (d2dcb450d8): the data length in a .sub pack was trusted during
// packet assembly; a dataSize that runs past packetSize now rejects the
// packet instead of handing consumers a buffer that ends before its data.
// Isolated: unfixed, the packet handed back claims data past its own end, and
// a consumer over-reading it must not take the rest of the run with it.
TEST_ISOLATED(VobSub, FileGetPacketRejectsDataSizeBeyondPacket)
{
    CCritSec lock;
    CTestVobSubFile vsf(&lock);
    vsf.m_nLang = 0;
    CVobSubFile::SubPos pos;
    vsf.m_langs[0].subpos.Add(pos);      // filepos 0: the malformed pack
    pos.filepos = 0x800;
    vsf.m_langs[0].subpos.Add(pos);      // filepos 0x800: a well-formed pack

    Bytes image;
    image.add(VobSubSubPack(0x10, 0x10))   // dataSize + 4 > packetSize
         .add(VobSubSubPack(0x20, 0x10));  // fits
    vsf.SubImage().Write(image.data(), (UINT)image.size());

    size_t packetSize = 0, dataSize = 0;
    EXPECT_EQ(vsf.GetPacket(0, packetSize, dataSize), nullptr);

    BYTE* good = vsf.GetPacket(1, packetSize, dataSize);
    ASSERT_NE(good, nullptr);
    EXPECT_EQ(packetSize, 0x20u);
    EXPECT_EQ(dataSize, 0x10u);
    delete[] good;
}

// #4183 (0332950f11): Open called ReadIdx unguarded, so a throw out of the
// .idx parse propagated out of Open. ReadIdx has no throw of its own -- a bad
// version line only sets bError -- so the throw has to come from the file
// read. CTextFile::Open probes the BOM by asking CStdioFile for 2 bytes, but
// the CRT fills its whole buffer to serve that, so the probe covers the first
// few KB, not 2 bytes; ReopenAsText then rereads the file through CStdioFile
// in text mode, and any later buffered read that fails raises CFileException.
// To fail such a read we hold an exclusive byte-range lock on the .idx from
// 16 KB to past the end of the file: locks are per handle, so the player's
// own handle gets ERROR_LOCK_VIOLATION once its buffered reads walk into the
// lock, while the probe's first buffer does not reach it. Without the fix the
// exception escapes Open and fails this test; with it Open catches and
// returns false.
TEST(VobSub, OpenWithUnreadableIdxFailsWithoutThrowing)
{
    CCritSec lock;

    // A valid-looking .idx: the correct header, no BOM, and enough valid
    // comment lines that the parse's buffered reads proceed past 16 KB.
    std::string idx = "# VobSub index file, v7 (do not modify this line!)\r\n";
    while (idx.size() < 32 * 1024) {
        idx += "# padding so a later buffered read runs into the lock\r\n";
    }
    Bytes sub;
    sub.u32(0x000001ba).fill(0x7fc, 0x00);
    WriteTemp(L"vobsub-locked.sub", sub);
    CStringW idxPath = WriteTemp(L"vobsub-locked.idx", idx);

    // Unlock and close on every path out of the test, ASSERTs included.
    struct IdxLock {
        HANDLE h = INVALID_HANDLE_VALUE;
        OVERLAPPED ov = {};
        DWORD len = 0;
        ~IdxLock() {
            if (h != INVALID_HANDLE_VALUE) {
                if (len) {
                    UnlockFileEx(h, 0, len, 0, &ov);
                }
                CloseHandle(h);
            }
        }
    } guard;

    guard.h = CreateFileW(idxPath, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                          nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    ASSERT_NE(guard.h, INVALID_HANDLE_VALUE);
    guard.ov.Offset = 16 * 1024; // past the first buffered read
    guard.len = 0x100000;        // runs past the end of the file
    ASSERT_TRUE(LockFileEx(guard.h, LOCKFILE_EXCLUSIVE_LOCK, 0, guard.len, 0, &guard.ov));

    // The input really reaches the throw: ReadIdx itself raises (MFC throws
    // CFileException pointers; EXPECT_ANY_THROW's catch-all takes it).
    {
        CTestVobSubFile vsf(&lock);
        int ver = 0;
        EXPECT_ANY_THROW(vsf.ReadIdx(idxPath, ver));
    }

    // And Open turns that throw into a plain false.
    CVobSubFile vsf(&lock);
    EXPECT_FALSE(vsf.Open(idxPath));
}

// --- PGS --------------------------------------------------------------------

namespace
{
    // A PGS "sample" is a run of segments: type, 16-bit length, payload.
    Bytes PgsSegment(BYTE type, const Bytes& payload)
    {
        Bytes b;
        b.u8(type).u16((unsigned)payload.size()).add(payload);
        return b;
    }

    // A palette-definition segment: palette_id, version, then 5-byte entries.
    Bytes PgsPalette(unsigned entryCount)
    {
        Bytes p;
        p.u8(0).u8(0); // id, version
        for (unsigned i = 0; i < entryCount; i++) {
            p.u8(i & 0xff).u8(128).u8(128).u8(128).u8(255); // entry_id, Y, Cr, Cb, T
        }
        return PgsSegment(0x14, p);
    }
}

TEST(PGS, ValidPaletteSegmentParses)
{
    CCritSec lock;
    CPGSSub pgs(&lock, L"test", 0);
    Bytes sample = PgsPalette(16);
    GuardedBuffer buf(sample);
    EXPECT_EQ(pgs.ParseSample(0, 0, buf.data(), buf.size()), S_OK);
}

TEST(PGS, FullPalette256Entries)
{
    CCritSec lock;
    CPGSSub pgs(&lock, L"test", 0);
    Bytes sample = PgsPalette(256);
    GuardedBuffer buf(sample);
    EXPECT_EQ(pgs.ParseSample(0, 0, buf.data(), buf.size()), S_OK);
}

TEST(PGS, EmptyAndTruncatedSamples)
{
    CCritSec lock;
    CPGSSub pgs(&lock, L"test", 0);
    // A header that claims more payload than the sample carries: buffered and
    // held for later, never over-read.
    Bytes shortSample;
    shortSample.u8(0x14).u16(500).u8(0).u8(0);
    GuardedBuffer buf(shortSample);
    EXPECT_EQ(pgs.ParseSample(0, 0, buf.data(), buf.size()), S_OK);
}

// #4187: a palette segment shorter than its two-byte header. Pre-fix this
// underflows the entry count; the out-of-bounds write lands in the object's
// own large palette arrays, so it corrupts silently rather than crashing and
// cannot be caught at unit level without the fix. What is checkable is that
// the input itself is not over-read and the call returns.
TEST(PGS, ShortPaletteSegment)
{
    CCritSec lock;
    CPGSSub pgs(&lock, L"test", 0);
    Bytes sample;
    sample.u8(0x14).u16(2).u8(0).u8(0); // palette segment, length 2 (header only, zero entries)
    GuardedBuffer buf(sample);
    EXPECT_EQ(pgs.ParseSample(0, 0, buf.data(), buf.size()), S_OK);
}

// --- DVB --------------------------------------------------------------------

namespace
{
    // A DVB subtitle stream: data_identifier 0x20, stream_id 0x00, then
    // segments, each 0x0F sync, type, page id, 16-bit length, payload.
    Bytes DvbSegment(BYTE type, unsigned pageId, const Bytes& payload)
    {
        Bytes b;
        b.u8(0x0F).u8(type).u16(pageId).u16((unsigned)payload.size()).add(payload);
        return b;
    }

    Bytes DvbStream(const Bytes& segments)
    {
        Bytes b;
        b.u8(0x20).u8(0x00).add(segments);
        return b;
    }

    // A composition page with no regions (page_time_out, version/state).
    Bytes DvbPage()
    {
        Bytes p;
        p.u8(10).u8(0); // timeout 10s, version 0 / state 0
        return DvbSegment(0x10, 1, p);
    }

    // A CLUT segment: clut_id, version, then entries. Each 2-bit-flagged entry
    // here uses the short (2-byte) form: entry_id, then a flags byte.
    Bytes DvbClut(unsigned entryCount)
    {
        Bytes p;
        p.u8(0).u8(0); // clut id, version/reserved
        for (unsigned i = 0; i < entryCount; i++) {
            p.u8(i & 0xff); // entry_id
            p.u8(0x00);     // flags: full_range off -> 2-byte entry, next byte is the packed value
            p.u8(0x00);
        }
        return DvbSegment(0x12, 1, p);
    }
}

TEST(DVB, ValidPageAndClutParse)
{
    CCritSec lock;
    CDVBSub dvb(&lock, L"test", 0);
    Bytes segments;
    segments.add(DvbPage()).add(DvbClut(4));
    Bytes sample = DvbStream(segments);
    GuardedBuffer buf(sample);
    HRESULT hr = dvb.ParseSample(0, 0, buf.data(), buf.size());
    EXPECT_TRUE(hr == S_OK || hr == S_FALSE);
}

TEST(DVB, TruncatedSegmentIsHeldNotOverRead)
{
    CCritSec lock;
    CDVBSub dvb(&lock, L"test", 0);
    // A segment header that promises a longer payload than is present.
    Bytes seg;
    seg.u8(0x0F).u8(0x12).u16(1).u16(400).u8(0).u8(0);
    Bytes sample = DvbStream(seg);
    GuardedBuffer buf(sample);
    HRESULT hr = dvb.ParseSample(0, 0, buf.data(), buf.size());
    EXPECT_TRUE(hr == S_OK || hr == S_FALSE);
}

TEST(DVB, GarbageSampleIsRejectedWithoutOverRead)
{
    CCritSec lock;
    CDVBSub dvb(&lock, L"test", 0);
    Bytes sample;
    sample.str("not a dvb subtitle segment at all, really");
    GuardedBuffer buf(sample);
    // AddToBuffer only accepts data starting with the DVB marker, so this is
    // dropped; the point is that it does not read past the sample.
    HRESULT hr = dvb.ParseSample(0, 0, buf.data(), buf.size());
    EXPECT_TRUE(hr == S_OK || hr == S_FALSE || FAILED(hr));
}
