## nginx_adapters.nim
##
## Comprehensive callback-based stream adapters for the nginx async backend.
##
## These adapters follow the pattern of chronos_adapters.nim but do not
## depend on any external async library. Instead, I/O operations delegate
## to user-provided callbacks and return lightweight Futures that complete
## synchronously.
##
## The actual nginx FFI (ngx_create_temp_buf, ngx_http_output_filter, etc.)
## stays in the downstream module (ngx-isonim). These adapters are generic
## "callback-based streams with Future support" that can be tested without
## nginx headers.
##
## Stream types provided:
##   - NginxOutputStream         — HTTP response output (flush/close callbacks)
##   - NginxInputStream          — Generic callback-based input
##   - NginxRequestBodyStream    — HTTP request body input (buffer chain)
##   - NginxUpstreamResponseStream — Upstream/proxy response input (chunked)
##   - NginxFileInputStream      — File reading (offset-based callback)
##   - NginxFileOutputStream     — File writing (callback-based)
##   - NginxConnection           — Bidirectional socket I/O pair
##   - nginxSubrequestInput      — Subrequest capture (alias for request body)

import
  std/options,
  inputs, outputs, buffers, async_backend

export
  inputs, outputs, async_backend

{.pragma: iocall, nimcall, gcsafe, raises: [IOError].}

# =============================================================================
# Callback type definitions
# =============================================================================

type
  # --- Output callbacks ---
  FlushCallback* = proc (data: openArray[byte]) {.gcsafe, raises: [IOError].}
    ## Called when the stream is flushed with all buffered data since the
    ## last flush. The callback is responsible for sending the data (e.g.
    ## via ngx_http_output_filter).

  CloseCallback* = proc () {.gcsafe, raises: [IOError].}
    ## Called when an output stream is closed. The callback should send the
    ## final response marker (e.g. last_buf in nginx).

  # --- Generic input callbacks ---
  ReadCallback* = proc (buf: pointer, maxLen: Natural): Natural
      {.gcsafe, raises: [IOError].}
    ## Read up to `maxLen` bytes into `buf`. Returns bytes actually read.
    ## 0 = EOF.

  ReadCloseCallback* = proc () {.gcsafe, raises: [IOError].}
    ## Called when an input stream is closed, for cleanup.

  # --- Request body callbacks ---
  BodyChunk* = object
    ## A single buffer in a chain (maps to an ngx_buf_t in a chain).
    data*: pointer
    len*: Natural

  RequestBodyCallback* = proc (): seq[BodyChunk]
      {.gcsafe, raises: [IOError].}
    ## Returns the chain of body buffers. Empty seq = no body or EOF.
    ## Maps to ngx_http_read_client_request_body → post_handler →
    ## r->request_body->bufs pattern.

  # --- Upstream response callbacks ---
  UpstreamChunkCallback* = proc (): BodyChunk
      {.gcsafe, raises: [IOError].}
    ## Called to read the next chunk of upstream response data.
    ## Returns (nil, 0) for EOF. Maps to the upstream input_filter model.

  # --- File I/O callbacks ---
  FileReadCallback* = proc (buf: pointer, size: Natural, offset: int64): Natural
      {.gcsafe, raises: [IOError].}
    ## Read `size` bytes from file at `offset` into `buf`.
    ## Returns bytes read. 0 = EOF. Maps to ngx_read_file.

  FileCloseCallback* = proc () {.gcsafe, raises: [IOError].}
    ## Called when a file stream is closed.

  FileWriteCallback* = proc (buf: pointer, size: Natural)
      {.gcsafe, raises: [IOError].}
    ## Write `size` bytes from `buf` to file at current position.
    ## Maps to ngx_write_file / ngx_write_chain_to_temp_file.

  # --- Connection callbacks ---
  ConnReadCallback* = proc (buf: pointer, size: Natural): Natural
      {.gcsafe, raises: [IOError].}
    ## Returns bytes read. 0 = EOF.
    ## Maps to c->recv(c, buf, size) — transparent to SSL.

  ConnWriteCallback* = proc (buf: pointer, size: Natural): Natural
      {.gcsafe, raises: [IOError].}
    ## Returns bytes written. Maps to c->send(c, buf, size).

  ConnCloseCallback* = proc () {.gcsafe, raises: [IOError].}
    ## Called when a connection is closed.

# =============================================================================
# Section 1: NginxOutputStream — HTTP response output
# =============================================================================

type
  NginxOutputStream* = ref object of OutputStream
    internalBuf: seq[byte]
    flushCb: FlushCallback
    closeCb: CloseCallback

proc appendToInternalBuf(ns: NginxOutputStream, src: pointer, srcLen: Natural) =
  if srcLen == 0:
    return
  let oldLen = ns.internalBuf.len
  ns.internalBuf.setLen(oldLen + srcLen)
  copyMem(addr ns.internalBuf[oldLen], src, srcLen)

proc drainInternalBuf(ns: NginxOutputStream) =
  ## Drain all completed pages from the PageBuffers into the internal buffer,
  ## then clear them.
  if ns.buffers != nil:
    for span in ns.buffers.consumeAll():
      let spanLen = span.len
      if spanLen > 0:
        let oldLen = ns.internalBuf.len
        ns.internalBuf.setLen(oldLen + spanLen)
        copyMem(addr ns.internalBuf[oldLen], span.startAddr, spanLen)

proc writeNginxSync(s: OutputStream, src: pointer, srcLen: Natural)
    {.iocall.} =
  let ns = NginxOutputStream(s)
  # Drain any pending page buffers first
  ns.drainInternalBuf()
  # Then append the new data
  ns.appendToInternalBuf(src, srcLen)

proc writeNginxAsync(s: OutputStream, src: pointer, srcLen: Natural): Future[void]
    {.iocall.} =
  writeNginxSync(s, src, srcLen)
  result = newFuture[void]("writeNginxAsync")
  fsTranslateErrors "Unexpected exception from merely completing a future":
    result.complete()

proc flushNginxSync(s: OutputStream)
    {.iocall.} =
  let ns = NginxOutputStream(s)
  ns.drainInternalBuf()
  if ns.internalBuf.len > 0 and ns.flushCb != nil:
    ns.flushCb(ns.internalBuf)
    ns.internalBuf.setLen(0)

proc flushNginxAsync(s: OutputStream): Future[void]
    {.iocall.} =
  flushNginxSync(s)
  result = newFuture[void]("flushNginxAsync")
  fsTranslateErrors "Unexpected exception from merely completing a future":
    result.complete()

proc closeNginxSync(s: OutputStream)
    {.iocall.} =
  let ns = NginxOutputStream(s)
  # Flush remaining data first
  ns.drainInternalBuf()
  if ns.internalBuf.len > 0 and ns.flushCb != nil:
    ns.flushCb(ns.internalBuf)
    ns.internalBuf.setLen(0)
  # Signal close
  if ns.closeCb != nil:
    ns.closeCb()

proc closeNginxAsync(s: OutputStream): Future[void]
    {.iocall.} =
  closeNginxSync(s)
  result = newFuture[void]("closeNginxAsync")
  fsTranslateErrors "Unexpected exception from merely completing a future":
    result.complete()

const nginxOutputVTable* = OutputStreamVTable(
  writeSync: writeNginxSync,
  writeAsync: writeNginxAsync,
  flushSync: flushNginxSync,
  flushAsync: flushNginxAsync,
  closeSync: closeNginxSync,
  closeAsync: closeNginxAsync,
)

proc nginxOutput*(flushCb: FlushCallback,
                  closeCb: CloseCallback = nil,
                  pageSize = defaultPageSize): OutputStreamHandle =
  ## Creates an OutputStream backed by an internal byte buffer with
  ## callback-based flush and close.
  ##
  ## `flushCb` is called with the accumulated data when the stream is
  ## flushed. `closeCb` is called when the stream is closed (after any
  ## remaining data has been flushed via `flushCb`).
  makeHandle NginxOutputStream(
    vtable: vtableAddr nginxOutputVTable,
    buffers: PageBuffers.init(pageSize),
    internalBuf: @[],
    flushCb: flushCb,
    closeCb: closeCb,
  )

proc getInternalBuf*(s: OutputStream): lent seq[byte] =
  ## Access the internal buffer of a NginxOutputStream (for testing).
  NginxOutputStream(s).internalBuf

# =============================================================================
# Section 2: NginxInputStream — Generic callback-based input
# =============================================================================

type
  NginxInputStream* = ref object of InputStream
    readCb: ReadCallback
    closeCb: ReadCloseCallback

proc readNginxInputSync(s: InputStream, dst: pointer, dstLen: Natural): Natural
    {.iocall.} =
  let ns = NginxInputStream(s)
  implementSingleRead(s.buffers, dst, dstLen,
                      ReadFlags {},
                      readStartAddr, readLen):
    ns.readCb(readStartAddr, readLen)

proc readNginxInputAsync(s: InputStream, dst: pointer, dstLen: Natural): Future[Natural]
    {.iocall.} =
  let bytesRead = readNginxInputSync(s, dst, dstLen)
  result = newFuture[Natural]("readNginxInputAsync")
  fsTranslateErrors "Unexpected exception from merely completing a future":
    result.complete(bytesRead)

proc closeNginxInputSync(s: InputStream)
    {.iocall.} =
  let ns = NginxInputStream(s)
  if ns.closeCb != nil:
    ns.closeCb()

proc closeNginxInputAsync(s: InputStream): Future[void]
    {.iocall.} =
  closeNginxInputSync(s)
  result = newFuture[void]("closeNginxInputAsync")
  fsTranslateErrors "Unexpected exception from merely completing a future":
    result.complete()

const nginxInputVTable* = InputStreamVTable(
  readSync: readNginxInputSync,
  readAsync: readNginxInputAsync,
  closeSync: closeNginxInputSync,
  closeAsync: closeNginxInputAsync,
)

proc nginxInput*(readCb: ReadCallback,
                 closeCb: ReadCloseCallback = nil,
                 pageSize = defaultPageSize): InputStreamHandle =
  ## Creates an InputStream backed by a read callback.
  ##
  ## `readCb` is called to read up to `maxLen` bytes into the provided
  ## buffer. It returns the number of bytes actually read. Returning 0
  ## signals EOF.
  ##
  ## `closeCb` is called when the stream is closed, for cleanup.
  makeHandle NginxInputStream(
    vtable: vtableAddr nginxInputVTable,
    buffers: PageBuffers.init(pageSize),
    readCb: readCb,
    closeCb: closeCb,
  )

# =============================================================================
# Section 3: NginxRequestBodyStream — HTTP request body input (buffer chain)
# =============================================================================

type
  NginxRequestBodyStream = ref object of InputStream
    bodyCb: RequestBodyCallback
    closeCb: ReadCloseCallback
    chunks: seq[BodyChunk]
    chunkIdx: int
    chunkOffset: int
    chunksLoaded: bool

proc loadChunksIfNeeded(ns: NginxRequestBodyStream) =
  if not ns.chunksLoaded:
    ns.chunks = ns.bodyCb()
    ns.chunkIdx = 0
    ns.chunkOffset = 0
    ns.chunksLoaded = true

proc readRequestBodySync(s: InputStream, dst: pointer, dstLen: Natural): Natural
    {.iocall.} =
  let ns = NginxRequestBodyStream(s)
  ns.loadChunksIfNeeded()

  implementSingleRead(s.buffers, dst, dstLen,
                      ReadFlags {},
                      readStartAddr, readLen):
    # Copy data from the chunk chain into the read buffer
    var
      totalCopied: Natural = 0
      dstPos = cast[ptr byte](readStartAddr)

    while totalCopied < readLen and ns.chunkIdx < ns.chunks.len:
      let chunk = ns.chunks[ns.chunkIdx]
      let available = chunk.len - ns.chunkOffset
      let toCopy = min(available, readLen - totalCopied)

      if toCopy > 0 and chunk.data != nil:
        copyMem(dstPos, cast[ptr byte](cast[uint](chunk.data) + uint(ns.chunkOffset)), toCopy)
        dstPos = cast[ptr byte](cast[uint](dstPos) + uint(toCopy))
        totalCopied += toCopy
        ns.chunkOffset += toCopy

      if ns.chunkOffset >= chunk.len:
        inc ns.chunkIdx
        ns.chunkOffset = 0

    totalCopied

proc readRequestBodyAsync(s: InputStream, dst: pointer, dstLen: Natural): Future[Natural]
    {.iocall.} =
  let bytesRead = readRequestBodySync(s, dst, dstLen)
  result = newFuture[Natural]("readRequestBodyAsync")
  fsTranslateErrors "Unexpected exception from merely completing a future":
    result.complete(bytesRead)

proc closeRequestBodySync(s: InputStream)
    {.iocall.} =
  let ns = NginxRequestBodyStream(s)
  if ns.closeCb != nil:
    ns.closeCb()

proc closeRequestBodyAsync(s: InputStream): Future[void]
    {.iocall.} =
  closeRequestBodySync(s)
  result = newFuture[void]("closeRequestBodyAsync")
  fsTranslateErrors "Unexpected exception from merely completing a future":
    result.complete()

const nginxRequestBodyVTable* = InputStreamVTable(
  readSync: readRequestBodySync,
  readAsync: readRequestBodyAsync,
  closeSync: closeRequestBodySync,
  closeAsync: closeRequestBodyAsync,
)

proc nginxRequestBodyInput*(bodyCb: RequestBodyCallback;
                            closeCb: ReadCloseCallback = nil;
                            pageSize = defaultPageSize): InputStreamHandle =
  ## Creates an InputStream that reads from an HTTP request body buffer chain.
  ##
  ## `bodyCb` is called once to get the full body as a sequence of
  ## (pointer, length) pairs representing the buffer chain. The stream
  ## then reads sequentially through the chunks.
  ##
  ## This maps to the ngx_http_read_client_request_body -> post_handler ->
  ## r->request_body->bufs pattern.
  makeHandle NginxRequestBodyStream(
    vtable: vtableAddr nginxRequestBodyVTable,
    buffers: PageBuffers.init(pageSize),
    bodyCb: bodyCb,
    closeCb: closeCb,
    chunksLoaded: false,
  )

# =============================================================================
# Section 4: NginxUpstreamResponseStream — Upstream response input (chunked)
# =============================================================================

type
  NginxUpstreamResponseStream = ref object of InputStream
    chunkCb: UpstreamChunkCallback
    closeCb: ReadCloseCallback
    currentChunk: BodyChunk
    chunkOffset: int
    eof: bool

proc readUpstreamSync(s: InputStream, dst: pointer, dstLen: Natural): Natural
    {.iocall.} =
  let ns = NginxUpstreamResponseStream(s)

  implementSingleRead(s.buffers, dst, dstLen,
                      ReadFlags {},
                      readStartAddr, readLen):
    var
      totalCopied: Natural = 0
      dstPos = cast[ptr byte](readStartAddr)

    while totalCopied < readLen and not ns.eof:
      # Fetch a new chunk if the current one is exhausted
      let available = ns.currentChunk.len - ns.chunkOffset
      if available == 0:
        ns.currentChunk = ns.chunkCb()
        ns.chunkOffset = 0
        if ns.currentChunk.data == nil and ns.currentChunk.len == 0:
          ns.eof = true
          break

      let chunkAvail = ns.currentChunk.len - ns.chunkOffset
      let toCopy = min(chunkAvail, readLen - totalCopied)

      if toCopy > 0 and ns.currentChunk.data != nil:
        copyMem(dstPos, cast[ptr byte](cast[uint](ns.currentChunk.data) + uint(ns.chunkOffset)), toCopy)
        dstPos = cast[ptr byte](cast[uint](dstPos) + uint(toCopy))
        totalCopied += toCopy
        ns.chunkOffset += toCopy

    totalCopied

proc readUpstreamAsync(s: InputStream, dst: pointer, dstLen: Natural): Future[Natural]
    {.iocall.} =
  let bytesRead = readUpstreamSync(s, dst, dstLen)
  result = newFuture[Natural]("readUpstreamAsync")
  fsTranslateErrors "Unexpected exception from merely completing a future":
    result.complete(bytesRead)

proc closeUpstreamSync(s: InputStream)
    {.iocall.} =
  let ns = NginxUpstreamResponseStream(s)
  if ns.closeCb != nil:
    ns.closeCb()

proc closeUpstreamAsync(s: InputStream): Future[void]
    {.iocall.} =
  closeUpstreamSync(s)
  result = newFuture[void]("closeUpstreamAsync")
  fsTranslateErrors "Unexpected exception from merely completing a future":
    result.complete()

const nginxUpstreamResponseVTable* = InputStreamVTable(
  readSync: readUpstreamSync,
  readAsync: readUpstreamAsync,
  closeSync: closeUpstreamSync,
  closeAsync: closeUpstreamAsync,
)

proc nginxUpstreamResponseInput*(chunkCb: UpstreamChunkCallback;
                                  closeCb: ReadCloseCallback = nil;
                                  pageSize = defaultPageSize): InputStreamHandle =
  ## Creates an InputStream for reading upstream/proxy response data.
  ##
  ## `chunkCb` is called repeatedly to get the next chunk of data.
  ## It returns a BodyChunk; (nil, 0) signals EOF.
  ## This maps to the upstream input_filter callback model.
  makeHandle NginxUpstreamResponseStream(
    vtable: vtableAddr nginxUpstreamResponseVTable,
    buffers: PageBuffers.init(pageSize),
    chunkCb: chunkCb,
    closeCb: closeCb,
    eof: false,
  )

# =============================================================================
# Section 5: NginxUpstreamRequestStream — Build upstream request via output
# =============================================================================

proc nginxUpstreamRequestOutput*(flushCb: FlushCallback;
                                  closeCb: CloseCallback = nil;
                                  pageSize = defaultPageSize): OutputStreamHandle =
  ## Creates an OutputStream for building upstream request data.
  ##
  ## This is a named alias for `nginxOutput` — the caller wires the flush
  ## callback to append to r->upstream->request_bufs.
  nginxOutput(flushCb, closeCb, pageSize)

# =============================================================================
# Section 6: NginxFileInputStream — File reading (offset-based callback)
# =============================================================================

type
  NginxFileInputStream = ref object of InputStream
    fileReadCb: FileReadCallback
    fileCloseCb: FileCloseCallback
    fileSize: int64
    fileOffset: int64

proc readNginxFileSync(s: InputStream, dst: pointer, dstLen: Natural): Natural
    {.iocall.} =
  let ns = NginxFileInputStream(s)

  implementSingleRead(s.buffers, dst, dstLen,
                      {partialReadIsEof},
                      readStartAddr, readLen):
    let remaining = ns.fileSize - ns.fileOffset
    if remaining <= 0:
      Natural(0)
    else:
      let toRead = min(readLen, Natural(remaining))
      let bytesRead = ns.fileReadCb(readStartAddr, toRead, ns.fileOffset)
      ns.fileOffset += int64(bytesRead)
      bytesRead

proc readNginxFileAsync(s: InputStream, dst: pointer, dstLen: Natural): Future[Natural]
    {.iocall.} =
  let bytesRead = readNginxFileSync(s, dst, dstLen)
  result = newFuture[Natural]("readNginxFileAsync")
  fsTranslateErrors "Unexpected exception from merely completing a future":
    result.complete(bytesRead)

proc closeNginxFileSync(s: InputStream)
    {.iocall.} =
  let ns = NginxFileInputStream(s)
  if ns.fileCloseCb != nil:
    ns.fileCloseCb()

proc closeNginxFileAsync(s: InputStream): Future[void]
    {.iocall.} =
  closeNginxFileSync(s)
  result = newFuture[void]("closeNginxFileAsync")
  fsTranslateErrors "Unexpected exception from merely completing a future":
    result.complete()

proc getNginxFileLen(s: InputStream): Option[Natural]
    {.iocall.} =
  let ns = NginxFileInputStream(s)
  let remaining = ns.fileSize - ns.fileOffset
  if remaining >= 0:
    some Natural(remaining)
  else:
    some Natural(0)

const nginxFileInputVTable* = InputStreamVTable(
  readSync: readNginxFileSync,
  readAsync: readNginxFileAsync,
  closeSync: closeNginxFileSync,
  closeAsync: closeNginxFileAsync,
  getLenSync: getNginxFileLen,
)

proc nginxFileInput*(readCb: FileReadCallback;
                     fileSize: int64;
                     closeCb: FileCloseCallback = nil;
                     pageSize = defaultPageSize): InputStreamHandle =
  ## Creates an InputStream for reading file data via callbacks.
  ##
  ## `readCb` is called with (buf, size, offset) to read data from the file.
  ## `fileSize` is the total file size (used for EOF detection and len).
  ## Maps to ngx_read_file.
  makeHandle NginxFileInputStream(
    vtable: vtableAddr nginxFileInputVTable,
    buffers: PageBuffers.init(pageSize),
    fileReadCb: readCb,
    fileCloseCb: closeCb,
    fileSize: fileSize,
    fileOffset: 0,
  )

# =============================================================================
# Section 7: NginxFileOutputStream — File writing (callback-based)
# =============================================================================

type
  NginxFileOutputStream = ref object of OutputStream
    internalBuf: seq[byte]
    fileWriteCb: FileWriteCallback
    fileCloseCb: CloseCallback

proc writeNginxFileSync(s: OutputStream, src: pointer, srcLen: Natural)
    {.iocall.} =
  let ns = NginxFileOutputStream(s)
  if ns.buffers != nil:
    for span in ns.buffers.consumeAll():
      let spanLen = span.len
      if spanLen > 0:
        let oldLen = ns.internalBuf.len
        ns.internalBuf.setLen(oldLen + spanLen)
        copyMem(addr ns.internalBuf[oldLen], span.startAddr, spanLen)
  if srcLen > 0:
    let oldLen = ns.internalBuf.len
    ns.internalBuf.setLen(oldLen + srcLen)
    copyMem(addr ns.internalBuf[oldLen], src, srcLen)

proc writeNginxFileAsync(s: OutputStream, src: pointer, srcLen: Natural): Future[void]
    {.iocall.} =
  writeNginxFileSync(s, src, srcLen)
  result = newFuture[void]("writeNginxFileAsync")
  fsTranslateErrors "Unexpected exception from merely completing a future":
    result.complete()

proc flushNginxFileSync(s: OutputStream)
    {.iocall.} =
  let ns = NginxFileOutputStream(s)
  if ns.buffers != nil:
    for span in ns.buffers.consumeAll():
      let spanLen = span.len
      if spanLen > 0:
        let oldLen = ns.internalBuf.len
        ns.internalBuf.setLen(oldLen + spanLen)
        copyMem(addr ns.internalBuf[oldLen], span.startAddr, spanLen)
  if ns.internalBuf.len > 0 and ns.fileWriteCb != nil:
    ns.fileWriteCb(addr ns.internalBuf[0], ns.internalBuf.len)
    ns.internalBuf.setLen(0)

proc flushNginxFileAsync(s: OutputStream): Future[void]
    {.iocall.} =
  flushNginxFileSync(s)
  result = newFuture[void]("flushNginxFileAsync")
  fsTranslateErrors "Unexpected exception from merely completing a future":
    result.complete()

proc closeNginxFileOutputSync(s: OutputStream)
    {.iocall.} =
  let ns = NginxFileOutputStream(s)
  # Flush remaining data
  if ns.buffers != nil:
    for span in ns.buffers.consumeAll():
      let spanLen = span.len
      if spanLen > 0:
        let oldLen = ns.internalBuf.len
        ns.internalBuf.setLen(oldLen + spanLen)
        copyMem(addr ns.internalBuf[oldLen], span.startAddr, spanLen)
  if ns.internalBuf.len > 0 and ns.fileWriteCb != nil:
    ns.fileWriteCb(addr ns.internalBuf[0], ns.internalBuf.len)
    ns.internalBuf.setLen(0)
  # Signal close
  if ns.fileCloseCb != nil:
    ns.fileCloseCb()

proc closeNginxFileOutputAsync(s: OutputStream): Future[void]
    {.iocall.} =
  closeNginxFileOutputSync(s)
  result = newFuture[void]("closeNginxFileOutputAsync")
  fsTranslateErrors "Unexpected exception from merely completing a future":
    result.complete()

const nginxFileOutputVTable* = OutputStreamVTable(
  writeSync: writeNginxFileSync,
  writeAsync: writeNginxFileAsync,
  flushSync: flushNginxFileSync,
  flushAsync: flushNginxFileAsync,
  closeSync: closeNginxFileOutputSync,
  closeAsync: closeNginxFileOutputAsync,
)

proc nginxFileOutput*(writeCb: FileWriteCallback;
                      closeCb: CloseCallback = nil;
                      pageSize = defaultPageSize): OutputStreamHandle =
  ## Creates an OutputStream for writing file data via callbacks.
  ##
  ## `writeCb` is called with (buf, size) to write data to the file.
  ## Maps to ngx_write_file / ngx_write_chain_to_temp_file.
  makeHandle NginxFileOutputStream(
    vtable: vtableAddr nginxFileOutputVTable,
    buffers: PageBuffers.init(pageSize),
    internalBuf: @[],
    fileWriteCb: writeCb,
    fileCloseCb: closeCb,
  )

# =============================================================================
# Section 8: NginxConnection — Bidirectional socket I/O pair
# =============================================================================

type
  NginxConnection* = object
    ## A bidirectional stream pair wrapping an nginx connection.
    input*: InputStreamHandle
    output*: OutputStreamHandle

type
  NginxConnInputStream = ref object of InputStream
    connReadCb: ConnReadCallback
    connCloseCb: ConnCloseCallback

  NginxConnOutputStream = ref object of OutputStream
    internalBuf: seq[byte]
    connWriteCb: ConnWriteCallback
    connCloseCb: ConnCloseCallback

# --- Connection input ---

proc readConnSync(s: InputStream, dst: pointer, dstLen: Natural): Natural
    {.iocall.} =
  let ns = NginxConnInputStream(s)
  implementSingleRead(s.buffers, dst, dstLen,
                      ReadFlags {},
                      readStartAddr, readLen):
    ns.connReadCb(readStartAddr, readLen)

proc readConnAsync(s: InputStream, dst: pointer, dstLen: Natural): Future[Natural]
    {.iocall.} =
  let bytesRead = readConnSync(s, dst, dstLen)
  result = newFuture[Natural]("readConnAsync")
  fsTranslateErrors "Unexpected exception from merely completing a future":
    result.complete(bytesRead)

proc closeConnInputSync(s: InputStream)
    {.iocall.} =
  let ns = NginxConnInputStream(s)
  if ns.connCloseCb != nil:
    ns.connCloseCb()

proc closeConnInputAsync(s: InputStream): Future[void]
    {.iocall.} =
  closeConnInputSync(s)
  result = newFuture[void]("closeConnInputAsync")
  fsTranslateErrors "Unexpected exception from merely completing a future":
    result.complete()

const nginxConnInputVTable* = InputStreamVTable(
  readSync: readConnSync,
  readAsync: readConnAsync,
  closeSync: closeConnInputSync,
  closeAsync: closeConnInputAsync,
)

# --- Connection output ---

proc writeConnSync(s: OutputStream, src: pointer, srcLen: Natural)
    {.iocall.} =
  let ns = NginxConnOutputStream(s)
  if ns.buffers != nil:
    for span in ns.buffers.consumeAll():
      let spanLen = span.len
      if spanLen > 0:
        let oldLen = ns.internalBuf.len
        ns.internalBuf.setLen(oldLen + spanLen)
        copyMem(addr ns.internalBuf[oldLen], span.startAddr, spanLen)
  if srcLen > 0:
    let oldLen = ns.internalBuf.len
    ns.internalBuf.setLen(oldLen + srcLen)
    copyMem(addr ns.internalBuf[oldLen], src, srcLen)

proc writeConnAsync(s: OutputStream, src: pointer, srcLen: Natural): Future[void]
    {.iocall.} =
  writeConnSync(s, src, srcLen)
  result = newFuture[void]("writeConnAsync")
  fsTranslateErrors "Unexpected exception from merely completing a future":
    result.complete()

proc flushConnSync(s: OutputStream)
    {.iocall.} =
  let ns = NginxConnOutputStream(s)
  if ns.buffers != nil:
    for span in ns.buffers.consumeAll():
      let spanLen = span.len
      if spanLen > 0:
        let oldLen = ns.internalBuf.len
        ns.internalBuf.setLen(oldLen + spanLen)
        copyMem(addr ns.internalBuf[oldLen], span.startAddr, spanLen)
  if ns.internalBuf.len > 0 and ns.connWriteCb != nil:
    var pos = 0
    while pos < ns.internalBuf.len:
      let written = ns.connWriteCb(addr ns.internalBuf[pos],
                                    Natural(ns.internalBuf.len - pos))
      if written == 0:
        raise newException(IOError, "Connection write returned 0")
      pos += written
    ns.internalBuf.setLen(0)

proc flushConnAsync(s: OutputStream): Future[void]
    {.iocall.} =
  flushConnSync(s)
  result = newFuture[void]("flushConnAsync")
  fsTranslateErrors "Unexpected exception from merely completing a future":
    result.complete()

proc closeConnOutputSync(s: OutputStream)
    {.iocall.} =
  let ns = NginxConnOutputStream(s)
  # Flush remaining data
  flushConnSync(s)
  # Signal close
  if ns.connCloseCb != nil:
    ns.connCloseCb()

proc closeConnOutputAsync(s: OutputStream): Future[void]
    {.iocall.} =
  closeConnOutputSync(s)
  result = newFuture[void]("closeConnOutputAsync")
  fsTranslateErrors "Unexpected exception from merely completing a future":
    result.complete()

const nginxConnOutputVTable* = OutputStreamVTable(
  writeSync: writeConnSync,
  writeAsync: writeConnAsync,
  flushSync: flushConnSync,
  flushAsync: flushConnAsync,
  closeSync: closeConnOutputSync,
  closeAsync: closeConnOutputAsync,
)

proc nginxConnection*(readCb: ConnReadCallback;
                      writeCb: ConnWriteCallback;
                      closeCb: ConnCloseCallback = nil;
                      pageSize = defaultPageSize): NginxConnection =
  ## Creates a bidirectional stream pair wrapping an nginx connection.
  ##
  ## `readCb` maps to c->recv(c, buf, size) — transparent to SSL.
  ## `writeCb` maps to c->send(c, buf, size).
  ## `closeCb` is called when either side is closed.
  NginxConnection(
    input: makeHandle NginxConnInputStream(
      vtable: vtableAddr nginxConnInputVTable,
      buffers: PageBuffers.init(pageSize),
      connReadCb: readCb,
      connCloseCb: closeCb,
    ),
    output: makeHandle NginxConnOutputStream(
      vtable: vtableAddr nginxConnOutputVTable,
      buffers: PageBuffers.init(pageSize),
      internalBuf: @[],
      connWriteCb: writeCb,
      connCloseCb: closeCb,
    ),
  )

# =============================================================================
# Section 9: NginxSubrequestStream — Capture subrequest response
# =============================================================================

proc nginxSubrequestInput*(bodyCb: RequestBodyCallback;
                            closeCb: ReadCloseCallback = nil;
                            pageSize = defaultPageSize): InputStreamHandle =
  ## Creates an InputStream for capturing subrequest response data.
  ##
  ## Same as nginxRequestBodyInput — the captured subrequest output
  ## is available as a buffer chain after the post_subrequest handler fires.
  ## This is a named alias for clarity.
  nginxRequestBodyInput(bodyCb, closeCb, pageSize)
