{.used.}

import
  std/strutils,
  unittest2,
  ../faststreams/[outputs, async_backend, nginx_adapters]

proc toString(data: openArray[byte]): string =
  result = newStringOfCap(data.len)
  for b in data:
    result.add char(b)

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
