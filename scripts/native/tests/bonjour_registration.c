/* Deterministic macOS registration lifecycle tests; no network access. */
#define DNSServiceRegister mock_register
#define DNSServiceSetDispatchQueue mock_set_queue
#define DNSServiceRefDeallocate mock_deallocate
#include "dnssd.c"

struct _DNSServiceRef_t {
    DNSServiceRegisterReply callback;
    void *context;
    dispatch_queue_t queue;
    int sequence;
};
static int scenario, registrations, deallocations, status_count, statuses[4];

static void deliver(void *context) {
    DNSServiceRef ref = context;
    ref->callback(ref, 0, scenario == 2 && ref->sequence == 2 ? kDNSServiceErr_PolicyDenied : 0,
                  "ignored", "ignored", "ignored", ref->context);
}
DNSServiceErrorType mock_register(DNSServiceRef *ref, DNSServiceFlags flags, uint32_t interface,
        const char *name, const char *type, const char *domain, const char *host, uint16_t port,
        uint16_t length, const void *txt, DNSServiceRegisterReply callback, void *context) {
    (void) flags; (void) interface; (void) name; (void) type; (void) domain;
    (void) host; (void) port; (void) length; (void) txt;
    ++registrations;
    if (scenario == 1 && registrations == 1) return kDNSServiceErr_PolicyDenied;
    *ref = calloc(1, sizeof(**ref));
    (*ref)->callback = callback;
    (*ref)->context = context;
    (*ref)->sequence = registrations;
    return 0;
}
DNSServiceErrorType mock_set_queue(DNSServiceRef ref, dispatch_queue_t queue) {
    if (scenario == 3 && ref->sequence == 2) return kDNSServiceErr_BadParam;
    ref->queue = queue;
    dispatch_async_f(queue, ref, deliver);
    return 0;
}
void mock_deallocate(DNSServiceRef ref) {
    if (ref->queue) dispatch_assert_queue(ref->queue);
    ++deallocations;
    free(ref);
}
int utils_hwaddr_raop(char *text, int length, const char *addr, int addr_length) {
    (void) addr; (void) addr_length;
    return snprintf(text, length, "020000000001") >= length ? -1 : 0;
}
int utils_hwaddr_airplay(char *text, int length, const char *addr, int addr_length) {
    (void) addr; (void) addr_length;
    return snprintf(text, length, "02:00:00:00:00:01") >= length ? -1 : 0;
}
static void status(void *context, int error) {
    dnssd_t *dnssd = context;
    dispatch_assert_queue(dnssd->registration_queue);
    assert(status_count < 4);
    statuses[status_count++] = error;
}
static void drain(void *context) { (void) context; }
static void repeated_ready(void *context) {
    dnssd_t *dnssd = context;
    dnssd_registered(dnssd->raop_service, 0, 0, NULL, NULL, NULL, dnssd);
    dnssd_registered(dnssd->airplay_service, 0, 0, NULL, NULL, NULL, dnssd);
}
static void late_failure(void *context) {
    dnssd_t *dnssd = context;
    dnssd_registered(dnssd->airplay_service, 0, kDNSServiceErr_ServiceNotRunning,
                     NULL, NULL, NULL, dnssd);
}
int main(void) {
    for (scenario = 0; scenario < 5; ++scenario) {
        registrations = deallocations = status_count = 0;
        int error = 0;
        char address[6] = {2,0,0,0,0,1};
        dnssd_t *dnssd = dnssd_init("Test", 4, address, 6, &error, 3);
        assert(dnssd && !error);
        dnssd_set_pk(dnssd, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
        dnssd_set_status_callback(dnssd, status, dnssd);
        int first = dnssd_register_raop(dnssd, 7000);
        dispatch_sync_f(dnssd->registration_queue, NULL, drain);
        if (scenario == 1) {
            assert(first == kDNSServiceErr_PolicyDenied && status_count == 1 && statuses[0] == first);
        } else {
            assert(!first && !status_count); /* Never ready with only one registration. */
            int second = dnssd_register_airplay(dnssd, 7001);
            dispatch_sync_f(dnssd->registration_queue, NULL, drain);
            assert(status_count == 1);
            if (scenario == 2) assert(!second && statuses[0] == kDNSServiceErr_PolicyDenied);
            else if (scenario == 3) assert(second == kDNSServiceErr_BadParam && statuses[0] == second);
            else {
                assert(!second && !statuses[0]);
                dispatch_sync_f(dnssd->registration_queue, dnssd, repeated_ready);
                assert(status_count == 1);
                if (scenario == 4) {
                    dispatch_sync_f(dnssd->registration_queue, dnssd, late_failure);
                    assert(status_count == 2 && statuses[1] == kDNSServiceErr_ServiceNotRunning);
                }
            }
        }
        dnssd_destroy(dnssd); /* Also checks pending callback/context teardown. */
        assert(deallocations == (scenario == 1 ? 0 : 2));
    }
    puts("Bonjour lifecycle: 5 scenarios passed (ASan + UBSan)");
    return 0;
}
