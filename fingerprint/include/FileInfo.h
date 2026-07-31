//
//  FileInfo.h
//  fingerprint
//
//  Created by Tomasz Kukielka on 11/17/25.
//

#pragma once

#include <fts.h>
#include <sys/stat.h>
#include <cstdint>

// the structure persisted in xattr for "public.fingerprint.crc32c" or "public.fingerprint.blake3"
struct FileInfoCore
{
    ino_t    inode;      // 8 bytes
    off_t    size;       // 8 bytes
    int64_t  mtime_ns;   // 8 bytes
    union
    {
        struct
        {
            uint32_t crc32c; // 4 bytes
            uint32_t reserved; // 4 bytes, always 0
        };
        uint64_t blake3;       // 8 bytes, low 64 bits of blake3
    } hash;
};

// The xattr payload is this exact byte range, shared with the gate and fingerprint tools.
// Nothing may be added to it without breaking every record already on disk.
static_assert(sizeof(FileInfoCore) == 32, "the persisted fingerprint xattr is 32 bytes");

struct FileInfo : public FileInfoCore
{
    // NOTE: ADDITIONAL INFO NOT PERSISTED
    mode_t   mode;       // Runtime only - not persisted to xattr, needed to determine file type

    // Runtime only, and used by replay's sidecar fingerprint store (FingerprintStore.h)
    // rather than by the xattr format:
    //   dev      - the xattr record lives on the file, so the inode alone identifies it.
    //              A record kept beside the cache does not, because inode numbers are
    //              only unique within a device.
    //   ctime_ns - closes the "touch -r restores mtime" wrong skip. utimes() is an inode
    //              metadata change, so POSIX requires it to move ctime, and there is no
    //              portable way to put ctime back. The xattr backend cannot validate on
    //              it: setxattr bumps ctime itself, so its records would invalidate
    //              themselves on every write.
    dev_t    dev;
    int64_t  ctime_ns;

    // Construct from stat structure
    explicit FileInfo(const struct stat& st) noexcept
        : FileInfoCore { .inode = st.st_ino,
                         .size = st.st_size,
                         .mtime_ns = (int64_t)st.st_mtimespec.tv_sec * 1000000000LL + st.st_mtimespec.tv_nsec,
                         .hash = {0} },
          mode(st.st_mode),
          dev(st.st_dev),
          ctime_ns((int64_t)st.st_ctimespec.tv_sec * 1000000000LL + st.st_ctimespec.tv_nsec)
    {
    }

    FileInfo() noexcept = default;
    
    // Helper to check if this represents a non-existent file
    bool is_nonexistent() const noexcept
    {
        return inode == 0 && size == 0 && mtime_ns == 0 && hash.blake3 == UINT64_MAX;
    }
    
    // Helper to check file type
    bool is_symlink() const noexcept
    {
        return S_ISLNK(mode);
    }
    
    bool is_regular_file() const noexcept
    {
        return S_ISREG(mode);
    }
    
    bool is_directory() const noexcept
    {
        return S_ISDIR(mode);
    }
    
    // Helper to mark as non-existent
    void mark_as_nonexistent() noexcept
    {
        inode = 0;
        size = 0;
        mtime_ns = 0;
        hash.blake3 = UINT64_MAX;  // Sentinel value
        mode = 0;
        dev = 0;
        ctime_ns = 0;
    }
};
