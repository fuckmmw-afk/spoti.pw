#include "AISpatialZip.h"
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>
static int u16(FILE *f, uint16_t v) { unsigned char b[2] = {v & 255, v >> 8}; return fwrite(b,1,2,f) == 2; }
static int u32(FILE *f, uint32_t v) { return u16(f,v & 65535) && u16(f,v >> 16); }
int ASZipCreate(const char *dest, const char **paths, const char **names, size_t n) {
    if (n > 65535) return 0;
    FILE *out = fopen(dest,"wb"); if (!out) return 0;
    uint32_t *offsets = calloc(n ? n : 1, sizeof(uint32_t));
    uint32_t *sizes = calloc(n ? n : 1, sizeof(uint32_t));
    uint32_t *crcs = calloc(n ? n : 1, sizeof(uint32_t));
    unsigned char *buf = malloc(65536); int ok = offsets && sizes && crcs && buf;
    for (size_t i=0; ok && i<n; i++) {
        FILE *in = fopen(paths[i],"rb"); if (!in) { ok=0; break; }
        size_t len; uint64_t size=0; uLong crc=crc32(0, Z_NULL, 0);
        while ((len=fread(buf,1,65536,in)) > 0) { crc=crc32(crc,buf,(uInt)len); size+=len; }
        if (ferror(in) || size>UINT32_MAX || ftell(out)>UINT32_MAX || strlen(names[i])>65535) ok=0;
        sizes[i]=(uint32_t)size; crcs[i]=(uint32_t)crc; offsets[i]=(uint32_t)ftell(out); rewind(in);
        uint16_t nameLen=(uint16_t)strlen(names[i]);
        if (ok) ok=u32(out,0x04034b50) && u16(out,20) && u16(out,0x0800) && u16(out,0) && u16(out,0) && u16(out,0) && u32(out,crcs[i]) && u32(out,sizes[i]) && u32(out,sizes[i]) && u16(out,nameLen) && u16(out,0) && fwrite(names[i],1,nameLen,out)==nameLen;
        while (ok && (len=fread(buf,1,65536,in))>0) if (fwrite(buf,1,len,out)!=len) ok=0;
        if (ferror(in)) ok=0;
        fclose(in);
    }
    uint32_t start=(uint32_t)ftell(out);
    for(size_t i=0;ok && i<n;i++) {
        uint16_t len=(uint16_t)strlen(names[i]);
        ok=u32(out,0x02014b50) && u16(out,20) && u16(out,20) && u16(out,0x0800) && u16(out,0) && u16(out,0) && u16(out,0) && u32(out,crcs[i]) && u32(out,sizes[i]) && u32(out,sizes[i]) && u16(out,len) && u16(out,0) && u16(out,0) && u16(out,0) && u16(out,0) && u32(out,0) && u32(out,offsets[i]) && fwrite(names[i],1,len,out)==len;
    }
    uint32_t central=(uint32_t)ftell(out)-start;
    if(ok) ok=u32(out,0x06054b50) && u16(out,0) && u16(out,0) && u16(out,(uint16_t)n) && u16(out,(uint16_t)n) && u32(out,central) && u32(out,start) && u16(out,0);
    if(fclose(out)!=0) ok=0;
    free(offsets); free(sizes); free(crcs); free(buf);
    if(!ok) remove(dest);
    return ok;
}
