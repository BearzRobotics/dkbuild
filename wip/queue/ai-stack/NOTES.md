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

## Update 2026-11-15: the RAG libraries

Written: llama-index 0.14.26 (the meta package: core, OpenAI LLM and embeddings, readers, workflows), haystack-ai 3.5.0 and
langchain 1.5.0 (with langchain-core and langgraph), each with the pydeps store (`files/python.lock` made by
`dkbuild python-lock` from what pip resolves: 82, 50 and 48 lines; the pure-Python wheels, plus greenlet and xxhash that
compile). The compiled dependencies that the tree already has (numpy, pillow, pydantic-core, pyyaml, markupsafe, regex,
rpds-py, zstandard) are left out of the locks and named as build and run dependencies; the Rust ones that it does not
have are packages of their own (python-jiter, python-tiktoken, python-orjson, python-ormsgpack, python-uuid-utils:
cargodeps, like python-pydantic-core). These integrations call remote model APIs (OpenAI and others) by default: with the
local stack (ollama, llama.cpp, fastembed, qdrant) the user points them at local endpoints. langchain-community and the
other langchain integrations are not included (install what is needed with pip into a venv, or ask for them).

## Update 2026-11-15: PyTorch and docling written

Written: pytorch 2.15.0 (CPU; bundled third_party; the biggest risk of the queue: musl and libc++ patches probably needed,
6 hours to build), python-transformers, python-sentence-transformers, python-torchvision (CPU), and the docling chain:
python-docling, python-docling-core, python-docling-parse (C++, pybind11, qpdf), python-docling-ibm-models,
python-pypdfium2 (bound to the system pdfium) and **pdfium**, which is the project's PREBUILT musl x86_64 library
(bblanchon/pdfium-binaries, Chromium 8152, pinned): a source build needs a Chromium gclient checkout (the
"snapshot" work in wip/README.md); this is the pragmatic first step. Also libspatialindex + python-rtree,
python-openpyxl (+ et-xmlfile), python-typer, python-marko, python-latex2mathml (wheels where the sdist needs an unpackaged
build backend). docling's OCR engines (easyocr, rapidocr, tesseract bindings) are not included: they are optional.
Still not written: apache-tika (Java/Maven), MinerU, kotaemon, Verba, danswer/Onyx, RAG-Anything, the legal RAG repos.
