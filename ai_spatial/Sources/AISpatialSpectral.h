#import <CoreML/CoreML.h>
#import <Accelerate/Accelerate.h>
// Shared Stage 01 implementation; streaming uses the same routines unchanged.
void AISpatialFillSpectrum(MLMultiArray *array, const float *left, const float *right, NSUInteger channel, NSUInteger length);
void AISpatialInverseWindow(MLMultiArray *source, NSUInteger channel, float *output, NSUInteger length, FFTSetup setup, const float *window);
