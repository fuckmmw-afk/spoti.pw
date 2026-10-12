#pragma once
#include <stddef.h>
// Stored ZIP, streamed in 64 KiB chunks; no audio-sized in-memory archive.
int ASZipCreate(const char *destination, const char **paths, const char **names, size_t count);
