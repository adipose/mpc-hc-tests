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
#include "../../src/Subtitles/RTS.h"
#include <random>
#include <vector>

// CRenderingCache's optional growth (src/Subtitles/RenderingCache.h), seen
// from outside: how many keys it still holds, and which ones. SetMaxBytes
// turns it on; only RenderingCaches::overlayCache does.

namespace
{
    struct Blob {
        size_t bytes = 1;
    };

    size_t CacheEntryBytes(const Blob& blob)
    {
        return blob.bytes;
    }

    typedef CRenderingCache<int, Blob> Cache;

    // Keys that do not fall in neat runs in the cache's bit array.
    int Scatter(int i)
    {
        return int((ULONG(i) + 1) * 2654435761u >> 1);
    }

    bool Holds(Cache& cache, int key)
    {
        Blob blob;
        return cache.Lookup(key, blob);
    }

    void Add(Cache& cache, int key, size_t bytes = 1)
    {
        Blob blob;
        blob.bytes = bytes;
        cache.SetAt(key, blob);
    }

    int HeldOf(Cache& cache, int first, int last)
    {
        int held = 0;
        for (int key = first; key <= last; key++) {
            held += Holds(cache, key);
        }
        return held;
    }

    // One pass over keys 0..count-1, adding what is missing. Returns the misses.
    int Cycle(Cache& cache, int count)
    {
        int misses = 0;
        for (int key = 0; key < count; key++) {
            if (!Holds(cache, key)) {
                Add(cache, key);
                misses++;
            }
        }
        return misses;
    }
}

TEST(RenderingCacheGrowth, CyclicKeysLargerThanTheCacheGrowItUntilTheyHit)
{
    Cache cache(16);
    cache.SetMaxBytes(1 << 20);

    EXPECT_EQ(Cycle(cache, 24), 24);
    for (int pass = 0; pass < 8; pass++) {
        Cycle(cache, 24);
    }
    EXPECT_EQ(Cycle(cache, 24), 0);
}

TEST(RenderingCacheGrowth, CycleOfFourTimesTheCapacityGrowsUntilItFits)
{
    Cache cache(16);
    cache.SetMaxBytes(1 << 20);

    EXPECT_EQ(Cycle(cache, 4 * 16), 4 * 16);
    for (int pass = 0; pass < 8; pass++) {
        Cycle(cache, 4 * 16);
    }
    EXPECT_EQ(Cycle(cache, 4 * 16), 0);
}

TEST(RenderingCacheGrowth, CycleOfSixTimesTheCapacityGrowsUntilItFits)
{
    Cache cache(16);
    cache.SetMaxBytes(1 << 20);

    EXPECT_EQ(Cycle(cache, 6 * 16), 6 * 16);
    for (int pass = 0; pass < 8; pass++) {
        Cycle(cache, 6 * 16);
    }
    EXPECT_EQ(Cycle(cache, 6 * 16), 0);
}

TEST(RenderingCacheGrowth, SixHundredGlyphsPerFrameGrowTheOverlayCapacity)
{
    Cache cache(128);
    cache.SetMaxBytes(1 << 20);

    for (int pass = 0; pass < 8; pass++) {
        Cycle(cache, 600);
    }
    EXPECT_EQ(Cycle(cache, 600), 0);
}

TEST(RenderingCacheGrowth, NewKeysNeverGrowIt)
{
    Cache cache(16);
    cache.SetMaxBytes(1 << 20);

    const int count = 100000;
    for (int i = 0; i < count; i++) {
        Add(cache, Scatter(i));
    }

    int held = 0;
    for (int i = count - 64; i < count; i++) {
        held += Holds(cache, Scatter(i));
    }
    EXPECT_EQ(held, 16);
}

// Scatter spreads keys too evenly to collide in the bit array. Random keys do,
// and collisions alone must not look like re-misses at the overlay's capacity.
TEST(RenderingCacheGrowth, RandomNewKeysNeverGrowTheOverlayCapacity)
{
    Cache cache(128);
    cache.SetMaxBytes(size_t(1) << 30);

    std::mt19937 random(1);
    std::vector<int> keys(3000000);
    for (int& key : keys) {
        key = int(random());
        Add(cache, key);
    }

    int held = 0;
    for (size_t i = keys.size() - 1024; i < keys.size(); i++) {
        held += Holds(cache, keys[i]);
    }
    EXPECT_EQ(held, 128);
}

TEST(RenderingCacheGrowth, ByteCeilingEvictsOldestFirst)
{
    Cache cache(1024);
    cache.SetMaxBytes(1000);

    for (int key = 0; key < 25; key++) {
        Add(cache, key, 100);
    }
    EXPECT_EQ(HeldOf(cache, 15, 24), 10);
    EXPECT_EQ(HeldOf(cache, 0, 14), 0);
}

TEST(RenderingCacheGrowth, ReplacingAValueCountsTheNewSize)
{
    Cache cache(1024);
    cache.SetMaxBytes(1000);

    for (int key = 0; key < 10; key++) {
        Add(cache, key, 100);
    }
    Add(cache, 9, 300); // the other nine now total 1200, so two go
    EXPECT_EQ(HeldOf(cache, 0, 1), 0);
    EXPECT_EQ(HeldOf(cache, 2, 9), 8);

    Add(cache, 9, 100); // back under, so a new entry fits without evicting
    Add(cache, 100, 200);
    EXPECT_EQ(HeldOf(cache, 2, 9), 8);
    EXPECT_TRUE(Holds(cache, 100));
}

TEST(RenderingCacheGrowth, EntryOverTheCeilingIsStillKept)
{
    Cache cache(1024);
    cache.SetMaxBytes(1000);

    Add(cache, 1, 100);
    Add(cache, 2, 5000);
    EXPECT_FALSE(Holds(cache, 1));
    EXPECT_TRUE(Holds(cache, 2));
}

TEST(RenderingCacheGrowth, ClearResetsTheAccounting)
{
    Cache cache(1024);
    cache.SetMaxBytes(1000);

    for (int key = 0; key < 10; key++) {
        Add(cache, key, 100);
    }
    cache.Clear();
    EXPECT_EQ(HeldOf(cache, 0, 9), 0);

    for (int key = 10; key < 20; key++) {
        Add(cache, key, 100);
    }
    EXPECT_EQ(HeldOf(cache, 10, 19), 10);
}

TEST(RenderingCacheGrowth, ClearForgetsEvictedKeys)
{
    Cache cache(8);
    cache.SetMaxBytes(1 << 20);

    for (int key = 1; key <= 14; key++) {
        Add(cache, key);
    }
    cache.Clear();

    // Keys 1..6 were evicted, and would count as re-misses here.
    for (int key = 1; key <= 9; key++) {
        Add(cache, key);
    }
    EXPECT_EQ(HeldOf(cache, 1, 9), 8);
}

TEST(RenderingCacheGrowth, WithoutACeilingItIsAFixedSize)
{
    Cache cache(16);

    for (int pass = 0; pass < 32; pass++) {
        EXPECT_EQ(Cycle(cache, 24), 24);
    }
    EXPECT_EQ(HeldOf(cache, 0, 23), 16);

    Add(cache, 100, size_t(1) << 40); // bytes mean nothing without a ceiling
    EXPECT_EQ(HeldOf(cache, 0, 23), 15);
}

TEST(RenderingCacheGrowth, OverlayEntryCountsBothBuffers)
{
    EXPECT_EQ(CacheEntryBytes(COverlayDataSharedPtr()), 0u);

    auto overlay = std::make_shared<COverlayData>();
    overlay->mOverlayPitch = 32;
    overlay->mOverlayHeight = 10;
    EXPECT_EQ(CacheEntryBytes(overlay), 640u);
}
