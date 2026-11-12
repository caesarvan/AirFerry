#include <stdint.h>
#include <stddef.h>
void *airferry_receiver_create(uint64_t, uint64_t);
void airferry_receiver_destroy(void *);
uint64_t airferry_receiver_ingest(void *, const uint8_t *, size_t);
int32_t airferry_receiver_assemble(void *, uint8_t **, size_t *);
void airferry_buffer_free(uint8_t *, size_t);
size_t airferry_receiver_file_name(const void *, uint8_t *, size_t);
size_t airferry_receiver_progress_json(const void *, uint8_t *, size_t);
uint64_t airferry_receiver_file_size(const void *);
uint64_t airferry_receiver_crc32(const void *);
int32_t airferry_receiver_crc32_known(const void *);
int32_t airferry_receiver_is_segmented(const void *);
int32_t airferry_receiver_assemble_raw(void *, uint8_t **, size_t *);
uint32_t airferry_receiver_segment_index(const void *);
uint32_t airferry_receiver_segment_count(const void *);
uint64_t airferry_receiver_root_original_size(const void *);
uint64_t airferry_receiver_root_session_id_lo(const void *);
uint64_t airferry_receiver_root_session_id_hi(const void *);
uint64_t airferry_receiver_compressed_size(const void *);
uint8_t airferry_receiver_compression(const void *);
size_t airferry_receiver_raw_sha256(const void *, uint8_t *, size_t);
size_t airferry_receiver_root_sha256(const void *, uint8_t *, size_t);
int32_t airferry_decompress_stream_to_file(const char *, const char *, uint8_t, uint64_t, uint64_t, uint32_t, _Bool, const char *);
