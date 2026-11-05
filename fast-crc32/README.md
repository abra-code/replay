# Fast CRC32

CRC32C hash source code generated for arm64 and x86_64 from work of Peter Cawley:
https://github.com/corsix/fast-crc32

The generated source code files are redistributed here without modifications.

## Regenerating

`generate-variants.sh` downloads the generator (`generate.c`) at a pinned upstream commit, checks its SHA-256, builds it in a temporary folder and writes every variant this folder uses, named `ab_<isa>_crc32c_<algorithm>.c`. `generate-variants.sh --check` compares instead of writing. The list of variants and the reason for each is in the script.

## License

Fast CRC32 is offered under the MIT or the zlib license, at the user's choice (the generated files say "MIT or zlib licensed"). This copy uses the MIT license:

* [MIT License](./LICENSE.md)
