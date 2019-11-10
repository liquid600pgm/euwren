import macros
import tables

import euwren/private/wren

#--
# Definitions
#--

type
  RawVM* = ptr WrenVM

  MethodSign = tuple[module, class, name: string, isStatic: bool]
  ClassSign = tuple[module, name: string]

  WrenType* = enum
    wtBool = "Bool"
    wtNum = "Num"
    wtForeign = "Foreign"
    wtList = "List"
    wtNull = "Null"
    wtString = "String"
    wtUnknown = "Wren type"
  WrenTypeData* = object
    case ty*: WrenType
    of wtForeign: foreignId*: uint16
    else: discard

  Wren* = ref object
    ## A Wren virtual machine used for executing code.
    handle: RawVM

    methods: Table[MethodSign, WrenForeignMethodFn]
    classes: Table[ClassSign, WrenForeignClassMethods]

    compileErrors: seq[WrenError]
    rtError: WrenError
  WrenErrorKind* = enum
    weCompile ## A compilation error (eg. syntax error).
    weRuntime ## A runtime error (eg. ``Fiber.abort()``).
  WrenError* = object of CatchableError
    ## A Wren error. This is raised when an error occurs *inside the VM.*
    module*: string
    line*: int
    message*: string
    case kind*: WrenErrorKind
    of weCompile: discard
    of weRuntime:
      stackTrace*: seq[tuple[module: string, line: int, message: string]]

const
  WrenBool* = WrenTypeData(ty: wtBool)
  WrenNum* = WrenTypeData(ty: wtNum)
  WrenList* = WrenTypeData(ty: wtList)
  WrenNull* = WrenTypeData(ty: wtNull)
  WrenString* = WrenTypeData(ty: wtString)

proc `$`*(vm: Wren): string =
  result = "- Wren instance\n" &
           "VM: " & $cast[int](vm.handle) & '\n'

proc newWren*(): Wren =
  ## Creates a new VM.
  new(result) do (vm: Wren):
    wrenFreeVM(vm.handle)

  var config = WrenConfiguration()
  wrenInitConfiguration(addr config)
  # debugging
  config.writeFn = proc (vm: RawVM, text: cstring) {.cdecl.} =
    stdout.write(text)
  config.errorFn = proc (vm: RawVM, ty: WrenErrorType, module: cstring,
                         line: cint, msg: cstring) {.cdecl.} =
    var wvm = cast[Wren](wrenGetUserData(vm))
    case ty
    of WREN_ERROR_COMPILE:
      var err = WrenError(
        kind: weCompile,
        module: $module,
        line: line.int,
        message: $msg
      )
      wvm.compileErrors.add(err)
    of WREN_ERROR_RUNTIME:
      var err = WrenError(
        kind: weRuntime,
        message: $msg
      )
      wvm.rtError = err
    of WREN_ERROR_STACK_TRACE:
      wvm.rtError.stackTrace.add((module: $module,
                                  line: line.int,
                                  message: $msg))
    else: doAssert(false) # unreachable
  # FFI
  config.bindForeignMethodFn = proc (vm: RawVM, module: cstring,
                                     class: cstring, isStatic: bool,
                                     name: cstring): WrenForeignMethodFn
                                    {.cdecl.} =
    var wvm = cast[Wren](wrenGetUserData(vm))
    let sign = ($module, $class, $name, isStatic).MethodSign
    if sign in wvm.methods:
      result = wvm.methods[sign]
    else:
      result = nil
  config.bindForeignClassFn = proc (vm: ptr WrenVM, module: cstring,
                                    class: cstring): WrenForeignClassMethods
                                   {.cdecl.} =
    var wvm = cast[Wren](wrenGetUserData(vm))
    let sign = ($module, $class).ClassSign
    if sign in wvm.classes:
      result = wvm.classes[sign]
    else:
      result = WrenForeignClassMethods()

  result.handle = wrenNewVM(addr config)
  wrenSetUserData(result.handle, cast[pointer](result))
  # ensure 32 slots:
  # 16 for parameters (max amount supported by Wren)
  # 8 for own use
  wrenEnsureSlots(result.handle, 24)
  result.rtError = WrenError(kind: weRuntime)

#--
# Low-level APIs
#--

# Ultimately, you shouldn't need to use these APIs. They're inherently unsafe,
# and don't provide any guarantees or assertions. In fact, they're only a thin
# wrapper over the underlying Wren embedding API.

# Use with care.

proc ensureSlots*(vm: RawVM, amount: int) =
  wrenEnsureSlots(vm, amount.cint)

proc slotCount*(vm: RawVM): int =
  wrenGetSlotCount(vm)

proc getSlot*[T](vm: RawVM, slot: int): T =
  when T is bool:
    result = wrenGetSlotBool(vm, slot.cint)
  elif T is SomeNumber:
    result = T(wrenGetSlotDouble(vm, slot.cint))
  elif T is string:
    var
      len: cint
      bytes = wrenGetSlotBytes(vm, slot.cint, addr len)
    result = newString(len.Natural)
    if len > 0:
      copyMem(result[0].unsafeAddr, bytes, len.Natural)
  elif T is object or T is ref object:
    let
      raw = cast[ptr UncheckedArray[uint16]](wrenGetSlotForeign(vm, slot.cint))
      obj = cast[ptr T](raw[1].unsafeAddr)
    result = obj[]
  else:
    {.error: "unsupported type for slot retrieval".}

proc newForeign*(vm: RawVM, slot: int, size: Natural, classSlot = 0): pointer =
  result = wrenSetSlotNewForeign(vm, slot.cint, classSlot.cint, size.cuint)

proc setSlot*[T](vm: RawVM, slot: int, val: T) =
  when T is bool:
    wrenSetSlotBool(vm, slot.cint, val)
  elif T is SomeNumber:
    wrenSetSlotDouble(vm, slot.cint, val.cdouble)
  elif T is string:
    wrenSetSlotBytes(vm, slot.cint, val, val.len.cuint)
  else:
    {.error: "unsupported type for slot assignment: " & $T.}

proc abortFiber*(vm: RawVM, message: string) =
  vm.setSlot[:string](23, message)
  wrenAbortFiber(vm, 23)

var
  typeIds {.compileTime.}: Table[string, uint16]
    ## Maps type hashes to unique integer IDs
  typeNames {.compileTime.}: Table[uint16, string]
    ## Maps integer IDs to type names
  # typeNameCache {.compileTime.}: Table[uint16, string]
  #   ## Compile-time cache for

proc addTypeName*(id: uint16, name: string) =
  ## This is an implementation detail used internally by the wrapper.
  ## You should not use this in your code.
  typeNames[id] = name

proc getSlotTypeStr(vm: RawVM, slot: int): string =
  discard

proc `$`(tydata: WrenTypeData): string =
  if tydata.ty != wtForeign:
    result = $tydata.ty
  else:
    result = typeNames[tydata.foreignId]

proc checkTypes*(vm: RawVM, types: varargs[WrenTypeData]): bool =
  for i in 0..<types.len:
    let t = types[i]
    if t.ty != wtForeign:
      let slotType = wrenGetSlotType(vm, cint(i + 1)).WrenType
      if t.ty != slotType:
        let slotTypeName = vm.getSlotTypeStr(i + 1)
        vm.abortFiber("type mismatch: got " & slotTypeName & ", " &
                      "but expected " & $t)
        return false
    else:
      let slotTy = wrenGetSlotType(vm, cint(i + 1)).WrenType
      if slotTy != wtForeign:
        let
          foreign = wrenGetSlotForeign(vm, cint(i + 1))
          typeId = cast[ptr uint16](foreign)[]
        if t.foreignId != typeId:
          let
            slotTypeName = vm.getSlotTypeStr(i + 1)
            typeName = typeNames[typeId]
          vm.abortFiber("type mismatch: got " & slotTypeName & ", " &
                        "but expected " & typeName)
          return false
  result = true

proc addProc*(vm: Wren, module, class, signature: string, isStatic: bool,
              impl: WrenForeignMethodFn) =
  vm.methods[(module, class, signature, isStatic)] = impl

proc addClass*(vm: Wren, module, name: string,
               construct: WrenForeignMethodFn,
               destroy: WrenFinalizerFn = nil) =
  vm.classes[(module, name)] = WrenForeignClassMethods(
    allocate: construct,
    finalize: destroy
  )

#--
# End user API - basics
#--

proc module*(vm: Wren, name, src: string) =
  ## Runs the provided source code inside of the specified `main` module.
  let result = wrenInterpret(vm.handle, name, src)
  case result
  of WREN_RESULT_SUCCESS: discard
  of WREN_RESULT_COMPILE_ERROR:
    var err = new(WrenError)
    err.msg = "compile error"
    for e in vm.compileErrors:
      err.msg &= '\n' & e.module & '(' & $e.line & "): " & e.message
    raise err
  of WREN_RESULT_RUNTIME_ERROR:
    var err = new(WrenError)
    err.msg = vm.rtError.message & "\nwren stack trace:"
    for t in vm.rtError.stackTrace:
      err.msg &= "\n  at " & t.module & '(' & $t.line & ')'
    raise err
  else: doAssert(false) # unreachable

proc run*(vm: Wren, src: string) =
  ## Runs the provided source code inside of a module named "main". This should
  ## be used for the entry point of your program. Use ``module`` if you want to
  ## modify the module name (used in error messages).
  vm.module("main", src)

#--
# End user API - foreign()
#--

proc getParamList(formalParams: NimNode): seq[NimNode] =
  ## Flattens an nnkFormalParams into a C-like list of argument types,
  ## eg. ``x, y: int`` becomes ``@[int, int]``.
  for identDefs in formalParams[1..^1]:
    let ty = identDefs[^2]
    for i in 0..identDefs.len - 3:
      result.add(ty)

proc getOverload(choices: NimNode, params: varargs[NimNode]): NimNode =
  ## Finds an appropriate proc overload based on the provided parameters.
  for overload in choices:
    block check:
      let
        impl = overload.getImpl
        formalParams = impl[3]
        argTypes = getParamList(formalParams)
      # compare ``argTypes`` with ``params``
      for i, param in params[0]:
        if argTypes[i] != param:
          break check
      return overload
  error("couldn't find overload for given parameter types")

proc getTypeId(typeSym: NimNode): uint16 =
  let hash = typeSym.signatureHash
  if hash notin typeIds:
    let id = typeIds.len.uint16
    typeIds[hash] = id
    typeNames[id] = typeSym.repr
  result = typeIds[hash]

proc getSlotGetters(params: seq[NimNode]): seq[NimNode] =
  for i, paramType in params:
    let getter = newCall(newTree(nnkBracketExpr, ident"getSlot", paramType),
                         ident"vm", newLit(i + 1))
    result.add(getter)

proc getWrenTypes(types: seq[NimNode]): seq[NimNode] =
  for ty in types:
    if ty.typeKind == ntyBool: result.add(ident"WrenBool")
    elif ty.typeKind in {ntyInt..ntyUint64}: result.add(ident"WrenNum")
    elif ty.typeKind == ntyString: result.add(ident"WrenString")
    elif ty.typeKind in {ntyObject, ntyRef}:
      result.add(newTree(nnkObjConstr, ident"WrenTypeData",
                         newColonExpr(ident"ty", ident"wtForeign"),
                         newColonExpr(ident"foreignId", newLit(getTypeId(ty)))))
    else:
      error("[euwren] unsupported proc param type", ty)

proc genProcGlue(theProc: NimNode, isGetter: bool): NimNode =
  ## Generate a glue procedure with type checks and VM slot conversions.

  # get some metadata about the proc
  let
    procImpl = theProc.getImpl
    procParams = getParamList(procImpl[3])
    procRetType = procImpl[3][0]
  # create a new anonymous proc; this is our resulting glue proc
  result = newProc(params = [newEmptyNode(),
                             newIdentDefs(ident"vm", ident"RawVM")])
  result.addPragma(ident"cdecl")
  var body = newStmtList()
  # generate the call
  let
    call = newCall(theProc, getSlotGetters(procParams))
    callWithReturn =
      if procRetType.kind == nnkEmpty or eqIdent(procRetType, "void"): call
      else:
        newCall(newTree(nnkBracketExpr, ident"setSlot", procRetType),
                ident"vm", newLit(0), call)
  # generate type check
  var typeCheckParams = @[ident"vm"]
  typeCheckParams.add(getWrenTypes(procParams))
  let typeCheck = newCall(ident"checkTypes", typeCheckParams)
  body.add(newIfStmt((cond: typeCheck, body: callWithReturn)))
  result.body = body

proc genSignature(procName: string, arity: int,
                  isStatic, isGetter: bool): string =
  ## Generate a Wren signature for the given proc and its properties.

  proc params(n: int): string =
    ## Generate a string of params like _,_,_,_
    for i in 1..n:
      result.add('_')
      if i != n:
        result.add(',')

  if not isGetter:
    let arity = arity - ord(not isStatic)
    if procName == "[]":
      result = '[' & arity.params & ']'
    elif procName == "[]=":
      result = '[' & (arity - 1).params & "]=(_)"
    else:
      result = procName & '(' & arity.params & ')'
  else:
    result = procName

macro addProcAux*(vm: Wren, module: string, classSym: typed, className: string,
                  procSym: typed, overloaded, isGetter: static bool,
                  params: varargs[typed]): untyped =
  ## Generates code which binds a procedure to the provided Wren instance.
  ## This is an implementation detail and you should not use it in your code.

  # find the correct overload of the procedure, if applicable
  var theProc = procSym
  if procSym.kind != nnkSym:
    if not overloaded:
      error("multiple overloads available; " &
            "provide the correct overload's parameters", procSym)
    theProc = getOverload(procSym, params)
  # get some metadata about the proc
  let
    procImpl = theProc.getImpl
    procParams = getParamList(procImpl[3])
  # generate glue and register the procedure in the Wren instance
  let
    classLit = className
    isStatic = procParams.len < 1 or procParams[0] != classSym
    isStaticLit = newLit(isStatic)
    nameLit = newLit(genSignature(theProc.strVal, procParams.len,
                                  isStatic, isGetter))
  result = newCall("addProc", vm, module,
                   classLit, nameLit, isStaticLit,
                   genProcGlue(theProc, isGetter))

type
  InitProcKind = enum
    ipInit
    ipNew

proc newCast(T, val: NimNode): NimNode =
  newTree(nnkCast, T, val)

proc isRef(class: NimNode): bool =
  if class.typeKind == ntyRef:
    result = true
  elif class.typeKind == ntyTypeDesc:
    let impl = class.getImpl
    if impl[2].kind == nnkRefTy:
      result = true

proc genInitGlue(vm, class, procSym: NimNode,
                 kind: InitProcKind, overloaded: bool,
                 params: varargs[NimNode]): NimNode =
  ## Generates a glue init procedure with checks and type conversions.

  # get the overload, if applicable
  var theProc = procSym
  if procSym.kind != nnkSym:
    if not overloaded:
      error("multiple overloads available; " &
            "provide the correct overload's parameters", procSym)
    theProc = getOverload(procSym, params)
  # get some metadata about the proc
  let
    procImpl = theProc.getImpl
    procParams = getParamList(procImpl[3])
    procRetType = procImpl[3][0]
  # do some extra checks to see if the passed proc is usable
  if kind == ipInit:
    if procParams[0] != newTree(nnkVarTy, class):
      error("first parameter of [init] proc must be var[class]", procSym)
    if not (procRetType.kind == nnkEmpty or procRetType == bindSym"void"):
      error("return type for [init] proc must be void", procSym)
  # create the resulting init proc
  result = newProc(params = [newEmptyNode(),
                             newIdentDefs(ident"vm", ident"RawVM")])
  result.addPragma(ident"cdecl")
  var body = newStmtList()
  # create the necessary variables and add type metadata
  let
    # the raw Wren instance
    rawVM = newDotExpr(vm, ident"handle")
    # raw memory, this includes the type ID prepended before the actual data
    sizeofU16 = newCall("sizeof", ident"uint16")
    sizeofClass = newCall("sizeof", class)
    foreignSize = newTree(nnkInfix, ident"+", sizeofU16, sizeofClass)
    newForeignCall = newCall("newForeign", rawVM, newLit(0), foreignSize)
    rawMemVar = newVarStmt(ident"rawMem",
                           newCast(parseExpr"ptr UncheckedArray[uint16]",
                                   newForeignCall))
    # the object pointer
    foreignData = newCall("unsafeAddr", newTree(nnkBracketExpr,
                                                ident"rawMem", newLit(1)))
    dataVar = newVarStmt(ident"foreignData",
                         newCast(newTree(nnkPtrTy, class), foreignData))
    # the type ID assignment
    typeIdAssign = newAssignment(newTree(nnkBracketExpr,
                                         ident"rawMem", newLit(0)),
                                 newLit(getTypeId(class)))
  body.add([rawMemVar, dataVar, typeIdAssign])
  # generate the type check
  var typeCheckParams = @[ident"vm"]
  let initParams =
    # the params for object construction, excluding the first param in case
    # of initializer
    if kind == ipInit: procParams[1..^1]
    else: procParams
  typeCheckParams.add(getWrenTypes(initParams))
  let typeCheck = newCall(ident"checkTypes", typeCheckParams)
  # finally, initialize or construct the object
  var initBody = newStmtList()
  case kind
  of ipInit:
    # initializer
    initBody.add(newCall("reset", newCast(newTree(nnkVarTy, class),
                                          ident"foreignData")))
    var initCallParams = @[newCast(newTree(nnkVarTy, class),
                                   ident"foreignData")]
    initCallParams.add(getSlotGetters(initParams))
    let initCall = newCall(theProc, initCallParams)
    initBody.add(initCall)
  of ipNew:
    # constructor
    let
      ctorCall = newCall(theProc, getSlotGetters(initParams))
      dataAssign = newAssignment(newTree(nnkBracketExpr, ident"foreignData"),
                                 ctorCall)
    initBody.add(dataAssign)
    if procRetType.isRef:
      initBody.add(newCall("GC_ref",
                           newTree(nnkBracketExpr, ident"foreignData")))
  body.add(newIfStmt((cond: typeCheck, body: initBody)))
  result.body = body

proc genDestroyGlue(vm, class, procSym: NimNode): NimNode =
  ## Generates glue code for the destructor.
  ## Special action must be done when:
  ## - a destructor is provided, to execute it
  ## - the object is a ref object, to call GC_unref and free its memory
  ## Otherwise, this proc returns a nil literal.
  echo class.getImpl.treeRepr
  if procSym.kind != nnkNilLit or class.isRef:
    # create the destructor proc
    result = newProc(params = [newEmptyNode(),
                              newIdentDefs(ident"rawPtr", ident"pointer")])
    result.addPragma(ident"cdecl")
    var body = newStmtList()
    # create some variables, which are conversions of ``rawPtr``
    let
      u16Var = newLetStmt(ident"u16",
                          newCast(parseExpr"ptr UncheckedArray[uint16]",
                                  ident"rawPtr"))
      dataPtr = newCall("unsafeAddr", newTree(nnkBracketExpr,
                                              ident"u16", newLit(1)))
      dataVar = newVarStmt(ident"foreignData",
                           newCast(newTree(nnkPtrTy, class), dataPtr))
    body.add([u16Var, dataVar])
    # run the user-provided destructor, if applicable
    if procSym.kind != nnkNilLit:
      # resolve the overload
      var theProc = procSym
      if theProc.kind != nnkSym:
        let param =
          if class.isRef: class
          else: newTree(nnkVarTy, class)
        theProc = getOverload(theProc, param)
        if theProc == nil:
          error("no suitable destructor found", theProc)
      # call the destructor
      let destructorParam =
        if class.isRef: newTree(nnkBracketExpr, ident"foreignData")
        else: newCast(newTree(nnkVarTy, class), ident"foreignData")
      body.add(newCall(theProc, destructorParam))
    # if dealing with a GD'd type, unref it
    if class.isRef:
      body.add(newCall("GC_unref", newTree(nnkBracketExpr, ident"foreignData")))
    result.body = body
  else:
    result = newNilLit()

macro addClassAux*(vm: Wren, module: string, class: typed,
                   initProc, destroyProc: typed,
                   initProcKind: static InitProcKind,
                   initOverloaded: static bool,
                   initParams: varargs[typed]): untyped =
  ## Generates code which binds a new class to the provided Wren instance.
  ## This is an implementation detail and you should not use it in your code.

  # generate all the glue procs
  let
    initGlue = genInitGlue(vm, class, initProc, initProcKind,
                           initOverloaded, initParams)
    destroyGlue = genDestroyGlue(vm, class, destroyProc)
  result = newCall("addClass", vm, module, newLit(class.repr),
                   initGlue, destroyGlue)

proc getOverloadParams(def: NimNode): seq[NimNode] =
  ## Returns the overload's parameters as a raw seq.
  for param in def[1..^1]:
    result.add(param)

proc getAddProcAuxCall(vm, module, class, theProc: NimNode,
                       isObject: bool, isGetter = false): NimNode =
  # get the class metadata, depending on whether we're binding a namespace or
  # an object
  let
    classSym =
      if isObject: class
      else: newNilLit()
    className = newLit(class.repr)
  # non-overloaded proc binding
  if theProc.kind == nnkIdent:
    # defer the binding to addProcAux
    # XXX: find a way which doesn't require addProcAux to be public
    result = newCall(ident"addProcAux", vm, module, classSym, className,
                     theProc, newLit(false), newLit(isGetter))
  # overloaded/getter proc binding
  elif theProc.kind in {nnkCall, nnkCommand}:
    var callArgs = @[vm, module, classSym, className,
                     theProc[0], newLit(true)]
    if isGetter:
      # bind a getter
      callArgs[3] = theProc[1]
      callArgs.add([newLit(true), class])
    else:
      # bind the overloaded proc
      callArgs.add(newLit(false))
      callArgs.add(getOverloadParams(theProc))
    result = newCall(ident"addProcAux", callArgs)

proc getAddClassAuxCall(vm, module, class, initProc, destroyProc: NimNode,
                        initProcKind: InitProcKind): NimNode =
  # non-overloaded init proc
  if initProc.kind == nnkIdent:
    result = newCall(ident"addClassAux", vm, module, class,
                     initProc, destroyProc, newLit(initProcKind), newLit(false))
  # overloaded init proc
  else:
    var callArgs = @[vm, module, class, initProc[0], destroyProc,
                     newLit(initProcKind), newLit(true)]
    callArgs.add(getOverloadParams(initProc))
    result = newCall(ident"addClassAux", callArgs)

macro foreign*(vm: Wren, module: string, body: untyped): untyped =
  body.expectKind(nnkStmtList)
  # we begin with an empty module
  # this module is later used in a ``module()`` call
  var stmts = newTree(nnkStmtList, newVarStmt(ident"modSrc", newLit("")))
  for decl in body:
    case decl.kind
    of nnkCallKinds:
      # ``module`` blocks accept a string and append to the ``modSrc`` string
      # described earlier
      if eqIdent(decl[0], "module"):
        stmts.add(newCall("add", ident"modSrc", decl[1]))
        stmts.add(newCall("add", ident"modSrc", newLit('\n')))
      # namespace and object bindings
      elif decl.kind == nnkCall:
        let
          class = decl[0]
          procs = decl[1]
        # object-specific procedures
        # If at least procInit or procNew is not nil, a class will be created
        # ``procInit`` and ``procNew`` are mutually exclusive, only one can
        # be present at a time
        # ``procDestroy`` is optional but one of the initializer procs must
        # be present
        # If none are present, no foreign class will be created, and the procs
        # will be bound to a namespace
        var
          procInit, procDestroy: NimNode = nil
          initProcKind: InitProcKind
          isObject = false
        for p in procs:
          if p.kind == nnkCommand and p[0].kind == nnkBracket:
            # annotated binding
            # [init], [new], [destroy], [get]
            p.expectLen(2)
            p[0][0].expectKind(nnkIdent)
            let annotation = p[0][0].strVal
            case annotation
            of "init":
              if procInit != nil:
                error("class may only have one constructing proc", p)
              procInit = p[1]
              initProcKind = ipInit
              isObject = true
            of "new":
              if procInit != nil:
                error("class may only have one constructing proc", p)
              procInit = p[1]
              initProcKind = ipNew
              isObject = true
            of "destroy":
              if procInit == nil:
                error("[destroy] may only be used in object-binding classes", p)
              procDestroy = p[1]
            of "get":
              stmts.add(getAddProcAuxCall(vm, module, class, p[1],
                                          isObject, true))
            else: error("invalid annotation", p[0][0])
          else:
            # regular binding
            stmts.add(getAddProcAuxCall(vm, module, class,
                                        p, isObject))
        if procInit != nil:
          stmts.add(getAddClassAuxCall(vm, module, class,
                                       procInit, procDestroy, initProcKind))
    else:
      # any other bindings are invalid
      error("invalid foreign binding", decl)
  stmts.add(newCall("module", vm, module, ident"modSrc"))
  result = newBlockStmt(stmts)

when isMainModule:
  proc add(x, y: int): int = x + y
  proc pi: float = 3.14159265

  type
    Greeter = object
      target: string
    Vec2 = object
      x, y: float
    Vec3 = object
      x, y, z: float

  proc init(greeter: var Greeter, target: string) =
    greeter.target = target

  proc `+`(a, b: Vec2) = discard
  proc `+`(a, b: Vec3) = discard
  proc `-`(a, b: Vec3) = discard

  var wrenVM = newWren()
  expandMacros:
    wrenVM.foreign("main"):
      Math:
        add(int, int)
        `+`(Vec2, Vec2)
        `+`(Vec3, Vec3)
        `-`(Vec3, Vec3)
        [get] pi
      Greeter:
        [init] init(var Greeter, string)
