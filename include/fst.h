#ifndef FST_H
#define FST_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Thread safety:
 *   - A single global mutex protects ALL C API calls for their entire
 *     duration. Concurrent calls from multiple threads are safe — the mutex
 *     serializes them and prevents use-after-free / dangling pointer races.
 *   - fst_teardown() also acquires the mutex; however, the caller MUST
 *     ensure no other API calls are in flight (i.e. call at quiescent time).
 *   - MutableFst semantics: single-writer. Do NOT mutate the same handle
 *     from multiple threads simultaneously.
 *   - Fst (frozen) queries are fully reentrant and thread-safe.
 */

/* Handle types — opaque u32 indices into internal tables.
 * Prevents double-free, use-after-free, and type confusion. */
typedef uint32_t FstMutableHandle;
typedef uint32_t FstHandle;

/* Error codes */
typedef enum {
    FST_OK = 0,
    FST_OOM = 1,
    FST_INVALID_ARG = 2,
    FST_INVALID_STATE = 3,
    FST_IO_ERROR = 4,
} FstError;

/* Closure types */
typedef enum {
    FST_CLOSURE_STAR = 0,
    FST_CLOSURE_PLUS = 1,
    FST_CLOSURE_QUES = 2,
} FstClosureType;

/* C-compatible arc struct */
typedef struct {
    uint32_t ilabel;
    uint32_t olabel;
    double weight;
    uint32_t nextstate;
} FstArc;

/* Sentinel values */
#define FST_NO_STATE UINT32_MAX
#define FST_EPSILON 0
#define FST_INVALID_HANDLE UINT32_MAX

/* --- MutableFst lifecycle --- */
FstMutableHandle fst_mutable_new(void);
void fst_mutable_free(FstMutableHandle handle);
uint32_t fst_mutable_add_state(FstMutableHandle handle);
FstError fst_mutable_set_start(FstMutableHandle handle, uint32_t state);
FstError fst_mutable_set_final(FstMutableHandle handle, uint32_t state, double weight);
FstError fst_mutable_add_arc(FstMutableHandle handle, uint32_t src,
                              uint32_t ilabel, uint32_t olabel,
                              double weight, uint32_t nextstate);

/* --- MutableFst query --- */
uint32_t fst_mutable_start(FstMutableHandle handle);
uint32_t fst_mutable_num_states(FstMutableHandle handle);
uint32_t fst_mutable_num_arcs(FstMutableHandle handle, uint32_t state);
double fst_mutable_final_weight(FstMutableHandle handle, uint32_t state);
uint32_t fst_mutable_get_arcs(FstMutableHandle handle, uint32_t state,
                               FstArc* buf, uint32_t buf_len);

/* --- Freeze: MutableFst -> Fst --- */
FstHandle fst_freeze(FstMutableHandle mutable_handle);

/* --- Fst (immutable) lifecycle --- */
void fst_free(FstHandle handle);
uint32_t fst_start(FstHandle handle);
uint32_t fst_num_states(FstHandle handle);
uint32_t fst_num_arcs(FstHandle handle, uint32_t state);
double fst_final_weight(FstHandle handle, uint32_t state);
uint32_t fst_get_arcs(FstHandle handle, uint32_t state,
                       FstArc* buf, uint32_t buf_len);

/* --- I/O --- */
FstMutableHandle fst_read_text(const char* path);
FstHandle fst_load(const char* path);
FstError fst_save(FstHandle handle, const char* path);

/* --- Operations (MutableFst -> MutableFst) --- */
FstMutableHandle fst_compose(FstMutableHandle a, FstMutableHandle b);
FstMutableHandle fst_determinize(FstMutableHandle handle);
FstError fst_minimize(FstMutableHandle handle);
FstMutableHandle fst_rm_epsilon(FstMutableHandle handle);
FstMutableHandle fst_shortest_path(FstMutableHandle handle, uint32_t n);
FstError fst_union(FstMutableHandle a, FstMutableHandle b);
FstError fst_concat(FstMutableHandle a, FstMutableHandle b);
FstError fst_closure(FstMutableHandle handle, int type);
void fst_invert(FstMutableHandle handle);
FstMutableHandle fst_optimize(FstMutableHandle handle);
FstMutableHandle fst_cdrewrite(FstMutableHandle tau,
                                FstMutableHandle lambda,
                                FstMutableHandle rho,
                                FstMutableHandle sigma);
FstMutableHandle fst_difference(FstMutableHandle a, FstMutableHandle b);
FstMutableHandle fst_replace(FstMutableHandle root,
                              const uint32_t* labels,
                              const FstMutableHandle* fsts,
                              uint32_t num_pairs);
void fst_project(FstMutableHandle handle, int side);  /* 0=input, 1=output */

/* --- String utilities --- */
FstMutableHandle fst_compile_string(const uint8_t* input, uint32_t len);
int32_t fst_print_string(FstMutableHandle handle, uint8_t* buf, uint32_t buf_len);

/* --- Global teardown --- */
void fst_teardown(void);

#ifdef __cplusplus
}
#endif

#endif /* FST_H */
