#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
int main(int argc,char**argv){
  FILE*f=fopen(argv[1],"rb"); fseek(f,0,SEEK_END); long sz=ftell(f); fseek(f,0,SEEK_SET);
  uint8_t*b=malloc(sz); fread(b,1,sz,f); fclose(f);
  uint64_t base=0x100000000ULL, ts=0x4000, te=ts+0xc70906c;
  for(uint64_t o=ts;o<te;o+=4){
    uint32_t i=*(uint32_t*)(b+o);
    if((i&0xfc000000)!=0x94000000 && (i&0xfc000000)!=0x14000000) continue;
    int64_t imm=i&0x3ffffff; if(imm&0x2000000) imm-=0x4000000;
    uint64_t t=base+o+imm*4;
    for(int m=2;m<argc;m++) if(t==strtoull(argv[m],0,16)) printf("%llx %s %s\n",(unsigned long long)(base+o),(i>>31)?"bl":"b",argv[m]);
  }
}
