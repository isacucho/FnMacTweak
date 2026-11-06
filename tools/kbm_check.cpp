// Uso: kbm_check <FortniteClient-IOS-Shipping> [--patch <salida>]
// Aplica kbm_scan.hpp al Mach-O del juego y dice donde esta el sitio a parchear. Con --patch
// escribe una copia con `mov w0,#1` (hay que volver a firmar). Build:
//   clang++ -std=c++17 -O2 -I../includes kbm_check.cpp -o kbm_check
#include "fndiag/kbm_scan.hpp"

#include <fcntl.h>
#include <mach-o/loader.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "uso: %s <binario> [--patch <salida>]\n", argv[0]);
        return 2;
    }
    int fd = open(argv[1], O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0) {
        perror("open");
        return 1;
    }
    const uint8_t *b = (const uint8_t *)mmap(nullptr, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    auto *mh = (const mach_header_64 *)b;
    if (mh->magic != MH_MAGIC_64) {
        fprintf(stderr, "no es un Mach-O 64 bits delgado\n");
        return 1;
    }
    const section_64 *text = nullptr, *ustr = nullptr;
    const uint8_t *p = b + sizeof(mach_header_64);
    for (uint32_t c = 0; c < mh->ncmds; c++) {
        auto *lc = (const load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            auto *seg = (const segment_command_64 *)p;
            auto *s = (const section_64 *)(seg + 1);
            for (uint32_t k = 0; k < seg->nsects; k++, s++) {
                if (!strcmp(s->segname, "__TEXT") && !strcmp(s->sectname, "__text"))
                    text = s;
                if (!strcmp(s->segname, "__TEXT") && !strcmp(s->sectname, "__ustring"))
                    ustr = s;
            }
        } else if (lc->cmd == LC_UUID) {
            auto *u = (const uuid_command *)p;
            printf("uuid ");
            for (int i = 0; i < 16; i++)
                printf("%02X%s", u->uuid[i], (i == 3 || i == 5 || i == 7 || i == 9) ? "-" : "");
            printf("\n");
        }
        p += lc->cmdsize;
    }
    if (!text || !ustr) {
        fprintf(stderr, "faltan __text o __ustring\n");
        return 1;
    }
    auto lits = fndiag::kbm::find_wide_literal(b + ustr->offset, ustr->size, ustr->addr, fndiag::kbm::kMouseSettingsReason);
    printf("literales: %zu\n", lits.size());
    std::vector<size_t> sites;
    for (uint64_t lva : lits) {
        auto s = fndiag::kbm::find_bl_before_literal((const uint32_t *)(b + text->offset), text->size / 4, text->addr, lva);
        sites.insert(sites.end(), s.begin(), s.end());
    }
    for (size_t w : sites)
        printf("sitio va=0x%llx fileoff=0x%llx\n", (unsigned long long)(text->addr + w * 4), (unsigned long long)(text->offset + w * 4));
    if (sites.size() != 1) {
        fprintf(stderr, "se esperaba exactamente 1 sitio, hay %zu\n", sites.size());
        return 1;
    }
    if (argc >= 4 && !strcmp(argv[2], "--patch")) {
        FILE *out = fopen(argv[3], "wb");
        if (!out || fwrite(b, 1, st.st_size, out) != (size_t)st.st_size) {
            perror("escribir");
            return 1;
        }
        fseek(out, (long)(text->offset + sites[0] * 4), SEEK_SET);
        uint32_t w = fndiag::kbm::kMovW0One;
        fwrite(&w, 4, 1, out);
        fclose(out);
        chmod(argv[3], 0755);
        printf("parcheado: %s\n", argv[3]);
    }
    return 0;
}
