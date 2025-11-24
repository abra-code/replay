//
//  FileInfo.h
//  fingerprint
//
//  Created by Tomasz Kukielka on 11/17/25.
//

#include <fts.h>
#include <sys/stat.h>

struct FileInfo
{
    ino_t    inode;      // 8
    off_t    size;       // 8
    int64_t  mtime_ns;   // 8
    union
    {
        struct
        {
            uint32_t crc32c;
            uint32_t reserved;  // always 0
        };
        uint64_t blake3;        // low 64 bits
    } checksum;
    
    // Construct from valid FTSENT reference
    explicit FileInfo(const FTSENT& ent) noexcept
        : inode(ent.fts_statp->st_ino)
        , size(ent.fts_statp->st_size)
        , mtime_ns((int64_t)ent.fts_statp->st_mtimespec.tv_sec * 1000000000LL +
                   ent.fts_statp->st_mtimespec.tv_nsec)
        , checksum{0}
    {
    }

    FileInfo() noexcept = default;
};
