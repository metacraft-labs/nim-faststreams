# The seeded-pipe regression uses real PageBuffers, pipeInput and Chronos
# scheduler/futures; no mocks or replacement scheduler are used. It checks
# the public device/buffer boundary without filesystem timing dependencies.

{.used.}

import
  unittest2,

  # FastStreams modules:
  ../faststreams/[pipelines, multisync]

when fsAsyncSupport:
  import
    # Std lib:
    std/[strutils, random, base64, terminal],
    # FastStreams modules:
    ../faststreams/[pipelines, multisync],
    # Testing modules:
    ./base64 as fsBase64,
    chronos/unittest2/asynctests

  include system/timers

  type
    TestTimes = object
      fsPipeline: Nanos
      fsAsyncPipeline: Nanos
      stdFunctionCalls: Nanos

  proc upcaseAllCharacters(i: InputStream, o: OutputStream) {.fsMultiSync.} =
    let inputLen = i.len
    if inputLen.isSome:
      o.ensureRunway inputLen.get

    while i.readable:
      o.write toUpperAscii(i.read.char)

    close o

  proc printTimes(t: TestTimes) =
    styledEcho "  cpu time [FS Sync  ]: ", styleBright, $t.fsPipeline, "ms"
    styledEcho "  cpu time [FS Async ]: ", styleBright, $t.fsAsyncPipeline, "ms"
    styledEcho "  cpu time [Std Lib  ]: ", styleBright, $t.stdFunctionCalls, "ms"

  template timeit(timerVar: var Nanos, code: untyped) =
    let t0 = getTicks()
    code
    timerVar = int64(getTicks() - t0) div 1000000

  proc getOutput(sp: AsyncInputStream, T: type string): Future[string] {.async.} =
    # Read real stream bytes into owned string storage; managed seq and
    # string representations are not interchangeable.
    let size = sp.totalUnconsumedBytes()
    if size > 0:
      result = newString(size)
      doAssert sp.readInto(result.toOpenArrayByte(0, size - 1))

  suite "pipelines":
    const loremIpsum = """
      Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod
      tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim
      veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex
      ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate
      velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat
      cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id
      est laborum.

    """

    test "upper-case/base64 pipeline benchmark":
      var
        times: TestTimes
        stdRes: string
        fsRes: string
        fsAsyncRes: string

      let inputText = loremIpsum.repeat(5000)

      timeit times.stdFunctionCalls:
        stdRes = base64.decode(base64.encode(toUpperAscii(inputText)))

      timeit times.fsPipeline:
        fsRes = executePipeline(unsafeMemoryInput(inputText),
                                upcaseAllCharacters,
                                base64encode,
                                base64decode,
                                getOutput string)

      timeit times.fsAsyncPipeline:
        fsAsyncRes = waitFor executePipeline(Async unsafeMemoryInput(inputText),
                                            upcaseAllCharacters,
                                            base64encode,
                                            base64decode,
                                            getOutput string)

      check fsAsyncRes == stdRes
      check fsRes == stdRes

      printTimes times

    asyncTest "upper-case/base64 async pipeline":
      let pipe = asyncPipe()
      let inputText = repeat(loremIpsum, 100)

      proc pipeFeeder(s: AsyncOutputStream) {.gcsafe, async.} =
        randomize 1234
        var pos = 0

        while pos != inputText.len:
          let bytesToWrite = rand(15)

          if bytesToWrite == 0:
            s.write inputText[pos]
            inc pos
          else:
            let endPos = min(pos + bytesToWrite, inputText.len)
            s.writeAndWait inputText[pos ..< endPos]
            pos = endPos

          let sleep = rand(50) - 45
          if sleep > 0:
            await sleepAsync(sleep.milliseconds)

        close s

      asyncCheck pipeFeeder(pipe.initWriter)

      let f = executePipeline(pipe.initReader,
                              upcaseAllCharacters,
                              base64encode,
                              base64decode,
                              getOutput string)

      let fsAsyncres = await f

      check fsAsyncres == toUpperAscii(inputText)
else:
  test "pipelines":
    skip

when fsAsyncSupport:
  proc seededPipeRoundtrip(): Future[void] {.async.} =
    let buffers = PageBuffers.init(64)
    let payload = @[byte 0x11, 0x22, 0x33, 0x44, 0x55]
    buffers.write(payload)
    let producer = pipeOutput(buffers)
    close(producer)
    let input = pipeInput(buffers)
    try:
      var actual: seq[byte]
      while input.readable:
        actual.add input.read()
      check actual == payload
    finally:
      close(input)

  suite "seeded asynchronous pipe":
    test "initial readable bytes survive construction and close":
      waitFor seededPipeRoundtrip()

const asyncBackend {.strdefine.} = "none"

when asyncBackend == "chronos":
  proc awaitingGroup(futures: seq[Future[void]]): Future[void] {.async.} =
    fsAwait allFutures(futures)

  proc raisesAwareStep(fail: bool): Future[int] {.async: (raises: [IOError]).} =
    if fail:
      raise newException(IOError, "raises-aware failure")
    return 23

  proc awaitingRaisesAware(fail: bool): Future[int] {.async.} =
    return fsAwait raisesAwareStep(fail)

  suite "Chronos raises-aware await delegation":
    test "allFutures completes through the wrapper":
      let completed = newFuture[void]("completed group member")
      completed.complete()
      waitFor awaitingGroup(@[completed])
    test "cancellation reaches the wrapper caller":
      let pending = newFuture[void]("pending group member")
      let joined = awaitingGroup(@[pending])
      waitFor joined.cancelAndWait()
      check joined.cancelled()
    test "typed result and error reach the wrapper caller":
      check waitFor(awaitingRaisesAware(false)) == 23
      expect IOError:
        discard waitFor awaitingRaisesAware(true)
