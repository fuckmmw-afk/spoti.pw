#include "AISpatialEventExtraction.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

int main(void) {
    ASExtractEvent e = {.event_id=7,.stream_epoch=3,.start_sample=100,.end_sample=300,
        .source=0,.priority=.9f,.intensity=1,.attack_seconds=.01f,.release_seconds=.02f,
        .tail_seconds=.03f,.selected=true};
    assert(ASExtractValidate(&e, 1000, 3, 0));
    assert(ASExtractEnvelope(99, &e, 1000) == 0);
    assert(ASExtractEnvelope(100, &e, 1000) < .1f);
    assert(ASExtractEnvelope(200, &e, 1000) > .9f);
    assert(ASExtractEnvelope(330, &e, 1000) == 0);
    ASExtractEvent other=e; other.event_id=9; other.priority=.1f; other.start_sample=120; other.end_sample=240;
    ASExtractEvent events[2]={e,other}; ASExtractWinner winners[2];
    assert(ASExtractChooseWinners(events,2,180,0,1000,winners,2)==2);
    assert(winners[0].event_id==7 && winners[0].priority > winners[1].priority);
    float inL[4]={1,1,1,1},inR[4]={1,1,1,1},outL[4],outR[4];
    ASExtractForeground(inL,inR,outL,outR,4,100,&e,1000);
    assert(outL[0] < .1f && outL[3] > outL[0]);
    puts("AISpatialEventExtractionTests: OK (envelopes, overlap arbitration, conservative foreground)");
}
