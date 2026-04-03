const
  # To compile with async support, use `-d:asyncBackend=chronos|asyncdispatch`
  asyncBackend {.strdefine.} = "none"

const
  faststreams_async_backend {.strdefine.} = ""

when faststreams_async_backend != "":
  {.fatal: "use `-d:asyncBackend` instead".}

type
  CloseBehavior* = enum
    waitAsyncClose
    dontWaitAsyncClose

const
  debugHelpers* = defined(debugHelpers)
  fsAsyncSupport* = asyncBackend != "none"

when asyncBackend == "none":
  discard
elif asyncBackend == "chronos":
  {.warning: "chronos backend uses nested calls to `waitFor` which is not supported by chronos - it is not recommended to use it until this has been resolved".}

  import
    chronos

  export
    chronos

  template fsAwait*(f: Future): untyped =
    await f

elif asyncBackend == "asyncdispatch":
  {.warning: "asyncdispatch backend currently fails tests - it may or may not work as expected".}

  import
    std/asyncdispatch

  export
    asyncdispatch

  template fsAwait*(awaited: Future): untyped =
    # TODO revisit after https://github.com/nim-lang/Nim/pull/12085/ is merged
    let f = awaited
    yield f
    if not isNil(f.error):
      raise f.error
    f.read

  type Duration* = int

elif asyncBackend == "nginx":
  # Lightweight Future type for nginx integration.
  #
  # Unlike chronos or asyncdispatch, there is no Nim event loop driving
  # future completion. Futures are completed explicitly by calling
  # `complete(future)` — this matches nginx's model where events are
  # triggered by the C event loop, not by a Nim scheduler.

  type
    FutureState* = enum
      fsPending, fsCompleted, fsFailed

    FutureBase* = ref object of RootObj
      state*: FutureState
      error*: ref CatchableError
      callbacks: seq[proc() {.closure, gcsafe.}]

    Future*[T] = ref object of FutureBase
      value*: T

  proc newFuture*[T](fromProc: static string = ""): Future[T] =
    Future[T](state: fsPending)

  proc complete*[T](future: Future[T]; val: T) =
    future.state = fsCompleted
    future.value = val
    for cb in future.callbacks:
      cb()
    future.callbacks.setLen(0)

  proc complete*(future: Future[void]) =
    future.state = fsCompleted
    for cb in future.callbacks:
      cb()
    future.callbacks.setLen(0)

  proc fail*(future: FutureBase; error: ref CatchableError) =
    future.state = fsFailed
    future.error = error
    for cb in future.callbacks:
      cb()
    future.callbacks.setLen(0)

  proc addCallback*(future: FutureBase; cb: proc() {.closure, gcsafe.}) =
    if future.state != fsPending:
      cb()
    else:
      future.callbacks.add(cb)

  proc read*[T](future: Future[T]): T =
    if future.state == fsFailed:
      raise future.error
    elif future.state == fsPending:
      raise newException(ValueError, "Future is still pending")
    future.value

  proc read*(future: Future[void]) =
    if future.state == fsFailed:
      raise future.error
    elif future.state == fsPending:
      raise newException(ValueError, "Future is still pending")

  proc isCompleted*(future: FutureBase): bool =
    future.state == fsCompleted

  proc isFailed*(future: FutureBase): bool =
    future.state == fsFailed

  proc isPending*(future: FutureBase): bool =
    future.state == fsPending

  template fsAwait*(f: untyped): untyped =
    ## For nginx, fsAwait simply reads the future value.
    ## Futures are expected to be already completed in the synchronous
    ## write/flush/close path. For truly async operations, callbacks
    ## are used instead.
    read(f)

  proc waitFor*[T](f: Future[T]): T =
    ## Blocking wait — in the nginx backend, futures are expected to be
    ## already completed, so this just reads the value.
    read(f)

  proc waitFor*(f: Future[void]) =
    read(f)

  proc asyncCheck*(f: FutureBase) =
    ## Check that a future completed without error.
    if f.state == fsFailed and f.error != nil:
      raise f.error

  type Duration* = int

  import std/macros

  macro async*(prc: untyped): untyped =
    ## For the nginx backend, `async` is a lightweight transformation:
    ## - If the proc has no return type or returns `void`, set return type
    ##   to `Future[void]` and wrap the body to return a completed future.
    ## - If the proc already returns `Future[T]`, leave it as-is.
    ##
    ## This is much simpler than chronos's async which transforms the
    ## entire proc into a state machine. Since nginx futures complete
    ## synchronously, no state machine is needed.
    result = prc

    let params = prc.params
    let retType = params[0]

    # Check if return type is already Future[T]
    var alreadyFuture = false
    var innerType: NimNode = nil
    if retType.kind == nnkBracketExpr and retType[0].eqIdent("Future"):
      alreadyFuture = true
      innerType = retType[1]

    if alreadyFuture:
      if innerType.eqIdent("void"):
        # Future[void]: keep return type, wrap body to return completed future
        let origBody = prc.body
        let futSym = genSym(nskLet, "fut")
        prc.body = quote do:
          `origBody`
          let `futSym` = newFuture[void]("async")
          `futSym`.complete()
          return `futSym`
      else:
        # Future[T]: change result type so `result` is T inside the body,
        # then wrap to return a completed Future[T].
        # This mirrors what chronos/asyncdispatch do: inside an async proc
        # returning Future[T], `result` has type T and `await` unwraps futures.
        let origBody = prc.body
        let futSym = genSym(nskLet, "fut")
        let resSym = genSym(nskLet, "res")
        let futType = retType  # Future[T]
        let valType = innerType  # T
        prc.body = quote do:
          let `resSym` = block:
            var result: `valType`
            `origBody`
            result
          let `futSym` = newFuture[`valType`]("async")
          `futSym`.complete(`resSym`)
          return `futSym`
    else:
      # No return type or void: set return type to Future[void]
      if retType.kind == nnkEmpty or
         (retType.kind == nnkIdent and retType.eqIdent("void")):
        params[0] = nnkBracketExpr.newTree(ident"Future", ident"void")

      # Wrap body: execute original body, then return completed future
      let origBody = prc.body
      let futSym = genSym(nskLet, "fut")
      prc.body = quote do:
        `origBody`
        let `futSym` = newFuture[void]("async")
        `futSym`.complete()
        return `futSym`

else:
  {.fatal: "Unrecognized network backend: " & asyncBackend .}

when defined(danger):
  template fsAssert*(x) = discard
  template fsAssert*(x, msg) = discard
else:
  template fsAssert*(x) = doAssert(x)
  template fsAssert*(x, msg) = doAssert(x, msg)

template fsTranslateErrors*(errMsg: string, body: untyped) =
  try:
    body
  except IOError as err:
    raise err
  except Exception as err:
    if err[] of Defect:
      raise (ref Defect)(err)
    else:
      raise newException(IOError, errMsg, err)

template noAwait*(expr: untyped): untyped =
  expr

