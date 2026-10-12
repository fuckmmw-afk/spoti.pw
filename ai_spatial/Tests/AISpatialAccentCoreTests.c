#include "../Sources/AISpatialAccentCore.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void attack_test(void) {
    ASAccentFrame f[50] = {0};
    for (size_t i = 0; i < 50; i++) { f[i].sample = i * 882; f[i].rms = .08f; f[i].flux = .01f; f[i].high_frequency = .02f; }
    f[20].rms = .8f; f[20].peak = 1.0f; f[20].flux = .7f; f[20].high_frequency = .4f;
    ASAccentCoreContext c; ASAccentCoreReset(&c); ASAccentCoreEvent e[8];
    size_t n = ASAccentCoreAnalyze(f, 50, 44100, 882, ASAccentSourceVocal, 0, 200000, &c, e, 8);
    assert(n > 0); assert(e[0].source == ASAccentSourceVocal); assert(e[0].selected);
}

static void repetition_test(void) {
    ASAccentFrame f[150] = {0};
    for (size_t i = 0; i < 150; i++) { f[i].sample = i * 882; f[i].rms = .06f; f[i].flux = .01f; }
    for (size_t i = 10; i < 150; i += 25) { f[i].rms = .7f; f[i].peak = .8f; f[i].flux = .8f; }
    ASAccentCoreContext c; ASAccentCoreReset(&c); ASAccentCoreEvent e[16];
    size_t n = ASAccentCoreAnalyze(f, 150, 44100, 882, ASAccentSourceInstrumental, 0, 500000, &c, e, 16);
    unsigned selected = 0, rejected = 0;
    for (size_t i = 0; i < n; i++) { selected += e[i].selected; rejected += !e[i].selected; }
    assert(selected >= 1 && rejected >= 1);
}

static void deadline_test(void) {
    ASAccentFrame f[20] = {0};
    for (size_t i = 0; i < 20; i++) { f[i].sample = i * 882; f[i].rms = .1f; f[i].flux = .01f; }
    f[8].rms = .9f; f[8].flux = .9f;
    ASAccentCoreContext c; ASAccentCoreReset(&c); ASAccentCoreEvent e[8];
    size_t n = ASAccentCoreAnalyze(f, 20, 44100, 882, ASAccentSourceVocal, 1000000, 1000, &c, e, 8);
    assert(n > 0 && !e[0].selected && strstr(e[0].reason, "late") != NULL);
}

int main(void) { attack_test(); repetition_test(); deadline_test(); puts("AISpatialAccentCoreTests: OK"); return 0; }
