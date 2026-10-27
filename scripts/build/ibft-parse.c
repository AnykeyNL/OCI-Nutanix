/*
 * ibft-parse.c — print the iSCSI boot settings from the firmware's iBFT table
 *
 * Used inside the CE installer on OCI bare metal (remaster-ce-iso-bm.sh). The
 * installer kernel has no iscsi_ibft driver, so the table is read straight
 * from ACPI: /sys/firmware/acpi/tables/iBFT. Output is shell assignments:
 *   IBFT_INITIATOR IBFT_TARGET IBFT_TARGET_IP IBFT_TARGET_PORT IBFT_LUN
 *   IBFT_MAC IBFT_IP IBFT_PREFIX IBFT_GATEWAY
 * Layout: struct ibft_hdr (6 bytes) / ibft_control / ibft_initiator / ibft_nic /
 * ibft_tgt in linux/drivers/firmware/iscsi_ibft.c (little-endian, packed).
 * IBFT_DEBUG=1 prints the control-structure offsets to stderr.
 *
 * build: gcc -O2 -o ibft-parse ibft-parse.c
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

static unsigned char t[65536];
static size_t n;

static unsigned u16(size_t o) { return o + 1 < n ? t[o] | t[o + 1] << 8 : 0; }

static void ip(const char *var, size_t o)
{
    static const unsigned char v4[12] = {0,0,0,0,0,0,0,0,0,0,0xff,0xff};
    if (o + 16 > n) return;
    if (memcmp(t + o, v4, 12) == 0)
        printf("%s=%u.%u.%u.%u\n", var, t[o+12], t[o+13], t[o+14], t[o+15]);
}

static void str(const char *var, size_t len_o, size_t off_o)
{
    unsigned len = u16(len_o), off = u16(off_o);
    if (!len || off + len > n) return;
    printf("%s='%.*s'\n", var, (int)len, t + off);
}

int main(int argc, char **argv)
{
    const char *path = argc > 1 ? argv[1] : "/sys/firmware/acpi/tables/iBFT";
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return 1; }
    n = fread(t, 1, sizeof t, f);
    fclose(f);
    if (n < 64 || memcmp(t, "iBFT", 4)) { fprintf(stderr, "not an iBFT table\n"); return 1; }
    /* control structure follows the 48-byte ACPI header; every structure
     * starts with a 6-byte ibft_hdr (id, version, u16 length, index, flags) */
    size_t ini = u16(56), nic = u16(58), tgt = u16(60);
    if (getenv("IBFT_DEBUG"))
        fprintf(stderr, "len=%zu control: ext=%u ini=%zu nic=%zu tgt=%zu\n",
            n, u16(54), ini, nic, tgt);
    if (ini) str("IBFT_INITIATOR", ini + 70, ini + 72);
    if (nic) {
        ip("IBFT_IP", nic + 6);
        printf("IBFT_PREFIX=%u\n", t[nic + 22]);
        ip("IBFT_GATEWAY", nic + 24);
        printf("IBFT_MAC=%02x:%02x:%02x:%02x:%02x:%02x\n", t[nic+90], t[nic+91],
               t[nic+92], t[nic+93], t[nic+94], t[nic+95]);
    }
    if (tgt) {
        ip("IBFT_TARGET_IP", tgt + 6);
        printf("IBFT_TARGET_PORT=%u\n", u16(tgt + 22));
        /* SAM LUN, single level: first two bytes big-endian, 14 bits */
        printf("IBFT_LUN=%u\n", ((t[tgt + 24] << 8) | t[tgt + 25]) & 0x3fff);
        str("IBFT_TARGET", tgt + 34, tgt + 36);
    }
    return 0;
}
