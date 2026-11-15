# Document search and AI stack: status of the queue (2026-11-15)

Requested in four priorities (docs/requests.md). Written in `wip/queue/packages` (not built):

- Search infrastructure: pgvector, sqlite-vec, tantivy-cli (the `tantivy` program), qdrant (with its
  pinned web UI, inert dinit service, listening on 127.0.0.1 only). sqlite itself has FTS5 on already.
- AI infrastructure: onnxruntime (C++ library + Python module; Alpine's patches; the fetched
  dependencies of its CMake pinned as sources; RISK: this tree's protobuf 35.1 and abseil 2026 are newer than
  what 1.30 was written for), python-huggingface-hub (+ python-fsspec; without hf-xet), python-safetensors,
  python-tokenizers, python-py-rust-stemmers, python-mmh3, python-loguru, python-protobuf, python-fastembed
  (the pure-Python wheel: its sdist needs `uv_build`, not packaged).

Not written, and why:
- **sentence-transformers** needs PyTorch (CPU build): `torch` is a very large C++ build (about 6 hours
  here), needs the release tarball with its submodules (pytorch-vX.tar.gz), oneDNN, sleef, protobuf, pybind11,
  numpy; plus `transformers` (huggingface), scikit-learn (in the tree), scipy (in the tree), pillow.
  Decision still open (docs/requests.md): CPU only, Vulkan, or skip. Then transformers and sentence-transformers.
- **docling** (PDF/document conversion): docling-core, docling-parse (C++), docling-ibm-models (torch),
  pypdfium2 (needs PDFium, which is unwritten: the gclient checkout), easyocr/rapidocr: after PyTorch and PDFium.
- **apache-tika** (Java): the server jar from a Maven build (gradledeps/mavendeps), or the released
  tika-server standard jar as a prebuilt: to decide (the tree builds from source where it can).
- **llama-index, haystack, langchain**: pure Python with many dependencies (the pydeps store with a lock
  file: `dkbuild python-lock` on a uv.lock or requirements); written when the base is there.
- **MinerU, kotaemon, Verba, danswer/Onyx, RAG-Anything** and the legal RAG repos: applications on top of the
  above (torch, vector databases, web UIs); see docs/requests.md.
