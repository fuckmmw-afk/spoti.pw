#import "AISpatialDiagnostics.h"
#import "AISpatialSeparator.h"
#import <AudioToolbox/AudioToolbox.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <string.h>
#import <stdatomic.h>
static _Atomic(BOOL) gStreamingBridgeActive;
void AISpatialDiagnosticsSetStreamingBridgeActive(BOOL active) { atomic_store_explicit(&gStreamingBridgeActive, active, memory_order_release); }

typedef void (*ASLiveProcessFn)(float *left, float *right, UInt32 frames, double sampleRate, const AudioTimeStamp *timestamp);
typedef BOOL (*ASLiveBridgeActiveFn)(void);
static _Atomic(ASLiveProcessFn) gLiveProcess;
static _Atomic(ASLiveBridgeActiveFn) gLiveBridgeActive;

static void *ASLookupInjectedSymbol(const char *name, const char *imagePart) {
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (symbol) return symbol;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path || !strstr(path, imagePart)) continue;
        void *handle = dlopen(path, RTLD_LAZY | RTLD_NOLOAD);
        if (!handle) continue;
        symbol = dlsym(handle, name);
        if (symbol) return symbol;
    }
    return NULL;
}

static void ASResolveLiveBridge(void) {
    ASLiveProcessFn process = atomic_load_explicit(&gLiveProcess, memory_order_acquire);
    if (!process) {
        process = (ASLiveProcessFn)dlsym(RTLD_DEFAULT, "AISpatialLiveProcessStereo");
        if (process) atomic_store_explicit(&gLiveProcess, process, memory_order_release);
    }
    ASLiveBridgeActiveFn active = atomic_load_explicit(&gLiveBridgeActive, memory_order_acquire);
    if (!active) {
        active = (ASLiveBridgeActiveFn)ASLookupInjectedSymbol("CromaJDSPAIStreamingBridgeActive", "chromajdsp");
        if (active) atomic_store_explicit(&gLiveBridgeActive, active, memory_order_release);
    }
}

// Diagnostics attaches a post-render observer. The normal path is metrics-only;
// when the companion Croma bridge is unavailable, the observer can feed the
// same pre-JamesDSP AI entry point for the common float32 stereo route.
static OSStatus (*gOriginalAudioOutputUnitStart)(AudioUnit);
static AudioStreamBasicDescription gCaptureFormat;

static const struct mach_header_64 *ASMainExecutable(intptr_t *slide) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        if (header && header->magic == MH_MAGIC_64 && header->filetype == MH_EXECUTE) {
            *slide = _dyld_get_image_vmaddr_slide(i);
            return (const struct mach_header_64 *)header;
        }
    }
    return NULL;
}

static BOOL ASWritePointer(void **slot, void *value, BOOL restoreReadOnly) {
    vm_size_t page = vm_page_size;
    vm_address_t start = (vm_address_t)slot & ~(page - 1);
    if (vm_protect(mach_task_self(), start, page, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) return NO;
    *slot = value;
    if (restoreReadOnly) vm_protect(mach_task_self(), start, page, FALSE, VM_PROT_READ);
    return YES;
}

static BOOL ASRebindImport(const char *symbol, void *replacement, void **original) {
    intptr_t slide = 0; const struct mach_header_64 *header = ASMainExecutable(&slide); if (!header) return NO;
    const struct segment_command_64 *linkedit = NULL; const struct symtab_command *symtab = NULL; const struct dysymtab_command *dysymtab = NULL;
    const struct load_command *command = (const struct load_command *)(header + 1);
    for (uint32_t i=0;i<header->ncmds;i++,command=(const struct load_command *)((const char *)command+command->cmdsize)) {
        if(command->cmd==LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)command)->segname,SEG_LINKEDIT)) linkedit=(const struct segment_command_64 *)command;
        else if(command->cmd==LC_SYMTAB) symtab=(const struct symtab_command *)command;
        else if(command->cmd==LC_DYSYMTAB) dysymtab=(const struct dysymtab_command *)command;
    }
    if(!linkedit||!symtab||!dysymtab) return NO;
    uintptr_t base=(uintptr_t)slide+(uintptr_t)(linkedit->vmaddr-linkedit->fileoff);
    const struct nlist_64 *symbols=(const struct nlist_64 *)(base+symtab->symoff); const char *strings=(const char *)(base+symtab->stroff); const uint32_t *indirect=(const uint32_t *)(base+dysymtab->indirectsymoff);
    uint32_t wanted=UINT32_MAX;
    for(uint32_t i=dysymtab->iundefsym;i<dysymtab->iundefsym+dysymtab->nundefsym&&i<symtab->nsyms;i++) { uint32_t offset=symbols[i].n_un.n_strx; if(offset<symtab->strsize&&strings[offset]=='_'&&!strcmp(strings+offset+1,symbol)){wanted=i;break;} }
    if(wanted==UINT32_MAX) return NO;
    BOOL rebound=NO; command=(const struct load_command *)(header+1);
    for(uint32_t i=0;i<header->ncmds;i++,command=(const struct load_command *)((const char *)command+command->cmdsize)) {
        if(command->cmd!=LC_SEGMENT_64) continue; const struct segment_command_64 *segment=(const struct segment_command_64 *)command; BOOL readonly=!strcmp(segment->segname,"__DATA_CONST")||!strcmp(segment->segname,"__AUTH_CONST"); const struct section_64 *section=(const struct section_64 *)(segment+1);
        for(uint32_t s=0;s<segment->nsects;s++,section++) { uint32_t type=section->flags&SECTION_TYPE; if(type!=S_NON_LAZY_SYMBOL_POINTERS&&type!=S_LAZY_SYMBOL_POINTERS) continue; void **slots=(void **)((uintptr_t)slide+section->addr); uint64_t count=section->size/sizeof(void *);
            for(uint64_t k=0;k<count;k++){uint64_t index=(uint64_t)section->reserved1+k; if(index>=dysymtab->nindirectsyms||indirect[index]!=wanted||slots[k]==replacement)continue; void *held=slots[k]; if(ASWritePointer(&slots[k],replacement,readonly)){if(original&&!*original)*original=held;rebound=YES;}}
        }
    }
    return rebound;
}

static void ASCaptureFormat(AudioUnit unit) {
    AudioStreamBasicDescription format={0}; UInt32 size=sizeof(format);
    if(AudioUnitGetProperty(unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,0,&format,&size)!=noErr) return;
    if(format.mFormatID!=kAudioFormatLinearPCM||format.mSampleRate<=0||!format.mChannelsPerFrame) return;
    gCaptureFormat=format;
}
static void ASFormatChanged(void *refCon, AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element) { if(property==kAudioUnitProperty_StreamFormat&&scope==kAudioUnitScope_Output&&element==0) ASCaptureFormat(unit); }
static OSStatus ASRendered(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus, UInt32 frames, AudioBufferList *data) {
    if(!flags||!(*flags&kAudioUnitRenderAction_PostRender)||bus!=0||!data||!frames) return noErr;
    ASLiveProcessFn process = atomic_load_explicit(&gLiveProcess, memory_order_acquire);
    ASLiveBridgeActiveFn bridgeActive = atomic_load_explicit(&gLiveBridgeActive, memory_order_acquire);
    BOOL processedByFallback = NO;
    // The normal path is CromaJDSP's render observer. If that companion hook
    // is absent, feed the common Spotify float32/non-interleaved stereo route
    // through the same AI entry point here. AISpatialLiveProcessStereo has a
    // timestamp/frame dedupe guard, so an older bridge cannot double-process a
    // block when both observers happen to be installed.
    BOOL splitFloat32 = (gCaptureFormat.mFormatFlags & kAudioFormatFlagIsFloat) &&
                        (gCaptureFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) &&
                        gCaptureFormat.mBitsPerChannel == 32 && data->mNumberBuffers >= 2 &&
                        data->mBuffers[0].mData && data->mBuffers[1].mData;
    if (process && (!bridgeActive || !bridgeActive()) && splitFloat32) {
        process((float *)data->mBuffers[0].mData, (float *)data->mBuffers[1].mData, frames, gCaptureFormat.mSampleRate, timestamp);
        AISpatialLiveRecordTerminalStereo((float *)data->mBuffers[0].mData,
                                           (float *)data->mBuffers[1].mData,
                                           frames, gCaptureFormat.mSampleRate);
        processedByFallback = YES;
    }
    if (!processedByFallback && !atomic_load_explicit(&gStreamingBridgeActive, memory_order_acquire)) AISpatialDiagnosticsCapturePCM(data,frames,&gCaptureFormat,timestamp);
    return noErr;
}
static void ASAttach(AudioUnit unit) {
    if(!unit) return; AudioComponentDescription description={0}; if(AudioComponentGetDescription(AudioComponentInstanceGetComponent(unit),&description)!=noErr||description.componentType!=kAudioUnitType_Output||description.componentSubType!=kAudioUnitSubType_RemoteIO)return;
    ASCaptureFormat(unit); AudioUnitRemovePropertyListenerWithUserData(unit,kAudioUnitProperty_StreamFormat,ASFormatChanged,NULL); AudioUnitAddPropertyListener(unit,kAudioUnitProperty_StreamFormat,ASFormatChanged,NULL); AudioUnitRemoveRenderNotify(unit,ASRendered,NULL); AudioUnitAddRenderNotify(unit,ASRendered,NULL);
}
static OSStatus ASStart(AudioUnit unit) { ASResolveLiveBridge(); OSStatus status=gOriginalAudioOutputUnitStart?gOriginalAudioOutputUnitStart(unit):-1; if(status==noErr) ASAttach(unit); return status; }
__attribute__((constructor)) static void AISpatialInstallRealtimeCapture(void) {
    // This function is in the same tweak. Keep a direct pointer so the
    // compatibility path still works when the injected image is RTLD_LOCAL
    // and RTLD_DEFAULT cannot discover its own exported symbol.
    atomic_store_explicit(&gLiveProcess, AISpatialLiveProcessStereo, memory_order_release);
    ASResolveLiveBridge();
    if(!ASRebindImport("AudioOutputUnitStart",(void *)ASStart,(void **)&gOriginalAudioOutputUnitStart)) {
        AISpatialDiagnosticsSetRealtimeCaptureHookAvailable(NO);
        NSLog(@"[ai-spatial] realtime PCM diagnostics hook unavailable; offline metrics remain available");
    } else {
        AISpatialDiagnosticsSetRealtimeCaptureHookAvailable(YES);
        NSLog(@"[ai-spatial] post-render PCM diagnostics observer installed; capture activates only while Diagnostics is recording");
    }
}
