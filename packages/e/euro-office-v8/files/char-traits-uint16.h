// std::char_traits<unsigned short> for V8 8.9's inspector, which keeps UTF-16
// text in std::basic_string<uint16_t>. libc++ 19+ no longer provides the
// generic char_traits<T> that made that work (it is only declared now), so the
// specialization is supplied here, with the semantics of the removed generic one.
#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

namespace std {
template <>
struct char_traits<unsigned short> {
  typedef unsigned short char_type;
  typedef unsigned int int_type;
  typedef streamoff off_type;
  typedef streampos pos_type;
  typedef mbstate_t state_type;

  static void assign(char_type& c1, const char_type& c2) noexcept { c1 = c2; }
  static constexpr bool eq(char_type c1, char_type c2) noexcept { return c1 == c2; }
  static constexpr bool lt(char_type c1, char_type c2) noexcept { return c1 < c2; }
  static int compare(const char_type* s1, const char_type* s2, size_t n) {
    for (; n; --n, ++s1, ++s2) {
      if (lt(*s1, *s2)) return -1;
      if (lt(*s2, *s1)) return 1;
    }
    return 0;
  }
  static size_t length(const char_type* s) {
    size_t len = 0;
    for (; !eq(*s, char_type(0)); ++s) ++len;
    return len;
  }
  static const char_type* find(const char_type* s, size_t n, const char_type& a) {
    for (; n; --n) {
      if (eq(*s, a)) return s;
      ++s;
    }
    return nullptr;
  }
  static char_type* move(char_type* s1, const char_type* s2, size_t n) {
    if (n) memmove(s1, s2, n * sizeof(char_type));
    return s1;
  }
  static char_type* copy(char_type* s1, const char_type* s2, size_t n) {
    if (n) memcpy(s1, s2, n * sizeof(char_type));
    return s1;
  }
  static char_type* assign(char_type* s, size_t n, char_type a) {
    char_type* r = s;
    for (; n; --n, ++s) *s = a;
    return r;
  }
  static constexpr char_type to_char_type(int_type c) noexcept { return char_type(c); }
  static constexpr int_type to_int_type(char_type c) noexcept { return int_type(c); }
  static constexpr bool eq_int_type(int_type c1, int_type c2) noexcept { return c1 == c2; }
  static constexpr int_type eof() noexcept { return int_type(0xFFFFFFFF); }
  static constexpr int_type not_eof(int_type c) noexcept { return eq_int_type(c, eof()) ? ~eof() : c; }
};
}  // namespace std
