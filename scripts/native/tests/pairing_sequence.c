/* Early sequence validation must reject missing state without touching crypto. */
#include "pairing.c"
int main(void) {
    pairing_session_t session = {0};
    pairing_t pairing = {0};
    unsigned char data[512] = {0}, proof[64] = {0}, tag[16] = {0};
    assert(srp_validate_proof(NULL,&pairing,data,32,proof,64,64)<0);
    assert(srp_validate_proof(&session,&pairing,data,32,proof,64,64)<0);
    assert(srp_confirm_pair_setup(NULL,&pairing,data,tag)<0);
    assert(srp_confirm_pair_setup(&session,&pairing,data,tag)<0);
    session.srp = calloc(1,sizeof(srp_t));
    assert(session.srp);
    assert(srp_validate_proof(&session,NULL,data,32,proof,64,64)<0);
    assert(srp_validate_proof(&session,&pairing,NULL,32,proof,64,64)<0);
    assert(srp_validate_proof(&session,&pairing,data,0,proof,64,64)<0);
    assert(srp_validate_proof(&session,&pairing,data,513,proof,64,64)<0);
    assert(srp_validate_proof(&session,&pairing,data,32,NULL,64,64)<0);
    assert(srp_validate_proof(&session,&pairing,data,32,proof,63,64)<0);
    assert(srp_validate_proof(&session,&pairing,data,32,proof,64,63)<0);
    assert(srp_confirm_pair_setup(&session,&pairing,data,tag)<0);
    session.srp->proof_validated = true;
    assert(srp_confirm_pair_setup(&session,NULL,data,tag)<0);
    assert(srp_confirm_pair_setup(&session,&pairing,NULL,tag)<0);
    assert(srp_confirm_pair_setup(&session,&pairing,data,NULL)<0);
    free(session.srp);
    session.srp = NULL;
    unsigned char basepoint[32] = {9}, zero_key[32] = {0}, public_key[32] = {0};
    assert(pairing_session_handshake(&session,basepoint,data)==0);
    assert(pairing_session_get_public_key(&session,public_key)==0);
    assert(pairing_session_handshake(&session,zero_key,data)<0);
    assert(pairing_session_get_public_key(&session,public_key)<0);
    assert(!session.ecdh_ours && !session.ecdh_theirs && !session.ed_theirs);
    assert(memcmp(session.ecdh_secret,zero_key,sizeof(zero_key))==0);
    assert(pairing_session_handshake(NULL,data,data)<0);
    assert(pairing_session_handshake(&session,NULL,data)<0);
    assert(pairing_session_handshake(&session,data,NULL)<0);
    puts("Pairing early sequence: 24 cases passed (ASan + UBSan)");
    return 0;
}
