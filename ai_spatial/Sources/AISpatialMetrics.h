#pragma once
#include <stddef.h>
#include <stdint.h>
typedef struct {
    size_t count, finite, nan, infinity, above_one;
    double sum, squares, minimum, maximum, peak;
} ASMetrics;
void ASMetricsAdd(ASMetrics *m, double value);
ASMetrics ASMeasure(const float *values, size_t count, size_t stride);
double ASRMS(ASMetrics m);
double ASHalfToDouble(uint16_t bits);
size_t ASTensorOffset(size_t index, const size_t *shape, const size_t *strides, size_t rank);
