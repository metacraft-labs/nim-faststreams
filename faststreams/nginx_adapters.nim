## nginx_adapters.nim
##
## A callback-based output stream adapter for the nginx async backend.
##
## This adapter follows the pattern of chronos_adapters.nim but does not
## depend on any external async library. Instead, write/flush/close
## operations delegate to user-provided callbacks and return lightweight
## Futures that complete synchronously.
##
## The actual nginx FFI (ngx_create_temp_buf, ngx_http_output_filter, etc.)
## stays in the downstream module (ngx-isonim). This adapter is a generic
## "callback-based output stream with Future support" that can be tested
## without nginx headers.

import
  outputs, buffers, async_backend

export
  outputs, async_backend

{.pragma: iocall, nimcall, gcsafe, raises: [IOError].}

type
  FlushCallback* = proc (data: openArray[byte]) {.gcsafe, raises: [IOError].}
    ## Called when the stream is flushed with all buffered data since the
    ## last flush. The callback is responsible for sending the data (e.g.
    ## via ngx_http_output_filter).

  CloseCallback* = proc () {.gcsafe, raises: [IOError].}
    ## Called when the stream is closed. The callback should send the
    ## final response marker (e.g. last_buf in nginx).

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
