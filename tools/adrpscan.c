// uso: adrpscan <bin> <hexVA>...   barre __text buscando adrp+add/ldr/str que resuelvan a cada VA
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
int main(int argc,char**argv){
  FILE*f=fopen(argv[1],"rb"); fseek(f,0,SEEK_END); long sz=ftell(f); fseek(f,0,SEEK_SET);
  uint8_t*b=malloc(sz); fread(b,1,sz,f); fclose(f);
  uint64_t base=0x100000000ULL, ts=getenv("TS")?strtoull(getenv("TS"),0,16):0x4000, te=getenv("TE")?strtoull(getenv("TE"),0,16):ts+0xc70906c;
  int n=argc-2; uint64_t t[64]; for(int i=0;i<n;i++) t[i]=strtoull(argv[i+2],0,16);
  for(uint64_t o=ts;o<te;o+=4){
    uint32_t i=*(uint32_t*)(b+o);
    if((i&0x9f000000)!=0x90000000) continue;
    int rd=i&31; int64_t imm=(((i>>5)&0x7ffff)<<2)|((i>>29)&3); if(imm&0x100000) imm-=0x200000;
    uint64_t pg=((base+o)&~0xfffULL)+(imm<<12);
    for(int k=1;k<=8&&o+4*k<te;k++){
      uint32_t j=*(uint32_t*)(b+o+4*k);
      uint64_t v=0; int ok=0;
      if((j&0xffc00000)==0x91000000 && ((j>>5)&31)==rd){ v=pg+((j>>10)&0xfff); ok=1; }
      else if((j&0xffc00000)==0xf9400000 && ((j>>5)&31)==rd){ v=pg+(((j>>10)&0xfff)<<3); ok=1; }
      if(ok) for(int m=0;m<n;m++) if(v==t[m]) printf("%llx -> %llx (+%d)\n",(unsigned long long)(base+o),(unsigned long long)v,k);
    }
  }
}
