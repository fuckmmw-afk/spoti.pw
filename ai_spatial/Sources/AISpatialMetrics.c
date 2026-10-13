#include "AISpatialMetrics.h"
#include <math.h>
void ASMetricsAdd(ASMetrics *m, double v) {
    m->count++;
    if (isnan(v)) { m->nan++; return; }
    if (isinf(v)) { m->infinity++; return; }
    if (!m->finite) m->minimum = m->maximum = v;
    m->finite++;
    if (v < m->minimum) m->minimum = v;
    if (v > m->maximum) m->maximum = v;
    if (fabs(v) > m->peak) m->peak = fabs(v);
    if (fabs(v) > 1) m->above_one++;
    m->sum += v; m->squares += v * v;
}
ASMetrics ASMeasure(const float *values, size_t count, size_t stride) {
    ASMetrics m = {0};
    if (values) for (size_t i = 0; i < count; i++) ASMetricsAdd(&m, values[i * stride]);
    return m;
}
double ASRMS(ASMetrics m) { return m.finite ? sqrt(m.squares / m.finite) : 0; }
double ASHalfToDouble(uint16_t b) {
    int exponent = (b >> 10) & 31;
    double value;
    if (exponent == 31) value = (b & 1023) ? NAN : INFINITY;
    else if (!exponent) value = ldexp((double)(b & 1023), -24);
    else value = ldexp(1.0 + (double)(b & 1023) / 1024.0, exponent - 15);
    return (b & 0x8000) ? -value : value;
}
size_t ASTensorOffset(size_t index, const size_t *shape, const size_t *strides, size_t rank) {
    size_t offset = 0;
    for (size_t d = rank; d > 0; d--) {
        if (!shape[d - 1]) return 0;
        offset += (index % shape[d - 1]) * strides[d - 1];
        index /= shape[d - 1];
    }
    return offset;
}
