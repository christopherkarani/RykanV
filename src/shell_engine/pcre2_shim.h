#pragma once
#include <stddef.h>

typedef struct ryk_regex ryk_regex;

ryk_regex *ryk_regex_compile(const char *pattern, size_t len, int *err_code, size_t *err_offset);
void ryk_regex_free(ryk_regex *re);

/* Match result contract (security-sensitive — must not collapse errors to no-match):
 *   1  = match
 *   0  = no match (PCRE2_ERROR_NOMATCH only)
 *  <0  = infrastructure / match error (caller must fail closed)
 */
int ryk_regex_is_match(ryk_regex *re, const char *text, size_t len);

/* Same contract as ryk_regex_is_match. On match (return 1), writes the full-match
 * byte span [start, end) into *out_start / *out_end when non-NULL.
 * On no-match or error, out offsets are left unchanged.
 */
int ryk_regex_match_span(
    ryk_regex *re,
    const char *text,
    size_t len,
    size_t *out_start,
    size_t *out_end);
