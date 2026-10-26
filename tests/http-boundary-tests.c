#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "http_request.h"
static int cases;
static http_request_t *parse(const char *s, size_t n, size_t chunk) {
    http_request_t *r = http_request_init(); assert(r);
    for (size_t i=0; i<n && !http_request_has_error(r);) {
        size_t take = n-i < chunk ? n-i : chunk;
        http_request_add_data(r, s+i, (int)take); i+=take;
    }
    return r;
}
static void valid(const char *s, size_t chunk, const char *protocol) {
    http_request_t *r=parse(s,strlen(s),chunk);
    assert(!http_request_has_error(r)); assert(http_request_is_complete(r));
    assert(!strcmp(http_request_get_protocol(r),protocol)); http_request_destroy(r); cases++;
}
static void sized_url(size_t count, int expected_error) {
    char *s=calloc(count+100,1); strcpy(s,"OPTIONS /"); memset(s+9,'a',count-1);
    strcpy(s+8+count," RTSP/1.0\r\nCSeq: 1\r\n\r\n");
    http_request_t*r=parse(s,strlen(s),7); assert(!!http_request_has_error(r)==expected_error);
    http_request_destroy(r);free(s);cases++;
}
static void sized_header(size_t count,int expected_error) {
    char *s=calloc(count+100,1); strcpy(s,"OPTIONS / RTSP/1.0\r\nX:"); size_t off=strlen(s);
    memset(s+off,'a',count-1);strcpy(s+off+count-1,"\r\n\r\n");
    http_request_t*r=parse(s,strlen(s),13); assert(!!http_request_has_error(r)==expected_error);
    http_request_destroy(r);free(s);cases++;
}
static void sized_body(size_t count,int expected_error) {
    char *s=calloc(count+200,1); int off=snprintf(s,200,"POST /pair-setup HTTP/1.1\r\nHost: localhost\r\nContent-Length: %zu\r\n\r\n",count);
    memset(s+off,'b',count); http_request_t*r=parse(s,off+count,257);
    assert(!!http_request_has_error(r)==expected_error);
    if(!expected_error){int len=0;assert(http_request_is_complete(r));assert(http_request_get_data(r,&len));assert((size_t)len==count);}
    http_request_destroy(r);free(s);cases++;
}
int main(void){
    valid("OPTIONS / RTSP/1.0\r\nCSeq: 1\r\n\r\n",1,"RTSP/1.0");
    valid("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\nabc",2,"HTTP/1.1");
    sized_url(8192,0);sized_url(8193,1);
    sized_header(32768,0);sized_header(32769,1);
    sized_body(1048576,0);sized_body(1048577,1);
    printf("PASS: %d HTTP boundary and fragmented protocol cases\n",cases);
}
