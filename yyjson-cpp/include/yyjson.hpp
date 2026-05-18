//
//  yyjson.hpp
//  Header-only C++20 wrappers for yyjson (read-only / query API).
//
//  Design notes:
//    - Val is a non-owning handle; Document owns the parsed memory.
//    - Typed getters return std::optional — nullopt means absent or wrong type.
//    - get_str() / obj_get() / arr_get() return string_view / Val backed by the
//      Document's arena; do not use them after the Document is destroyed.
//    - parse_file(std::string_view) copies the path to a std::string because
//      yyjson_read_file requires a null-terminated C string.
//

#pragma once

#include "yyjson.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

namespace Json {

// ---------------------------------------------------------------------------
// Val — lightweight non-owning handle to a single parsed JSON node.
// ---------------------------------------------------------------------------

class Val {
public:
    Val() noexcept : val_(nullptr) {}
    explicit Val(yyjson_val *v) noexcept : val_(v) {}

    bool valid() const noexcept { return val_ != nullptr; }
    explicit operator bool() const noexcept { return val_ != nullptr; }

    // Type predicates
    bool is_null() const noexcept { return val_ != nullptr && yyjson_is_null(val_); }
    bool is_bool() const noexcept { return val_ != nullptr && yyjson_is_bool(val_); }
    bool is_sint() const noexcept { return val_ != nullptr && yyjson_is_sint(val_); }
    bool is_uint() const noexcept { return val_ != nullptr && yyjson_is_uint(val_); }
    bool is_int()  const noexcept { return val_ != nullptr && yyjson_is_int(val_);  }
    bool is_real() const noexcept { return val_ != nullptr && yyjson_is_real(val_); }
    bool is_num()  const noexcept { return val_ != nullptr && yyjson_is_num(val_);  }
    bool is_str()  const noexcept { return val_ != nullptr && yyjson_is_str(val_);  }
    bool is_arr()  const noexcept { return val_ != nullptr && yyjson_is_arr(val_);  }
    bool is_obj()  const noexcept { return val_ != nullptr && yyjson_is_obj(val_);  }

    // Value extractors — nullopt when absent or wrong type.
    // get_str() returns a view into the Document's arena; lifetime follows the Document.
    std::optional<bool>             get_bool() const noexcept;
    std::optional<int64_t>          get_sint() const noexcept;
    std::optional<uint64_t>         get_uint() const noexcept;
    // get_num() accepts any numeric node (int or real) and returns a double.
    std::optional<double>           get_num()  const noexcept;
    // get_real() accepts only floating-point nodes (excludes integers).
    std::optional<double>           get_real() const noexcept;
    std::optional<std::string_view> get_str()  const noexcept;

    // Object key lookup — returns an invalid Val on miss or if this is not an object.
    Val obj_get(std::string_view key) const noexcept;

    // Array element access by index — returns invalid Val on out-of-range or non-array.
    Val    arr_get(size_t idx) const noexcept;
    size_t arr_size()          const noexcept;
    size_t obj_size()          const noexcept;

    yyjson_val *raw() const noexcept { return val_; }

private:
    yyjson_val *val_;
};

// ---------------------------------------------------------------------------
// ArrIter / ObjIter — forward iterators over arrays and objects.
// ---------------------------------------------------------------------------

class ArrIter {
public:
    // Precondition: arr.is_arr() must be true.
    explicit ArrIter(Val arr) noexcept { yyjson_arr_iter_init(arr.raw(), &iter_); }

    bool has_next() noexcept { return yyjson_arr_iter_has_next(&iter_); }
    Val  next()     noexcept { return Val{yyjson_arr_iter_next(&iter_)}; }

private:
    yyjson_arr_iter iter_{};
};

class ObjIter {
public:
    // Precondition: obj.is_obj() must be true.
    explicit ObjIter(Val obj) noexcept { yyjson_obj_iter_init(obj.raw(), &iter_); }

    bool has_next() noexcept { return yyjson_obj_iter_has_next(&iter_); }

    // Advances the iterator and returns the key node; call val(key) for the value.
    Val next_key() noexcept { return Val{yyjson_obj_iter_next(&iter_)}; }

    // Returns the value paired with a key returned by next_key().
    static Val val(Val key) noexcept { return Val{yyjson_obj_iter_get_val(key.raw())}; }

private:
    yyjson_obj_iter iter_{};
};

// ---------------------------------------------------------------------------
// Document — RAII owner of a fully parsed yyjson document.
// ---------------------------------------------------------------------------

class Document {
public:
    Document() noexcept : doc_(nullptr) {}
    explicit Document(yyjson_doc *doc) noexcept : doc_(doc) {}
    ~Document() { if (doc_ != nullptr) yyjson_doc_free(doc_); }

    Document(const Document &) = delete;
    Document &operator=(const Document &) = delete;

    Document(Document &&o) noexcept : doc_(o.doc_) { o.doc_ = nullptr; }
    Document &operator=(Document &&o) noexcept
    {
        if (this != &o)
        {
            if (doc_ != nullptr)
                yyjson_doc_free(doc_);
            doc_ = o.doc_;
            o.doc_ = nullptr;
        }
        return *this;
    }

    bool valid() const noexcept { return doc_ != nullptr; }
    explicit operator bool() const noexcept { return doc_ != nullptr; }

    Val root() const noexcept
    {
        if (doc_ == nullptr)
            return Val{};
        return Val{yyjson_doc_get_root(doc_)};
    }

    yyjson_doc *raw() const noexcept { return doc_; }

private:
    yyjson_doc *doc_;
};

// ---------------------------------------------------------------------------
// Factory functions
// ---------------------------------------------------------------------------

// Parse JSON from a string_view (yyjson copies the buffer; json does not need
// to outlive the returned Document).
inline Document parse(std::string_view json,
                      yyjson_read_flag flags = YYJSON_READ_NOFLAG,
                      yyjson_read_err *err   = nullptr) noexcept
{
    // yyjson_read_opts signature takes char* but does not modify the buffer
    // when YYJSON_READ_INSITU is not set.
    char *buf = const_cast<char *>(json.data());
    return Document{yyjson_read_opts(buf, json.size(), flags, nullptr, err)};
}

// Parse JSON from a null-terminated file path.
inline Document parse_file(const char *path,
                            yyjson_read_flag flags = YYJSON_READ_NOFLAG,
                            yyjson_read_err *err   = nullptr) noexcept
{
    return Document{yyjson_read_file(path, flags, nullptr, err)};
}

// Parse JSON from a file path expressed as a string_view (may not be
// null-terminated, so a std::string copy is made for the C API).
inline Document parse_file(std::string_view path,
                            yyjson_read_flag flags = YYJSON_READ_NOFLAG,
                            yyjson_read_err *err   = nullptr)
{
    std::string p(path);
    return Document{yyjson_read_file(p.c_str(), flags, nullptr, err)};
}

// ---------------------------------------------------------------------------
// Val inline method implementations
// ---------------------------------------------------------------------------

inline std::optional<bool> Val::get_bool() const noexcept
{
    if (val_ == nullptr || !yyjson_is_bool(val_))
        return std::nullopt;
    return yyjson_get_bool(val_);
}

inline std::optional<int64_t> Val::get_sint() const noexcept
{
    if (val_ == nullptr || !yyjson_is_sint(val_))
        return std::nullopt;
    return yyjson_get_sint(val_);
}

inline std::optional<uint64_t> Val::get_uint() const noexcept
{
    if (val_ == nullptr || !yyjson_is_uint(val_))
        return std::nullopt;
    return yyjson_get_uint(val_);
}

inline std::optional<double> Val::get_num() const noexcept
{
    if (val_ == nullptr || !yyjson_is_num(val_))
        return std::nullopt;
    return yyjson_get_num(val_);
}

inline std::optional<double> Val::get_real() const noexcept
{
    if (val_ == nullptr || !yyjson_is_real(val_))
        return std::nullopt;
    return yyjson_get_real(val_);
}

inline std::optional<std::string_view> Val::get_str() const noexcept
{
    if (val_ == nullptr || !yyjson_is_str(val_))
        return std::nullopt;
    return std::string_view{yyjson_get_str(val_), yyjson_get_len(val_)};
}

inline Val Val::obj_get(std::string_view key) const noexcept
{
    if (val_ == nullptr || !yyjson_is_obj(val_))
        return Val{};
    return Val{yyjson_obj_getn(val_, key.data(), key.size())};
}

inline Val Val::arr_get(size_t idx) const noexcept
{
    if (val_ == nullptr || !yyjson_is_arr(val_))
        return Val{};
    return Val{yyjson_arr_get(val_, idx)};
}

inline size_t Val::arr_size() const noexcept
{
    if (val_ == nullptr || !yyjson_is_arr(val_))
        return 0;
    return yyjson_arr_size(val_);
}

inline size_t Val::obj_size() const noexcept
{
    if (val_ == nullptr || !yyjson_is_obj(val_))
        return 0;
    return yyjson_obj_size(val_);
}

// ---------------------------------------------------------------------------
// MutableVal — non-owning handle to a mutable yyjson node (owned by MutableDoc).
// ---------------------------------------------------------------------------

class MutableVal {
public:
    MutableVal() noexcept : val_(nullptr) {}
    explicit MutableVal(yyjson_mut_val *v) noexcept : val_(v) {}
    bool valid()   const noexcept { return val_ != nullptr; }
    explicit operator bool() const noexcept { return val_ != nullptr; }
    yyjson_mut_val *raw() const noexcept { return val_; }
private:
    yyjson_mut_val *val_;
};

// ---------------------------------------------------------------------------
// MutableDoc — RAII owner of a mutable yyjson document (JSON builder).
//
// All Val objects produced by a MutableDoc are owned by that document's
// internal allocator and must not outlive it.
// ---------------------------------------------------------------------------

class MutableDoc {
public:
    MutableDoc() noexcept : doc_(yyjson_mut_doc_new(nullptr)) {}
    ~MutableDoc() noexcept { if (doc_ != nullptr) yyjson_mut_doc_free(doc_); }

    MutableDoc(const MutableDoc &) = delete;
    MutableDoc &operator=(const MutableDoc &) = delete;
    MutableDoc(MutableDoc &&o) noexcept : doc_(o.doc_) { o.doc_ = nullptr; }
    MutableDoc &operator=(MutableDoc &&o) noexcept
    {
        if (this != &o)
        {
            if (doc_ != nullptr) yyjson_mut_doc_free(doc_);
            doc_ = o.doc_;
            o.doc_ = nullptr;
        }
        return *this;
    }

    bool valid() const noexcept { return doc_ != nullptr; }

    // Scalar constructors — memory owned by this document.
    MutableVal new_null()           noexcept { return MutableVal{yyjson_mut_null(doc_)}; }
    MutableVal new_bool(bool v)     noexcept { return MutableVal{yyjson_mut_bool(doc_, v)}; }
    MutableVal new_sint(int64_t v)  noexcept { return MutableVal{yyjson_mut_sint(doc_, v)}; }
    MutableVal new_uint(uint64_t v) noexcept { return MutableVal{yyjson_mut_uint(doc_, v)}; }
    MutableVal new_real(double v)   noexcept { return MutableVal{yyjson_mut_real(doc_, v)}; }
    MutableVal new_obj()            noexcept { return MutableVal{yyjson_mut_obj(doc_)}; }
    MutableVal new_arr()            noexcept { return MutableVal{yyjson_mut_arr(doc_)}; }

    // Copies sv into the document allocator — safe for temporaries and string_views.
    MutableVal new_str(std::string_view sv) noexcept
    {
        return MutableVal{yyjson_mut_strncpy(doc_, sv.data(), sv.size())};
    }

    // Embeds raw JSON verbatim without parsing or escaping.
    // Copies sv so the caller's string need not outlive this document.
    // Useful for preserving JSON-RPC ids (numbers, strings, null) as-is.
    MutableVal new_raw(std::string_view sv) noexcept
    {
        return MutableVal{yyjson_mut_rawncpy(doc_, sv.data(), sv.size())};
    }

    // Add key->val pair to an object.  The key string is copied.
    bool obj_add(MutableVal obj, std::string_view key, MutableVal val) noexcept
    {
        MutableVal k = new_str(key);
        if (!k.valid() || !val.valid()) return false;
        return yyjson_mut_obj_add(obj.raw(), k.raw(), val.raw());
    }

    // Append val to an array.
    bool arr_append(MutableVal arr, MutableVal val) noexcept
    {
        if (!arr.valid() || !val.valid()) return false;
        return yyjson_mut_arr_append(arr.raw(), val.raw());
    }

    void set_root(MutableVal val) noexcept
    {
        yyjson_mut_doc_set_root(doc_, val.raw());
    }

    // Serialize to std::string (compact by default). Returns empty on error.
    std::string to_string(yyjson_write_flag flags = YYJSON_WRITE_NOFLAG) const noexcept
    {
        size_t len = 0;
        std::unique_ptr<char, decltype(&free)> json(
            yyjson_mut_write(doc_, flags, &len), free);
        if (json == nullptr) return {};
        return std::string(json.get(), len);
    }

    yyjson_mut_doc *raw_doc() const noexcept { return doc_; }

private:
    yyjson_mut_doc *doc_;
};

} // namespace Json
