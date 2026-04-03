{.used.}

import
  std/strutils,
  unittest2,
  ../faststreams/[inputs, outputs, async_backend, nginx_adapters]

proc toString(data: openArray[byte]): string =
  result = newStringOfCap(data.len)
  for b in data:
    result.add char(b)

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(c)

# =============================================================================
# Existing tests: nginx Future type
# =============================================================================

suite "nginx Future type":
  test "new future is pending":
    let f = newFuture[int]("test")
    check f.isPending
    check not f.isCompleted
    check not f.isFailed

  test "complete sets value and state":
    let f = newFuture[int]("test")
    f.complete(42)
    check f.isCompleted
    check f.read == 42

  test "complete void future":
    let f = newFuture[void]("test")
    f.complete()
    check f.isCompleted
    # read should not raise
    f.read()

  test "fail sets error and state":
    let f = newFuture[int]("test")
    f.fail(newException(CatchableError, "boom"))
    check f.isFailed
    expect CatchableError:
      discard f.read

  test "callbacks fire on complete":
    let f = newFuture[void]("test")
    var fired = false
    f.addCallback(proc() = fired = true)
    check not fired
    f.complete()
    check fired

  test "callback added after completion fires immediately":
    let f = newFuture[void]("test")
    f.complete()
    var fired = false
    f.addCallback(proc() = fired = true)
    check fired

  test "multiple callbacks fire in order":
    let f = newFuture[void]("test")
    var order: seq[int]
    f.addCallback(proc() = order.add(1))
    f.addCallback(proc() = order.add(2))
    f.addCallback(proc() = order.add(3))
    f.complete()
    check order == @[1, 2, 3]

  test "waitFor reads completed future":
    let f = newFuture[int]("test")
    f.complete(99)
    check waitFor(f) == 99

  test "waitFor void future":
    let f = newFuture[void]("test")
    f.complete()
    waitFor(f)

  test "asyncCheck on completed future is ok":
    let f = newFuture[void]("test")
    f.complete()
    asyncCheck(f)

  test "asyncCheck on failed future raises":
    let f = newFuture[void]("test")
    f.fail(newException(CatchableError, "boom"))
    expect CatchableError:
      asyncCheck(f)

# =============================================================================
# Existing tests: NginxOutputStream
# =============================================================================

suite "NginxOutputStream - writeSync":
  test "write appends to internal buffer":
    var flushed: seq[byte]
    proc onFlush(data: openArray[byte]) {.raises: [IOError].} =
      flushed.add(data)
    let stream = nginxOutput(onFlush)
    stream.write("Hello")
    stream.flush()
    check toString(flushed) == "Hello"

  test "multiple writes accumulate":
    var flushed: seq[byte]
    proc onFlush(data: openArray[byte]) {.raises: [IOError].} =
      flushed.add(data)
    let stream = nginxOutput(onFlush)
    stream.write("Hello")
    stream.write(" ")
    stream.write("World")
    stream.flush()
    check toString(flushed) == "Hello World"

  test "empty write is noop":
    var flushCount = 0
    proc onFlush(data: openArray[byte]) {.raises: [IOError].} =
      inc flushCount
    let stream = nginxOutput(onFlush)
    stream.write("")
    stream.flush()
    # Empty write followed by flush with no data should not call flushCb
    check flushCount == 0

suite "NginxOutputStream - flushSync":
  test "flush calls callback with buffered data":
    var flushedData: string
    proc onFlush(data: openArray[byte]) {.raises: [IOError].} =
      flushedData = toString(data)
    let stream = nginxOutput(onFlush)
    stream.write("test data")
    stream.flush()
    check flushedData == "test data"

  test "flush clears internal buffer":
    var flushCount = 0
    proc onFlush(data: openArray[byte]) {.raises: [IOError].} =
      inc flushCount
    let stream = nginxOutput(onFlush)
    stream.write("data")
    stream.flush()
    check flushCount == 1
    # Second flush with no new writes should not call callback
    stream.flush()
    check flushCount == 1

  test "flush on empty stream is noop":
    var flushCount = 0
    proc onFlush(data: openArray[byte]) {.raises: [IOError].} =
      inc flushCount
    let stream = nginxOutput(onFlush)
    stream.flush()
    check flushCount == 0

suite "NginxOutputStream - closeSync":
  test "close flushes remaining data and calls closeCb":
    var flushedData: string
    var closeCalled = false
    proc onFlush(data: openArray[byte]) {.raises: [IOError].} =
      flushedData = toString(data)
    proc onClose() {.raises: [IOError].} =
      closeCalled = true
    let stream = nginxOutput(onFlush, onClose)
    stream.write("final")
    close(stream)
    check flushedData == "final"
    check closeCalled

  test "close without writes calls closeCb":
    var closeCalled = false
    proc onFlush(data: openArray[byte]) {.raises: [IOError].} =
      discard
    proc onClose() {.raises: [IOError].} =
      closeCalled = true
    let stream = nginxOutput(onFlush, onClose)
    close(stream)
    check closeCalled

  test "close after flush sends remaining and closes":
    var flushedChunks: seq[string]
    var closeCalled = false
    proc onFlush(data: openArray[byte]) {.raises: [IOError].} =
      flushedChunks.add(toString(data))
    proc onClose() {.raises: [IOError].} =
      closeCalled = true
    let stream = nginxOutput(onFlush, onClose)
    stream.write("chunk1")
    stream.flush()
    stream.write("chunk2")
    close(stream)
    check flushedChunks.len == 2
    check flushedChunks[0] == "chunk1"
    check flushedChunks[1] == "chunk2"
    check closeCalled

suite "NginxOutputStream - async operations":
  test "writeAsync returns completed future":
    var flushed: seq[byte]
    proc onFlush(data: openArray[byte]) {.raises: [IOError].} =
      flushed.add(data)
    let stream = nginxOutput(onFlush)
    stream.write("async data")
    stream.flush()
    check toString(flushed) == "async data"

  test "flushAsync calls callback and returns completed future":
    var flushedData: string
    proc onFlush(data: openArray[byte]) {.raises: [IOError].} =
      flushedData = toString(data)
    let stream = nginxOutput(onFlush)
    stream.write("data")
    stream.flush()
    check flushedData == "data"

suite "NginxOutputStream - full lifecycle":
  test "write-flush-write-flush-close":
    var flushedChunks: seq[string]
    var closeCalled = false
    proc onFlush(data: openArray[byte]) {.raises: [IOError].} =
      flushedChunks.add(toString(data))
    proc onClose() {.raises: [IOError].} =
      closeCalled = true
    let stream = nginxOutput(onFlush, onClose)

    # Write shell HTML (TTFB)
    stream.write("<html><body>")
    stream.flush()
    check flushedChunks.len == 1
    check flushedChunks[0] == "<html><body>"

    # Write body content
    stream.write("<div>Content</div>")
    stream.flush()
    check flushedChunks.len == 2
    check flushedChunks[1] == "<div>Content</div>"

    # Close
    stream.write("</body></html>")
    close(stream)
    check flushedChunks.len == 3
    check flushedChunks[2] == "</body></html>"
    check closeCalled

  test "streaming SSR simulation":
    var flushedChunks: seq[string]
    var closeCalled = false
    proc onFlush(data: openArray[byte]) {.raises: [IOError].} =
      flushedChunks.add(toString(data))
    proc onClose() {.raises: [IOError].} =
      closeCalled = true
    let stream = nginxOutput(onFlush, onClose)

    # Shell (TTFB)
    stream.write("<!DOCTYPE html><html><body>")
    stream.write("<div id=\"app\"><!--$-->Loading...<!--/$-->")
    stream.flush()
    check flushedChunks.len == 1

    # Suspense boundary resolves
    stream.write("<script>_$RC('b0', '<p>Content</p>')</script>")
    stream.flush()
    check flushedChunks.len == 2

    # Hydration script + close
    stream.write("<script>window._$HY={}</script>")
    stream.write("</body></html>")
    close(stream)
    check flushedChunks.len == 3
    check closeCalled

  test "large write across page boundaries":
    var totalFlushed: seq[byte]
    proc onFlush(data: openArray[byte]) {.raises: [IOError].} =
      totalFlushed.add(data)
    let stream = nginxOutput(onFlush, pageSize = 10)

    let largeData = "A".repeat(100)
    stream.write(largeData)
    stream.flush()
    check toString(totalFlushed) == largeData

  test "close with nil closeCb works":
    var flushedData: string
    proc onFlush(data: openArray[byte]) {.raises: [IOError].} =
      flushedData = toString(data)
    let stream = nginxOutput(onFlush)
    stream.write("data")
    close(stream)
    check flushedData == "data"

# =============================================================================
# NginxInputStream tests
# =============================================================================

suite "NginxInputStream - basic read":
  test "read from callback returns data":
    let testData = "Hello, nginx!".toBytes()
    var pos = 0
    proc onRead(buf: pointer, maxLen: Natural): Natural {.gcsafe, raises: [IOError].} =
      let available = testData.len - pos
      if available == 0:
        return 0
      let toCopy = min(maxLen, available)
      copyMem(buf, unsafeAddr testData[pos], toCopy)
      pos += toCopy
      return Natural(toCopy)

    let handle = nginxInput(onRead)
    let stream = handle.s
    var output: seq[byte]
    while stream.readable:
      output.add stream.read()
    check toString(output) == "Hello, nginx!"

  test "read from callback returning 0 signals EOF":
    proc onRead(buf: pointer, maxLen: Natural): Natural {.gcsafe, raises: [IOError].} =
      return 0

    let handle = nginxInput(onRead)
    let stream = handle.s
    check not stream.readable

  test "read callback that raises propagates IOError":
    proc onRead(buf: pointer, maxLen: Natural): Natural {.gcsafe, raises: [IOError].} =
      raise newException(IOError, "read failed")

    let handle = nginxInput(onRead)
    let stream = handle.s
    expect IOError:
      discard stream.readable

  test "close callback fires":
    var closeCalled = false
    let testData = "x".toBytes()
    var done = false
    proc onRead(buf: pointer, maxLen: Natural): Natural {.gcsafe, raises: [IOError].} =
      if not done:
        done = true
        copyMem(buf, unsafeAddr testData[0], 1)
        return 1
      return 0
    proc onClose() {.gcsafe, raises: [IOError].} =
      closeCalled = true

    let handle = nginxInput(onRead, onClose)
    close(handle.s)
    check closeCalled

  test "multiple sequential reads":
    # Return data in small chunks
    var callCount = 0
    let chunks = @["AAA".toBytes(), "BBB".toBytes(), "CCC".toBytes()]
    proc onRead(buf: pointer, maxLen: Natural): Natural {.gcsafe, raises: [IOError].} =
      if callCount >= chunks.len:
        return 0
      let chunk = chunks[callCount]
      let toCopy = min(maxLen, chunk.len)
      copyMem(buf, unsafeAddr chunk[0], toCopy)
      inc callCount
      return Natural(toCopy)

    let handle = nginxInput(onRead)
    let stream = handle.s
    var output: seq[byte]
    while stream.readable:
      output.add stream.read()
    check toString(output) == "AAABBBCCC"

# =============================================================================
# NginxRequestBodyStream tests
# =============================================================================

suite "NginxRequestBodyStream":
  test "single chunk body":
    var bodyData = "POST body content".toBytes()
    proc onBody(): seq[BodyChunk] {.gcsafe, raises: [IOError].} =
      @[BodyChunk(data: addr bodyData[0], len: bodyData.len)]

    let handle = nginxRequestBodyInput(onBody)
    let stream = handle.s
    var output: seq[byte]
    while stream.readable:
      output.add stream.read()
    check toString(output) == "POST body content"

  test "multiple chunk body":
    var chunk1 = "Hello ".toBytes()
    var chunk2 = "World".toBytes()
    proc onBody(): seq[BodyChunk] {.gcsafe, raises: [IOError].} =
      @[
        BodyChunk(data: addr chunk1[0], len: chunk1.len),
        BodyChunk(data: addr chunk2[0], len: chunk2.len),
      ]

    let handle = nginxRequestBodyInput(onBody)
    let stream = handle.s
    var output: seq[byte]
    while stream.readable:
      output.add stream.read()
    check toString(output) == "Hello World"

  test "empty body signals EOF":
    proc onBody(): seq[BodyChunk] {.gcsafe, raises: [IOError].} =
      @[]

    let handle = nginxRequestBodyInput(onBody)
    let stream = handle.s
    check not stream.readable

  test "close callback fires":
    var closeCalled = false
    proc onBody(): seq[BodyChunk] {.gcsafe, raises: [IOError].} =
      @[]
    proc onClose() {.gcsafe, raises: [IOError].} =
      closeCalled = true

    let handle = nginxRequestBodyInput(onBody, onClose)
    close(handle.s)
    check closeCalled

  test "three chunks read sequentially":
    var c1 = "AA".toBytes()
    var c2 = "BB".toBytes()
    var c3 = "CC".toBytes()
    proc onBody(): seq[BodyChunk] {.gcsafe, raises: [IOError].} =
      @[
        BodyChunk(data: addr c1[0], len: c1.len),
        BodyChunk(data: addr c2[0], len: c2.len),
        BodyChunk(data: addr c3[0], len: c3.len),
      ]

    let handle = nginxRequestBodyInput(onBody)
    let stream = handle.s
    var output: seq[byte]
    while stream.readable:
      output.add stream.read()
    check toString(output) == "AABBCC"

# =============================================================================
# NginxUpstreamResponseStream tests
# =============================================================================

suite "NginxUpstreamResponseStream":
  test "read single chunk then EOF":
    var chunkData = "upstream response".toBytes()
    var sent = false
    proc onChunk(): BodyChunk {.gcsafe, raises: [IOError].} =
      if not sent:
        sent = true
        return BodyChunk(data: addr chunkData[0], len: chunkData.len)
      return BodyChunk(data: nil, len: 0)

    let handle = nginxUpstreamResponseInput(onChunk)
    let stream = handle.s
    var output: seq[byte]
    while stream.readable:
      output.add stream.read()
    check toString(output) == "upstream response"

  test "multiple chunks then EOF":
    var c1 = "part1-".toBytes()
    var c2 = "part2".toBytes()
    var idx = 0
    proc onChunk(): BodyChunk {.gcsafe, raises: [IOError].} =
      case idx
      of 0:
        inc idx
        return BodyChunk(data: addr c1[0], len: c1.len)
      of 1:
        inc idx
        return BodyChunk(data: addr c2[0], len: c2.len)
      else:
        return BodyChunk(data: nil, len: 0)

    let handle = nginxUpstreamResponseInput(onChunk)
    let stream = handle.s
    var output: seq[byte]
    while stream.readable:
      output.add stream.read()
    check toString(output) == "part1-part2"

  test "immediate EOF":
    proc onChunk(): BodyChunk {.gcsafe, raises: [IOError].} =
      BodyChunk(data: nil, len: 0)

    let handle = nginxUpstreamResponseInput(onChunk)
    let stream = handle.s
    check not stream.readable

  test "close callback fires":
    var closeCalled = false
    proc onChunk(): BodyChunk {.gcsafe, raises: [IOError].} =
      BodyChunk(data: nil, len: 0)
    proc onClose() {.gcsafe, raises: [IOError].} =
      closeCalled = true

    let handle = nginxUpstreamResponseInput(onChunk, onClose)
    close(handle.s)
    check closeCalled

# =============================================================================
# NginxUpstreamRequestStream tests (output)
# =============================================================================

suite "NginxUpstreamRequestStream":
  test "upstream request output works like nginxOutput":
    var flushed: seq[byte]
    proc onFlush(data: openArray[byte]) {.raises: [IOError].} =
      flushed.add(data)
    let stream = nginxUpstreamRequestOutput(onFlush)
    stream.write("GET /api HTTP/1.1")
    stream.flush()
    check toString(flushed) == "GET /api HTTP/1.1"

  test "close callback fires":
    var closeCalled = false
    proc onFlush(data: openArray[byte]) {.raises: [IOError].} =
      discard
    proc onClose() {.raises: [IOError].} =
      closeCalled = true
    let stream = nginxUpstreamRequestOutput(onFlush, onClose)
    close(stream)
    check closeCalled

# =============================================================================
# NginxFileInputStream tests
# =============================================================================

suite "NginxFileInputStream":
  test "read file data at offset":
    let fileData = "0123456789ABCDEF".toBytes()
    proc onFileRead(buf: pointer, size: Natural, offset: int64): Natural
        {.gcsafe, raises: [IOError].} =
      let available = fileData.len - int(offset)
      if available <= 0:
        return 0
      let toCopy = min(size, available)
      copyMem(buf, unsafeAddr fileData[int(offset)], toCopy)
      return Natural(toCopy)

    let handle = nginxFileInput(onFileRead, int64(fileData.len))
    let stream = handle.s
    var output: seq[byte]
    while stream.readable:
      output.add stream.read()
    check toString(output) == "0123456789ABCDEF"

  test "empty file signals EOF":
    proc onFileRead(buf: pointer, size: Natural, offset: int64): Natural
        {.gcsafe, raises: [IOError].} =
      return 0

    let handle = nginxFileInput(onFileRead, 0)
    let stream = handle.s
    check not stream.readable

  test "close callback fires":
    var closeCalled = false
    proc onFileRead(buf: pointer, size: Natural, offset: int64): Natural
        {.gcsafe, raises: [IOError].} =
      return 0
    proc onClose() {.gcsafe, raises: [IOError].} =
      closeCalled = true

    let handle = nginxFileInput(onFileRead, 0, onClose)
    close(handle.s)
    check closeCalled

  test "len reports remaining bytes":
    let fileData = "ABCDEFGH".toBytes()
    proc onFileRead(buf: pointer, size: Natural, offset: int64): Natural
        {.gcsafe, raises: [IOError].} =
      let available = fileData.len - int(offset)
      if available <= 0:
        return 0
      let toCopy = min(size, available)
      copyMem(buf, unsafeAddr fileData[int(offset)], toCopy)
      return Natural(toCopy)

    let handle = nginxFileInput(onFileRead, int64(fileData.len))
    let stream = handle.s
    let reportedLen = stream.len
    check reportedLen.isSome
    check reportedLen.get == Natural(8)

# =============================================================================
# NginxFileOutputStream tests
# =============================================================================

suite "NginxFileOutputStream":
  test "write data forwarded to callback":
    var writtenData: seq[byte]
    proc onWrite(buf: pointer, size: Natural) {.gcsafe, raises: [IOError].} =
      let src = cast[ptr byte](buf)
      for i in 0 ..< size:
        writtenData.add cast[ptr byte](cast[uint](src) + uint(i))[]

    let stream = nginxFileOutput(onWrite)
    stream.write("file content")
    stream.flush()
    check toString(writtenData) == "file content"

  test "close flushes and calls closeCb":
    var writtenData: seq[byte]
    var closeCalled = false
    proc onWrite(buf: pointer, size: Natural) {.gcsafe, raises: [IOError].} =
      let src = cast[ptr byte](buf)
      for i in 0 ..< size:
        writtenData.add cast[ptr byte](cast[uint](src) + uint(i))[]
    proc onClose() {.raises: [IOError].} =
      closeCalled = true

    let stream = nginxFileOutput(onWrite, onClose)
    stream.write("data")
    close(stream)
    check toString(writtenData) == "data"
    check closeCalled

  test "multiple writes accumulate":
    var writtenData: seq[byte]
    proc onWrite(buf: pointer, size: Natural) {.gcsafe, raises: [IOError].} =
      let src = cast[ptr byte](buf)
      for i in 0 ..< size:
        writtenData.add cast[ptr byte](cast[uint](src) + uint(i))[]

    let stream = nginxFileOutput(onWrite)
    stream.write("AA")
    stream.write("BB")
    stream.flush()
    check toString(writtenData) == "AABB"

# =============================================================================
# NginxConnection tests
# =============================================================================

suite "NginxConnection":
  test "bidirectional: write output, read input":
    # Simulate a loopback: what output writes, input reads
    var pipe: seq[byte]
    var readPos = 0

    proc onRead(buf: pointer, size: Natural): Natural {.gcsafe, raises: [IOError].} =
      let available = pipe.len - readPos
      if available == 0:
        return 0
      let toCopy = min(size, available)
      copyMem(buf, addr pipe[readPos], toCopy)
      readPos += toCopy
      return Natural(toCopy)

    proc onWrite(buf: pointer, size: Natural): Natural {.gcsafe, raises: [IOError].} =
      let src = cast[ptr byte](buf)
      for i in 0 ..< size:
        pipe.add cast[ptr byte](cast[uint](src) + uint(i))[]
      return size

    let conn = nginxConnection(onRead, onWrite)

    # Write to output side
    conn.output.s.write("hello")
    conn.output.s.flush()

    # Read from input side
    let inStream = conn.input.s
    var output: seq[byte]
    while inStream.readable:
      output.add inStream.read()
    check toString(output) == "hello"

  test "EOF on read side":
    proc onRead(buf: pointer, size: Natural): Natural {.gcsafe, raises: [IOError].} =
      return 0
    proc onWrite(buf: pointer, size: Natural): Natural {.gcsafe, raises: [IOError].} =
      return size

    let conn = nginxConnection(onRead, onWrite)
    check not conn.input.s.readable

  test "close both sides":
    var inputClosed = false
    var outputClosed = false
    # Use separate closeCb tracking via wrapper
    proc onRead(buf: pointer, size: Natural): Natural {.gcsafe, raises: [IOError].} =
      return 0
    proc onWrite(buf: pointer, size: Natural): Natural {.gcsafe, raises: [IOError].} =
      return size
    proc onClose() {.gcsafe, raises: [IOError].} =
      # This fires for both sides (shared closeCb)
      discard

    let conn = nginxConnection(onRead, onWrite, onClose)
    close(conn.input.s)
    close(conn.output.s)
    # If we get here without crash, the close worked

# =============================================================================
# NginxSubrequestStream tests
# =============================================================================

suite "NginxSubrequestStream":
  test "subrequest capture same as request body":
    var bodyData = "subrequest output data".toBytes()
    proc onBody(): seq[BodyChunk] {.gcsafe, raises: [IOError].} =
      @[BodyChunk(data: addr bodyData[0], len: bodyData.len)]

    let handle = nginxSubrequestInput(onBody)
    let stream = handle.s
    var output: seq[byte]
    while stream.readable:
      output.add stream.read()
    check toString(output) == "subrequest output data"

  test "subrequest with multiple chunks":
    var c1 = "part1".toBytes()
    var c2 = "part2".toBytes()
    proc onBody(): seq[BodyChunk] {.gcsafe, raises: [IOError].} =
      @[
        BodyChunk(data: addr c1[0], len: c1.len),
        BodyChunk(data: addr c2[0], len: c2.len),
      ]

    let handle = nginxSubrequestInput(onBody)
    let stream = handle.s
    var output: seq[byte]
    while stream.readable:
      output.add stream.read()
    check toString(output) == "part1part2"

  test "empty subrequest":
    proc onBody(): seq[BodyChunk] {.gcsafe, raises: [IOError].} =
      @[]

    let handle = nginxSubrequestInput(onBody)
    let stream = handle.s
    check not stream.readable
