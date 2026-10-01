/*
 * insert_dylib — add LC_LOAD_DYLIB to a Mach-O binary (thin or FAT)
 *
 * Usage: insert_dylib <binary> <dylib_path>
 *
 * Inserts a new LC_LOAD_DYLIB load command pointing to <dylib_path> into every
 * arm64/arm64e slice of <binary>. Modifies the file in-place. Safe to run
 * multiple times — skips if the dylib is already present. After patching,
 * re-sign with ldid -S and add to trustcache via jbctl trust.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>

static int patch_slice(uint8_t *base, size_t slice_off, size_t slice_size,
                       const char *dylib_path) {
    uint8_t *p = base + slice_off;
    uint32_t magic = *(uint32_t *)p;

    int is64;
    if (magic == MH_MAGIC_64)
        is64 = 1;
    else if (magic == MH_MAGIC)
        is64 = 0;
    else {
        fprintf(stderr, "  skip: not a Mach-O slice (magic 0x%x)\n", magic);
        return 0;
    }

    uint32_t header_size = is64 ? sizeof(struct mach_header_64)
                                : sizeof(struct mach_header);
    struct mach_header_64 *hdr = (struct mach_header_64 *)p;

    uint32_t ncmds      = hdr->ncmds;
    uint32_t sizeofcmds = hdr->sizeofcmds;
    uint32_t lc_offset  = header_size;

    /* walk load commands — check if already inserted */
    for (uint32_t i = 0; i < ncmds; i++) {
        struct load_command *lc = (struct load_command *)(p + lc_offset);
        if (lc->cmd == LC_LOAD_DYLIB || lc->cmd == LC_LOAD_WEAK_DYLIB) {
            struct dylib_command *dc = (struct dylib_command *)(p + lc_offset);
            const char *name = (const char *)dc + dc->dylib.name.offset;
            if (strcmp(name, dylib_path) == 0) {
                fprintf(stderr, "  already present, skipping\n");
                return 0;
            }
        }
        lc_offset += lc->cmdsize;
    }

    /* build the new LC_LOAD_DYLIB */
    uint32_t name_offset = sizeof(struct dylib_command);
    uint32_t path_len    = (uint32_t)strlen(dylib_path) + 1;
    uint32_t raw_size    = name_offset + path_len;
    /* align to pointer size */
    uint32_t align       = is64 ? 8 : 4;
    uint32_t cmdsize     = (raw_size + align - 1) & ~(align - 1);

    /* check padding: space between end of load commands and first section */
    uint32_t end_of_lcs = header_size + sizeofcmds;
    uint32_t first_section_off = (uint32_t)slice_size;

    lc_offset = header_size;
    for (uint32_t i = 0; i < ncmds; i++) {
        struct load_command *lc = (struct load_command *)(p + lc_offset);
        if (is64 && lc->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg =
                (struct segment_command_64 *)(p + lc_offset);
            struct section_64 *sec =
                (struct section_64 *)((uint8_t *)seg +
                                      sizeof(struct segment_command_64));
            for (uint32_t j = 0; j < seg->nsects; j++) {
                if (sec[j].offset > 0 && sec[j].offset < first_section_off)
                    first_section_off = sec[j].offset;
            }
        } else if (!is64 && lc->cmd == LC_SEGMENT) {
            struct segment_command *seg =
                (struct segment_command *)(p + lc_offset);
            struct section *sec =
                (struct section *)((uint8_t *)seg +
                                   sizeof(struct segment_command));
            for (uint32_t j = 0; j < seg->nsects; j++) {
                if (sec[j].offset > 0 && sec[j].offset < first_section_off)
                    first_section_off = sec[j].offset;
            }
        }
        lc_offset += lc->cmdsize;
    }

    uint32_t available = first_section_off - end_of_lcs;
    if (cmdsize > available) {
        fprintf(stderr,
                "  ERROR: not enough header padding (%u avail, need %u)\n",
                available, cmdsize);
        return -1;
    }

    /* write the new load command */
    uint8_t *dest = p + end_of_lcs;
    memset(dest, 0, cmdsize);

    struct dylib_command *dc = (struct dylib_command *)dest;
    dc->cmd                 = LC_LOAD_DYLIB;
    dc->cmdsize             = cmdsize;
    dc->dylib.name.offset   = name_offset;
    dc->dylib.timestamp      = 0;
    dc->dylib.current_version       = 0;
    dc->dylib.compatibility_version = 0;
    memcpy(dest + name_offset, dylib_path, path_len);

    /* update header */
    hdr->ncmds      = ncmds + 1;
    hdr->sizeofcmds = sizeofcmds + cmdsize;

    fprintf(stderr, "  inserted LC_LOAD_DYLIB -> %s (cmdsize %u)\n",
            dylib_path, cmdsize);
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "Usage: %s <binary> <dylib_path>\n", argv[0]);
        return 1;
    }

    const char *binary_path = argv[1];
    const char *dylib_path  = argv[2];

    int fd = open(binary_path, O_RDWR);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    struct stat st;
    fstat(fd, &st);
    size_t file_size = st.st_size;

    uint8_t *base = mmap(NULL, file_size, PROT_READ | PROT_WRITE, MAP_SHARED,
                         fd, 0);
    if (base == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }

    uint32_t magic = *(uint32_t *)base;
    int patched = 0;

    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        /* FAT binary */
        int swap = (magic == FAT_CIGAM);
        struct fat_header *fh = (struct fat_header *)base;
        uint32_t nfat = swap ? __builtin_bswap32(fh->nfat_arch) : fh->nfat_arch;
        struct fat_arch *archs =
            (struct fat_arch *)(base + sizeof(struct fat_header));

        for (uint32_t i = 0; i < nfat; i++) {
            uint32_t offset = swap ? __builtin_bswap32(archs[i].offset)
                                   : archs[i].offset;
            uint32_t size   = swap ? __builtin_bswap32(archs[i].size)
                                   : archs[i].size;
            uint32_t cputype = swap ? __builtin_bswap32(archs[i].cputype)
                                    : archs[i].cputype;

            fprintf(stderr, "FAT slice %u: cputype 0x%x offset %u size %u\n",
                    i, cputype, offset, size);

            int r = patch_slice(base, offset, size, dylib_path);
            if (r > 0) patched++;
            if (r < 0) { munmap(base, file_size); close(fd); return 1; }
        }
    } else {
        /* thin binary */
        fprintf(stderr, "thin binary\n");
        int r = patch_slice(base, 0, file_size, dylib_path);
        if (r > 0) patched++;
        if (r < 0) { munmap(base, file_size); close(fd); return 1; }
    }

    msync(base, file_size, MS_SYNC);
    munmap(base, file_size);
    close(fd);

    if (patched > 0)
        fprintf(stderr, "patched %d slice(s)\n", patched);
    else
        fprintf(stderr, "no slices patched\n");

    return 0;
}
